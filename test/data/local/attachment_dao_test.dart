import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/mail_attachment.dart';

void main() {
  late Database db;
  late AttachmentDao dao;
  late int messageId;

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
    dao = AttachmentDao(db);

    final accountId = await AccountDao(db).insert(const MailAccount(
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
    final folderId = await FolderDao(db).upsert(MailFolder(
      accountId: accountId,
      name: 'INBOX',
      path: 'INBOX',
      type: MailFolderType.inbox,
    ));
    await MessageDao(db).upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    messageId = (await MessageDao(db).getForFolder(folderId)).first.id!;
  });

  tearDown(() async => db.close());

  test('insertAll then getForMessage returns them', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);

    final attachments = await dao.getForMessage(messageId);
    expect(attachments, hasLength(1));
    expect(attachments.first.filename, 'report.pdf');
    expect(attachments.first.localPath, isNull);
  });

  test('updateLocalPath sets the downloaded file path', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);
    final id = (await dao.getForMessage(messageId)).first.id!;

    await dao.updateLocalPath(id, '/tmp/report.pdf');

    final updated = await dao.getForMessage(messageId);
    expect(updated.first.localPath, '/tmp/report.pdf');
  });

  test('insertAll with a duplicate (message_id, filename) replaces rather than duplicates', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);

    // Simulates re-opening a message: fetchBodyIfNeeded re-inserts the same
    // attachment metadata a second time.
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 4096,
      ),
    ]);

    final attachments = await dao.getForMessage(messageId);
    expect(attachments, hasLength(1));
    expect(attachments.first.size, 4096);
  });

  test('deleting the parent message cascades to its attachments', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);
    expect(await dao.getForMessage(messageId), hasLength(1));

    await db.delete('messages', where: 'id = ?', whereArgs: [messageId]);

    expect(await dao.getForMessage(messageId), isEmpty);
  });
}
