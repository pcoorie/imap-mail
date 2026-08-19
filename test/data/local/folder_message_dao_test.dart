import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';

void main() {
  late Database db;
  late FolderDao folderDao;
  late MessageDao messageDao;
  late int accountId;

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
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    folderDao = FolderDao(db);
    messageDao = MessageDao(db);
    accountId = await AccountDao(db).insert(const MailAccount(
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    ));
  });

  tearDown(() async => db.close());

  group('FolderDao', () {
    test('upsert inserts then updates the same folder by (accountId, path)', () async {
      final folder = MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      );
      final id1 = await folderDao.upsert(folder);
      final id2 = await folderDao.upsert(folder.copyWith(unreadCount: 3));

      expect(id2, id1);
      final fetched = await folderDao.getById(id1);
      expect(fetched!.unreadCount, 3);
    });

    test('getForAccount returns only that account\'s folders', () async {
      await folderDao.upsert(MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      ));
      final folders = await folderDao.getForAccount(accountId);
      expect(folders, hasLength(1));
      expect(folders.first.name, 'INBOX');
    });
  });

  group('MessageDao', () {
    late int folderId;

    setUp(() async {
      folderId = await folderDao.upsert(MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      ));
    });

    MailMessage sampleMessage(int uid) => MailMessage(
          folderId: folderId,
          uid: uid,
          subject: 'Subject $uid',
          from: 'a@example.com',
          to: 'me@example.com',
          date: DateTime.utc(2026, 8, 19),
          snippet: 'snippet',
        );

    test('upsertHeaders inserts new and replaces existing by (folderId, uid)', () async {
      await messageDao.upsertHeaders([sampleMessage(1), sampleMessage(2)]);
      await messageDao.upsertHeaders([sampleMessage(1).copyWith(isRead: true)]);

      final messages = await messageDao.getForFolder(folderId);
      expect(messages, hasLength(2));
      expect(messages.firstWhere((m) => m.uid == 1).isRead, isTrue);
    });

    test(
        'upsertHeaders on an existing uid preserves a previously-downloaded body when the new header data has no body',
        () async {
      await messageDao.upsertHeaders([sampleMessage(1)]);
      final id = (await messageDao.getForFolder(folderId)).first.id!;
      await messageDao.updateBody(id, bodyText: 'full body', bodyHtml: '<p>full body</p>');

      await messageDao.upsertHeaders([sampleMessage(1).copyWith(subject: 'New subject')]);

      final updated = await messageDao.getById(id);
      expect(updated!.bodyText, 'full body');
      expect(updated.bodyHtml, '<p>full body</p>');
      expect(updated.isDownloaded, isTrue);
      expect(updated.subject, 'New subject');
    });

    test(
        'upsertHeaders on an existing uid overwrites the body when the new header data is itself downloaded',
        () async {
      await messageDao.upsertHeaders([sampleMessage(1)]);

      await messageDao.upsertHeaders([
        sampleMessage(1).copyWith(
          bodyText: 'fetched body',
          isDownloaded: true,
        ),
      ]);

      final updated = (await messageDao.getForFolder(folderId)).first;
      expect(updated.bodyText, 'fetched body');
      expect(updated.isDownloaded, isTrue);
    });

    test('getMaxUid returns 0 when folder is empty, else the highest uid', () async {
      expect(await messageDao.getMaxUid(folderId), 0);
      await messageDao.upsertHeaders([sampleMessage(1), sampleMessage(5)]);
      expect(await messageDao.getMaxUid(folderId), 5);
    });

    test('updateBody sets bodyText/bodyHtml', () async {
      await messageDao.upsertHeaders([sampleMessage(1)]);
      final id = (await messageDao.getForFolder(folderId)).first.id!;

      await messageDao.updateBody(id, bodyText: 'full body', bodyHtml: null);

      final updated = await messageDao.getById(id);
      expect(updated!.bodyText, 'full body');
      expect(updated.isDownloaded, isTrue);
    });

    test('insertLocal creates a message not tied to a synced uid', () async {
      final id = await messageDao.insertLocal(sampleMessage(0).copyWith(
        sendStatus: MailSendStatus.failed,
      ));
      final fetched = await messageDao.getById(id);
      expect(fetched!.sendStatus, MailSendStatus.failed);
    });

    test('insertLocal called twice into the same folder produces two distinct messages without throwing',
        () async {
      final id1 = await messageDao.insertLocal(sampleMessage(0).copyWith(subject: 'First local'));
      final id2 = await messageDao.insertLocal(sampleMessage(0).copyWith(subject: 'Second local'));

      final messages = await messageDao.getForFolder(folderId);
      expect(messages, hasLength(2));
      final m1 = messages.firstWhere((m) => m.id == id1);
      final m2 = messages.firstWhere((m) => m.id == id2);
      expect(m1.uid, isNot(equals(m2.uid)));
    });

    test('updateSendStatus updates the flag', () async {
      final id = await messageDao.insertLocal(sampleMessage(0));
      await messageDao.updateSendStatus(id, MailSendStatus.sent);
      expect((await messageDao.getById(id))!.sendStatus, MailSendStatus.sent);
    });

    test('updateReadStatus marks a message read', () async {
      await messageDao.upsertHeaders([sampleMessage(1)]);
      final id = (await messageDao.getForFolder(folderId)).first.id!;
      expect((await messageDao.getById(id))!.isRead, isFalse);

      await messageDao.updateReadStatus(id, true);

      expect((await messageDao.getById(id))!.isRead, isTrue);
    });

    test('moveToFolder relocates the message and assigns it a fresh negative local uid', () async {
      final trashFolderId = await folderDao.upsert(MailFolder(
        accountId: accountId,
        name: 'Trash',
        path: 'Trash',
        type: MailFolderType.trash,
      ));
      await messageDao.upsertHeaders([sampleMessage(7)]);
      final message = (await messageDao.getForFolder(folderId)).first;

      await messageDao.moveToFolder(message.id!, trashFolderId);

      final trashMessages = await messageDao.getForFolder(trashFolderId);
      expect(trashMessages, hasLength(1));
      expect(trashMessages.first.id, message.id);
      expect(trashMessages.first.uid, lessThan(0));

      final inboxMessages = await messageDao.getForFolder(folderId);
      expect(inboxMessages, isEmpty);
    });
  });
}
