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

class MockMailTransport extends Mock implements MailTransport {}

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

const _accountTemplate = MailAccount(
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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(_accountTemplate);
    registerFallbackValue(const MailFolder(accountId: 1, name: '', path: '', type: MailFolderType.inbox));
  });

  test(
      'foldersProvider: a sync failure after a prior success sets syncErrorProvider but still resolves with cached data',
      () async {
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

    final accountId = await AccountDao(db).insert(_accountTemplate);
    final account = _accountTemplate.copyWith(id: accountId);

    final transport = MockMailTransport();
    var callCount = 0;
    when(() => transport.discoverFolders(any(), any(), any())).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return [MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox)];
      }
      throw Exception('connection refused');
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => db),
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      mailTransportProvider.overrideWithValue(transport),
      credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
    ]);
    addTearDown(container.dispose);

    final first = await container.read(foldersProvider(accountId).future);
    expect(first.map((f) => f.name), contains('INBOX'));
    expect(container.read(syncErrorProvider(accountId)), isNull);

    container.invalidate(foldersProvider(accountId));
    final second = await container.read(foldersProvider(accountId).future);

    // Falls back to cache instead of throwing...
    expect(second, isNotEmpty);
    // ...but the failure must not be silently swallowed now that a cache
    // exists: it has to surface somewhere.
    expect(container.read(syncErrorProvider(accountId)), isNotNull);
    expect(container.read(syncErrorProvider(accountId)), contains('connection refused'));
  });

  test(
      'messagesProvider: a sync failure after a prior success sets syncErrorProvider but still resolves with cached data',
      () async {
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

    final accountId = await AccountDao(db).insert(_accountTemplate);
    final account = _accountTemplate.copyWith(id: accountId);
    final folderId = await FolderDao(db).upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );

    final transport = MockMailTransport();
    var callCount = 0;
    when(() => transport.fetchHeadersSince(any(), any(), any(), any())).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) {
        return [
          MailMessage(
            folderId: folderId,
            uid: 1,
            subject: 'Hello',
            from: 'a@example.com',
            to: 'me@example.com',
            date: DateTime.utc(2026, 8, 19),
            snippet: 'Hi',
          ),
        ];
      }
      throw Exception('connection refused');
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => db),
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      mailTransportProvider.overrideWithValue(transport),
      credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
    ]);
    addTearDown(container.dispose);

    final folder = MailFolder(id: folderId, accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox);

    final first = await container.read(messagesProvider(folder).future);
    expect(first, isNotEmpty);
    expect(container.read(syncErrorProvider(accountId)), isNull);

    container.invalidate(messagesProvider(folder));
    final second = await container.read(messagesProvider(folder).future);

    expect(second, isNotEmpty);
    expect(container.read(syncErrorProvider(accountId)), isNotNull);
    expect(container.read(syncErrorProvider(accountId)), contains('connection refused'));
  });

  test(
      'syncErrorProvider: setting the error state for one accountId does not affect another accountId (per-account isolation, the entire point of the family key)',
      () async {
    // No DB/transport needed here — this tests the family's own key
    // isolation, which is orthogonal to how foldersProvider/messagesProvider
    // populate it. Simulating two concurrently-syncing accounts (accountA
    // failing, accountB healthy) directly via the notifiers is the most
    // direct proof that the family doesn't secretly share state across keys.
    const accountA = 1;
    const accountB = 2;

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Both start unset.
    expect(container.read(syncErrorProvider(accountA)), isNull);
    expect(container.read(syncErrorProvider(accountB)), isNull);

    // Account A's sync fails...
    container.read(syncErrorProvider(accountA).notifier).state = 'connection refused';

    // ...and must be readable under its own key...
    expect(container.read(syncErrorProvider(accountA)), 'connection refused');
    // ...without leaking into account B's independent key.
    expect(container.read(syncErrorProvider(accountB)), isNull);

    // Account B's sync then succeeds explicitly (mirrors what
    // foldersProvider/messagesProvider do on success) — this must not clear
    // account A's still-outstanding failure.
    container.read(syncErrorProvider(accountB).notifier).state = null;
    expect(container.read(syncErrorProvider(accountA)), 'connection refused');
    expect(container.read(syncErrorProvider(accountB)), isNull);
  });
}
