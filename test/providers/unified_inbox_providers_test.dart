import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';

class MockMailTransport extends Mock implements MailTransport {}

class _FakeCredentialStore implements SecureCredentialStore {
  @override
  Future<void> savePassword({required int accountId, required String password}) async {}
  @override
  Future<String?> getPassword(int accountId) async => 'app-password';
  @override
  Future<void> deletePassword(int accountId) async {}
}

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  const workAccount = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personalAccount = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 3);
  final workSent = MailFolder(id: 11, accountId: 1, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 5);

  MailMessage msg({required int id, required int folderId, required DateTime date}) => MailMessage(
        id: id, folderId: folderId, uid: id, subject: 'Subject $id', from: 'a@example.com',
        to: 'me@example.com', date: date, snippet: 'snippet',
      );

  test('unifiedInboxProvider merges only Inbox folders across accounts, sorted newest-first', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) {
          return [msg(id: 1, folderId: 10, date: DateTime.utc(2026, 8, 20))];
        }
        if (folder.id == personalInbox.id) {
          return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
        }
        fail('messagesProvider should never be called for a non-inbox folder');
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2, 1]); // personal (8/21) before work (8/20)
    expect(result[0].account, personalAccount);
    expect(result[1].account, workAccount);
  });

  test('unifiedInboxProvider treats a failed, cache-empty account as contributing zero rows, and records its error', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) throw Exception('connection refused');
        return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2]);
    expect(container.read(syncErrorProvider(1)), contains('connection refused'));
  });

  test('totalUnreadCountProvider sums unread counts across accounts\' Inbox folders only', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 8); // 3 + 5
  });

  test('totalUnreadCountProvider treats a failed account as contributing zero, not throwing', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async {
        if (accountId == 1) throw Exception('offline');
        return [personalInbox];
      }),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 5);
  });

  group('totalUnreadCountProvider through the real DAO/repository path (regression coverage for the '
      'always-0 badge bug — no test previously drove this provider through real persisted data)', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      registerFallbackValue(workAccount);
      registerFallbackValue(const MailFolder(accountId: 1, name: '', path: '', type: MailFolderType.inbox));
    });

    test(
        'sums a real unread count recomputed by MailRepository.syncHeaders and persisted via FolderDao — '
        'not an overridden foldersProvider fixture', () async {
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: AppDatabase.onCreate,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          singleInstance: false,
        ),
      );
      addTearDown(() => db.close());

      final accountId = await AccountDao(db).insert(workAccount);
      final account = workAccount.copyWith(id: accountId);
      final folderId = await FolderDao(db).upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );

      final transport = MockMailTransport();
      when(() => transport.discoverFolders(any(), any(), any())).thenAnswer((_) async => [
            MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
          ]);
      when(() => transport.fetchHeadersSince(any(), any(), any(), any())).thenAnswer((_) async => [
            MailMessage(
              folderId: folderId, uid: 1, subject: 'Unread one', from: 'a@example.com',
              to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'snippet',
            ),
            MailMessage(
              folderId: folderId, uid: 2, subject: 'Already read', from: 'a@example.com',
              to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'snippet', isRead: true,
            ),
            MailMessage(
              folderId: folderId, uid: 3, subject: 'Unread two', from: 'a@example.com',
              to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'snippet',
            ),
          ]);

      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailTransportProvider.overrideWithValue(transport),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ]);
      addTearDown(container.dispose);

      // Drives a real syncHeaders call, which recomputes and persists the
      // folder's true unread count (2 of 3 messages unread) via
      // MessageDao.countUnread + FolderDao.updateUnreadCount — exactly the
      // path production code takes, not a hand-built MailFolder(unreadCount: N).
      final folder = MailFolder(id: folderId, accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox);
      await container.read(messagesProvider(folder).future);

      // A subsequent foldersProvider refresh (the real trigger for
      // totalUnreadCountProvider re-reading folder rows) must not clobber
      // the count back to 0 — this is what FolderDao.upsert's preservation
      // of unread_count guards against.
      container.invalidate(foldersProvider(accountId));

      expect(await container.read(totalUnreadCountProvider.future), 2);
    });
  });
}
