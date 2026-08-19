import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_attachment.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // Use the no-isolate ffi factory: this test pumps a real widget that
    // awaits real async DAO calls through mailRepositoryProvider inside
    // testWidgets' fake-async environment. The default databaseFactoryFfi
    // dispatches SQLite calls to a background worker isolate; cross-isolate
    // message delivery can deadlock under that environment (unlike the
    // codebase's plain `test()` DAO tests, which run on the real event loop
    // and are unaffected). Running SQLite calls directly on the calling
    // isolate avoids the deadlock.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  // The real database/accounts provider chain reaches through path_provider
  // and sqflite platform channels, which never settle inside a widget test's
  // fake async zone (see folder_view_screen_test.dart for the same
  // established fix). We instead override databaseProvider with a
  // pre-populated in-memory sqflite database and accountsProvider with a
  // fake notifier, exercising the real MailRepository/DAO logic without
  // touching any platform channel.
  Future<
      ({
        MailAccount account,
        MailFolder folder,
        MailMessage message,
        Database db,
      })> seedDatabase({List<MailAttachment> attachments = const []}) async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: AppDatabase.onCreate,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    const accountTemplate = MailAccount(
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    );
    final accountId = await AccountDao(db).insert(accountTemplate);
    final account = accountTemplate.copyWith(id: accountId);

    final folderDao = FolderDao(db);
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;

    final messageDao = MessageDao(db);
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Hello',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'Hi',
        bodyText: 'Hi there, this is the plain body.',
        isDownloaded: true,
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;

    if (attachments.isNotEmpty) {
      await AttachmentDao(db).insertAll(
        attachments.map((a) => a.copyWith(messageId: message.id)).toList(),
      );
    }

    return (account: account, folder: folder, message: message, db: db);
  }

  testWidgets('renders plain text body when no HTML is present', (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('Hi there, this is the plain body.'), findsOneWidget);
  });

  testWidgets('loads and renders attachment metadata persisted for the message', (tester) async {
    final seed = await seedDatabase(attachments: const [
      MailAttachment(
        messageId: 0,
        filename: 'invoice.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);
    addTearDown(() => seed.db.close());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('invoice.pdf'), findsOneWidget);
  });

  testWidgets('confirming delete moves the message to Trash and pops back to the folder view', (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());
    final folderDao = FolderDao(seed.db);
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: seed.account.id!, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
      ],
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (settings) => MaterialPageRoute(
            builder: (_) => MessageDetailScreen(folder: seed.folder, message: seed.message),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(find.text('Delete this message?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MessageDetailScreen), findsNothing);

    final messageDao = MessageDao(seed.db);
    final trashMessages = await messageDao.getForFolder(trashFolderId);
    expect(trashMessages, hasLength(1));
    expect(trashMessages.first.id, seed.message.id);
    final inboxMessages = await messageDao.getForFolder(seed.folder.id!);
    expect(inboxMessages, isEmpty);
  });
}
