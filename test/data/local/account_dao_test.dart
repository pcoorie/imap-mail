import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

void main() {
  late Database db;
  late AccountDao dao;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: AppDatabase.onCreate,
      ),
    );
    dao = AccountDao(db);
  });

  tearDown(() async {
    await db.close();
  });

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

  test('insert assigns an id and getById returns the same account', () async {
    final id = await dao.insert(account);
    expect(id, greaterThan(0));

    final fetched = await dao.getById(id);
    expect(fetched, account.copyWith(id: id));
  });

  test('getAll returns all inserted accounts', () async {
    await dao.insert(account);
    await dao.insert(account.copyWith(displayName: 'Personal', email: 'p@example.com'));

    final all = await dao.getAll();
    expect(all, hasLength(2));
  });

  test('update persists changed fields', () async {
    final id = await dao.insert(account);
    await dao.update(account.copyWith(id: id, displayName: 'Renamed'));

    final fetched = await dao.getById(id);
    expect(fetched!.displayName, 'Renamed');
  });

  test('delete removes the account', () async {
    final id = await dao.insert(account);
    await dao.delete(id);

    expect(await dao.getById(id), isNull);
  });
}
