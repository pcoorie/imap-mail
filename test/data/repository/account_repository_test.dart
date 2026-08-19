import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/repository/account_repository.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

class MockMailTransport extends Mock implements MailTransport {}

class FakeCredentialStore implements SecureCredentialStore {
  final Map<int, String> _passwords = {};

  @override
  Future<void> savePassword({
    required int accountId,
    required String password,
  }) async {
    _passwords[accountId] = password;
  }

  @override
  Future<String?> getPassword(int accountId) async => _passwords[accountId];

  @override
  Future<void> deletePassword(int accountId) async =>
      _passwords.remove(accountId);
}

void main() {
  late Database db;
  late AccountDao accountDao;
  late FakeCredentialStore credentialStore;
  late MockMailTransport transport;
  late AccountRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(
      const MailAccount(
        displayName: '',
        email: '',
        imapHost: '',
        imapPort: 993,
        imapSecurity: MailSecurity.ssl,
        smtpHost: '',
        smtpPort: 465,
        smtpSecurity: MailSecurity.ssl,
        username: '',
      ),
    );
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: AppDatabase.onCreate,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    accountDao = AccountDao(db);
    credentialStore = FakeCredentialStore();
    transport = MockMailTransport();
    repository = AccountRepository(accountDao, credentialStore, transport);
  });

  tearDown(() async => db.close());

  const account = MailAccount(
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

  test('addAccount tests the connection before persisting', () async {
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});

    final id = await repository.addAccount(account, 'app-password');

    verify(() => transport.testConnection(any(), 'app-password')).called(1);
    expect(await accountDao.getById(id), isNotNull);
    expect(await credentialStore.getPassword(id), 'app-password');
  });

  test('addAccount does not persist when the connection test throws', () async {
    when(
      () => transport.testConnection(any(), any()),
    ).thenThrow(Exception('auth failed'));

    await expectLater(
      repository.addAccount(account, 'wrong-password'),
      throwsException,
    );
    expect(await accountDao.getAll(), isEmpty);
  });

  test(
    'removeAccount deletes the account row and the stored password',
    () async {
      when(
        () => transport.testConnection(any(), any()),
      ).thenAnswer((_) async {});
      final id = await repository.addAccount(account, 'app-password');

      await repository.removeAccount(id);

      expect(await accountDao.getById(id), isNull);
      expect(await credentialStore.getPassword(id), isNull);
    },
  );

  test('listAccounts returns all persisted accounts', () async {
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});
    await repository.addAccount(account, 'app-password');

    expect(await repository.listAccounts(), hasLength(1));
  });
}
