import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_attachment.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeCredentialStore implements SecureCredentialStore {
  @override
  Future<void> savePassword({required int accountId, required String password}) async {}
  @override
  Future<String?> getPassword(int accountId) async => 'app-password';
  @override
  Future<void> deletePassword(int accountId) async {}
}

/// Hand-written fake (rather than mocktail) so every method's behavior is
/// explicit and configurable per test without registering fallback values
/// for every domain type.
class _FakeMailTransport implements MailTransport {
  bool throwOnFetchBody = false;
  int fetchHeadersSinceCallCount = 0;

  @override
  Future<void> testConnection(MailAccount account, String password) async {}

  @override
  Future<List<MailFolder>> discoverFolders(MailAccount account, String password, int accountId) async => [];

  @override
  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  ) async {
    fetchHeadersSinceCallCount++;
    return [];
  }

  @override
  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async {
    if (throwOnFetchBody) {
      throw Exception('connection refused');
    }
    throw UnimplementedError('not exercised by this test');
  }

  @override
  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async =>
      [];

  @override
  Future<List<MailAttachment>> fetchAttachmentList(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async =>
      [];
}

class _FakeMailSender implements MailSender {
  bool sendCalled = false;
  ComposedMessage? lastMessage;

  @override
  Future<void> send(MailAccount account, String password, ComposedMessage message) async {
    sendCalled = true;
    lastMessage = message;
  }
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
      })> seedDatabase({
    List<MailAttachment> attachments = const [],
    bool downloaded = true,
    MailSendStatus sendStatus = MailSendStatus.none,
  }) async {
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
        bodyText: downloaded ? 'Hi there, this is the plain body.' : null,
        isDownloaded: downloaded,
        sendStatus: sendStatus,
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

  testWidgets('marks the message read after a successful load', (tester) async {
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

    final refreshed = await MessageDao(seed.db).getById(seed.message.id!);
    expect(refreshed!.isRead, isTrue);
  });

  testWidgets('shows an error with a Retry button instead of a permanent spinner when loading the body fails',
      (tester) async {
    final seed = await seedDatabase(downloaded: false);
    addTearDown(() => seed.db.close());
    final transport = _FakeMailTransport()..throwOnFetchBody = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(transport),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('connection refused'), findsOneWidget);
    final retryButtonFinder = find.widgetWithText(ElevatedButton, 'Retry');
    expect(retryButtonFinder, findsOneWidget);

    // Retry re-runs _load(); still fails the same way (transport keeps
    // throwing), proving Retry actually re-triggers a load rather than
    // being a dead button.
    await tester.tap(retryButtonFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('connection refused'), findsOneWidget);
  });

  testWidgets('deleting a message invalidates messagesProvider so the folder view resyncs instead of showing stale data',
      (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());
    final folderDao = FolderDao(seed.db);
    await folderDao.upsert(
      MailFolder(accountId: seed.account.id!, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final transport = _FakeMailTransport();

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => seed.db),
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
      mailTransportProvider.overrideWithValue(transport),
      credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
    ]);
    addTearDown(container.dispose);

    // Warm the messagesProvider cache the way FolderViewScreen would.
    await container.read(messagesProvider(seed.folder).future);
    expect(transport.fetchHeadersSinceCallCount, 1);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
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
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Re-reading messagesProvider(folder) must re-sync (hit the transport
    // again) rather than silently serving the stale cached list that still
    // contains the just-deleted message.
    await container.read(messagesProvider(seed.folder).future);
    expect(transport.fetchHeadersSinceCallCount, 2);
  });

  testWidgets('shows a Retry-send action for a failed message and calls retryFailedMessage', (tester) async {
    final seed = await seedDatabase(sendStatus: MailSendStatus.failed);
    addTearDown(() => seed.db.close());
    final sender = _FakeMailSender();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
        mailSenderProvider.overrideWithValue(sender),
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

    final retryIconFinder = find.byIcon(Icons.refresh);
    expect(retryIconFinder, findsOneWidget);

    await tester.tap(retryIconFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(sender.sendCalled, isTrue);
    expect(sender.lastMessage!.subject, seed.message.subject);
    // Retry navigates back on success, same as the delete flow.
    expect(find.byType(MessageDetailScreen), findsNothing);
    final remaining = await MessageDao(seed.db).getById(seed.message.id!);
    expect(remaining, isNull);
  });
}
