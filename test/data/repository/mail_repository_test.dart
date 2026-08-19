import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';

class MockMailTransport extends Mock implements MailTransport {}

class MockMailSender extends Mock implements MailSender {}

class FakeCredentialStore implements SecureCredentialStore {
  final Map<int, String> _passwords = {1: 'app-password'};
  @override
  Future<void> savePassword({required int accountId, required String password}) async {}
  @override
  Future<String?> getPassword(int accountId) async => _passwords[accountId];
  @override
  Future<void> deletePassword(int accountId) async {}

  void overridePassword(int accountId, String password) => _passwords[accountId] = password;
}

void main() {
  late Database db;
  late FolderDao folderDao;
  late MessageDao messageDao;
  late AttachmentDao attachmentDao;
  late MockMailTransport transport;
  late MockMailSender sender;
  late MailRepository repository;
  late int accountId;

  const account = MailAccount(
    id: 1,
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

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(account);
    registerFallbackValue(const MailFolder(accountId: 1, name: '', path: '', type: MailFolderType.inbox));
    registerFallbackValue(MailMessage(
      folderId: 1,
      uid: 1,
      subject: '',
      from: '',
      to: '',
      date: DateTime.utc(2026, 1, 1),
      snippet: '',
    ));
    registerFallbackValue(ComposedMessage(
      to: const [],
      cc: const [],
      bcc: const [],
      subject: '',
      bodyText: '',
      bodyHtml: null,
      attachmentFilePaths: const [],
    ));
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
    attachmentDao = AttachmentDao(db);
    transport = MockMailTransport();
    sender = MockMailSender();
    repository = MailRepository(
      folderDao,
      messageDao,
      attachmentDao,
      transport,
      FakeCredentialStore(),
      sender,
    );
    accountId = await AccountDao(db).insert(account);
  });

  tearDown(() async => db.close());

  test('syncFolders discovers folders and preserves the local Outbox', () async {
    when(() => transport.discoverFolders(any(), any(), any())).thenAnswer((_) async => [
          MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
          MailFolder(accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent),
        ]);
    await repository.ensureOutboxFolder(accountId);

    final folders = await repository.syncFolders(account.copyWith(id: accountId));

    expect(folders.map((f) => f.name), containsAll(['INBOX', 'Sent', 'Outbox']));
    expect(folders.firstWhere((f) => f.name == 'Outbox').isLocalOnly, isTrue);
  });

  test('syncHeaders fetches only messages after the highest cached uid', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 5,
        subject: 'Old',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 1, 1),
        snippet: 'old',
      ),
    ]);
    when(() => transport.fetchHeadersSince(any(), any(), any(), 5)).thenAnswer((_) async => [
          MailMessage(
            folderId: folderId,
            uid: 6,
            subject: 'New',
            from: 'b@example.com',
            to: 'me@example.com',
            date: DateTime.utc(2026, 8, 19),
            snippet: 'new',
          ),
        ]);

    final messages = await repository.syncHeaders(account, folder);

    verify(() => transport.fetchHeadersSince(any(), any(), any(), 5)).called(1);
    expect(messages, hasLength(2));
  });

  test('fetchBodyIfNeeded returns cached message untouched when already downloaded', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
        bodyText: 'cached body',
        isDownloaded: true,
      ),
    ]);
    final cached = (await messageDao.getForFolder(folderId)).first;

    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    expect(result.bodyText, 'cached body');
    verifyNever(() => transport.fetchBody(any(), any(), any(), any()));
  });

  test('fetchBodyIfNeeded fetches and caches the body when not yet downloaded', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
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
    final cached = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.fetchBody(any(), any(), any(), any())).thenAnswer(
      (_) async => cached.copyWith(bodyText: 'fetched body', isDownloaded: true),
    );

    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    expect(result.bodyText, 'fetched body');
    final refetched = await messageDao.getById(cached.id!);
    expect(refetched!.bodyText, 'fetched body');
  });

  test('sendMessage succeeds and caches a sent copy when a Sent folder exists', () async {
    final sentFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent),
    );
    when(() => sender.send(any(), any(), any())).thenAnswer((_) async {});
    final composed = ComposedMessage(
      to: const ['bob@example.com'],
      cc: const [],
      bcc: const [],
      subject: 'Hi',
      bodyText: 'Hello Bob',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    await repository.sendMessage(account, composed);

    verify(() => sender.send(account, 'app-password', composed)).called(1);
    final sentMessages = await messageDao.getForFolder(sentFolderId);
    expect(sentMessages, hasLength(1));
    expect(sentMessages.first.sendStatus, MailSendStatus.sent);
  });

  test('sendMessage does not throw when the best-effort caching step fails after a successful send', () async {
    // Use a dedicated database that we close before the send completes, so that the
    // post-send folder lookup (_folderDao.getForAccount) and the sent-copy cache write
    // both fail with a "database closed" error. The widened try/catch around the whole
    // caching sequence must swallow this and let sendMessage return successfully.
    final scratchDb = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: AppDatabase.onCreate,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    final scratchFolderDao = FolderDao(scratchDb);
    final scratchMessageDao = MessageDao(scratchDb);
    final scratchAttachmentDao = AttachmentDao(scratchDb);
    final scratchAccountId = await AccountDao(scratchDb).insert(account);
    await scratchFolderDao.upsert(
      MailFolder(accountId: scratchAccountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent),
    );
    final scratchCredentialStore = FakeCredentialStore()..overridePassword(scratchAccountId, 'app-password');
    final scratchRepository = MailRepository(
      scratchFolderDao,
      scratchMessageDao,
      scratchAttachmentDao,
      transport,
      scratchCredentialStore,
      sender,
    );
    when(() => sender.send(any(), any(), any())).thenAnswer((_) async {});
    final composed = ComposedMessage(
      to: const ['bob@example.com'],
      cc: const [],
      bcc: const [],
      subject: 'Hi',
      bodyText: 'Hello Bob',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    await scratchDb.close();

    await expectLater(
      scratchRepository.sendMessage(account.copyWith(id: scratchAccountId), composed),
      completes,
    );

    verify(() => sender.send(any(), any(), any())).called(1);
  });

  test('sendMessage on failure stores a failed record in Outbox and rethrows', () async {
    await repository.ensureOutboxFolder(accountId);
    when(() => sender.send(any(), any(), any())).thenThrow(Exception('smtp down'));
    final composed = ComposedMessage(
      to: const ['bob@example.com'],
      cc: const [],
      bcc: const [],
      subject: 'Hi',
      bodyText: 'Hello Bob',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    await expectLater(repository.sendMessage(account, composed), throwsException);

    final outbox = (await folderDao.getForAccount(accountId))
        .firstWhere((f) => f.name == 'Outbox');
    final outboxMessages = await messageDao.getForFolder(outbox.id!);
    expect(outboxMessages, hasLength(1));
    expect(outboxMessages.first.sendStatus, MailSendStatus.failed);
    expect(outboxMessages.first.subject, 'Hi');
  });
}
