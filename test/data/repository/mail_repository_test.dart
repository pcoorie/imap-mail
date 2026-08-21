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
import 'package:imap_mail/models/mail_attachment.dart';
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

  test('syncHeaders fetches only messages after the folder\'s last synced uid', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    var folder = (await folderDao.getById(folderId))!;
    // Establish the uid-5 watermark through a real sync (not a direct DAO
    // write), since the watermark now lives on the folder row, independent
    // of which message rows are physically present.
    when(() => transport.fetchHeadersSince(any(), any(), any(), 0)).thenAnswer((_) async => [
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
    await repository.syncHeaders(account, folder);
    folder = (await folderDao.getById(folderId))!;
    expect(folder.lastSyncedUid, 5);

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

  test(
      'syncHeaders does not regress the sync watermark after the newest message is moved out of the folder (deleteMessage)',
      () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    var folder = (await folderDao.getById(folderId))!;
    when(() => transport.fetchHeadersSince(any(), any(), any(), 0)).thenAnswer((_) async => [
          MailMessage(
            folderId: folderId,
            uid: 5,
            subject: 'Only message',
            from: 'a@example.com',
            to: 'me@example.com',
            date: DateTime.utc(2026, 1, 1),
            snippet: 'only',
          ),
        ]);
    await repository.syncHeaders(account, folder);
    folder = (await folderDao.getById(folderId))!;
    expect(folder.lastSyncedUid, 5);

    // Read the top message, then delete it — the common case. This moves
    // the folder's only (and therefore highest-uid) message out to Trash.
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => null);
    await repository.deleteMessage(account.copyWith(id: accountId), folder, message);
    expect(await messageDao.getForFolder(folderId), isEmpty);
    // If the watermark were derived from getMaxUid(folderId) on live rows,
    // it would now read back as 0 (folder is empty) instead of 5.
    folder = (await folderDao.getById(folderId))!;
    expect(folder.lastSyncedUid, 5);

    when(() => transport.fetchHeadersSince(any(), any(), any(), 5)).thenAnswer((_) async => []);

    await repository.syncHeaders(account, folder);

    verify(() => transport.fetchHeadersSince(any(), any(), any(), 5)).called(1);
    // The re-fetched/re-inserted message must not have resurrected in
    // either the original folder or in Trash.
    expect(await messageDao.getForFolder(folderId), isEmpty);
    expect(await messageDao.getForFolder(trashFolderId), hasLength(1));
  });

  test(
      'syncHeaders reads the persisted watermark even when the caller passes a stale MailFolder object '
      '(matches production: callers reuse a folder snapshot across calls rather than re-reading it)',
      () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    // This is the folder snapshot a caller (e.g. messagesProvider's family
    // key) would hold — captured once, never re-read from the DB between
    // calls, exactly like production.
    final staleFolder = (await folderDao.getById(folderId))!;

    when(() => transport.fetchHeadersSince(any(), any(), any(), 0)).thenAnswer((_) async => [
          MailMessage(
            folderId: folderId,
            uid: 5,
            subject: 'Only message',
            from: 'a@example.com',
            to: 'me@example.com',
            date: DateTime.utc(2026, 1, 1),
            snippet: 'only',
          ),
        ]);
    // First sync advances the persisted watermark to 5, but staleFolder
    // (still lastSyncedUid: 0) is never updated to reflect that.
    await repository.syncHeaders(account, staleFolder);

    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => null);
    await repository.deleteMessage(account.copyWith(id: accountId), staleFolder, message);
    expect(await messageDao.getForFolder(folderId), isEmpty);

    when(() => transport.fetchHeadersSince(any(), any(), any(), 5)).thenAnswer((_) async => []);

    // Second sync passes the SAME staleFolder object (lastSyncedUid: 0 in
    // memory) — if syncHeaders trusted that argument instead of re-reading
    // the DB, this second call would ALSO fetch from sinceUid: 0 (a second
    // call with 0, on top of the first sync's legitimate one) and resurrect
    // the message. Re-reading the DB means the second call uses 5 instead.
    await repository.syncHeaders(account, staleFolder);

    // sinceUid: 0 called exactly once — only by the first sync above, not
    // repeated by the second call trusting the stale in-memory value.
    verify(() => transport.fetchHeadersSince(any(), any(), any(), 0)).called(1);
    verify(() => transport.fetchHeadersSince(any(), any(), any(), 5)).called(1);
    expect(await messageDao.getForFolder(folderId), isEmpty);
    expect(await messageDao.getForFolder(trashFolderId), hasLength(1));
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
    when(() => transport.fetchAttachmentList(any(), any(), any(), any()))
        .thenAnswer((_) async => <MailAttachment>[]);

    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    expect(result.bodyText, 'fetched body');
    final refetched = await messageDao.getById(cached.id!);
    expect(refetched!.bodyText, 'fetched body');
  });

  test('fetchBodyIfNeeded persists attachment metadata when fetching a not-yet-downloaded message with attachments', () async {
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
    when(() => transport.fetchAttachmentList(any(), any(), any(), any())).thenAnswer(
      (_) async => [
        MailAttachment(
          messageId: cached.id!,
          filename: 'report.pdf',
          mimeType: 'application/pdf',
          size: 1234,
        ),
      ],
    );

    await repository.fetchBodyIfNeeded(account, folder, cached);

    final attachments = await repository.getAttachments(cached.id!);
    expect(attachments, hasLength(1));
    expect(attachments.first.filename, 'report.pdf');
    expect(attachments.first.mimeType, 'application/pdf');
    expect(attachments.first.size, 1234);
  });

  test(
      'fetchBodyIfNeeded does not re-fetch when the passed-in message object is stale (its own isDownloaded is false) but the DB row is already downloaded',
      () async {
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
    when(() => transport.fetchAttachmentList(any(), any(), any(), any()))
        .thenAnswer((_) async => <MailAttachment>[]);

    // First open: not yet downloaded, so this legitimately fetches.
    await repository.fetchBodyIfNeeded(account, folder, cached);

    // Second open: simulates a stale cached provider list where the passed
    // object's own isDownloaded is still false (never refreshed), even
    // though the DB row backing it is now downloaded. Must not re-fetch.
    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    // Only ever fetched once in total, across both calls.
    verify(() => transport.fetchBody(any(), any(), any(), any())).called(1);
    verify(() => transport.fetchAttachmentList(any(), any(), any(), any())).called(1);
    expect(result.bodyText, 'fetched body');
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

  test('markRead marks the message read locally and on the server', () async {
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
    final message = (await messageDao.getForFolder(folderId)).first;
    expect(message.isRead, isFalse);
    when(() => transport.setSeen(any(), any(), any(), any(), any())).thenAnswer((_) async {});

    await repository.markRead(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(message.id!))!.isRead, isTrue);
    verify(() => transport.setSeen(any(), any(), any(), message, true)).called(1);
  });

  test('markRead reverts the local change and rethrows when the server call fails', () async {
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
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setSeen(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.markRead(account.copyWith(id: accountId), folder, message, true),
      throwsException,
    );

    expect((await messageDao.getById(message.id!))!.isRead, isFalse);
    // A revert must never disturb the message's identity on the server.
    expect((await messageDao.getById(message.id!))!.uid, 1);
  });

  test(
      'markRead with revertLocalOnFailure: false keeps the local read flag when the server call fails (still rethrows)',
      () async {
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
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setSeen(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.markRead(
        account.copyWith(id: accountId),
        folder,
        message,
        true,
        revertLocalOnFailure: false,
      ),
      throwsException,
    );

    // The server sync was still attempted...
    verify(() => transport.setSeen(any(), any(), any(), any(), any())).called(1);
    // ...but the local read flag stands (this is the auto-mark-read-on-open
    // call site's behavior: no Retry affordance, so reverting would silently
    // undo the user's read state while offline).
    expect((await messageDao.getById(message.id!))!.isRead, isTrue);
  });

  test('markRead on a message with a synthetic (negative) uid skips the server round-trip', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final folder = (await folderDao.getById(folderId))!;
    // insertLocal always assigns a synthetic negative placeholder uid — the
    // same convention moveToFolder uses when the server reports no new UID.
    final messageId = await messageDao.insertLocal(MailMessage(
      folderId: folderId,
      uid: 0,
      subject: 'Subject',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'snippet',
    ));
    final message = (await messageDao.getById(messageId))!;
    expect(message.uid, lessThan(0));

    await repository.markRead(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(messageId))!.isRead, isTrue);
    verifyNever(() => transport.setSeen(any(), any(), any(), any(), any()));
  });

  test('markFlagged on a message with a synthetic (negative) uid skips the server round-trip', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final folder = (await folderDao.getById(folderId))!;
    final messageId = await messageDao.insertLocal(MailMessage(
      folderId: folderId,
      uid: 0,
      subject: 'Subject',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'snippet',
    ));
    final message = (await messageDao.getById(messageId))!;
    expect(message.uid, lessThan(0));

    await repository.markFlagged(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(messageId))!.isFlagged, isTrue);
    verifyNever(() => transport.setFlagged(any(), any(), any(), any(), any()));
  });

  test('markFlagged flags the message locally and on the server', () async {
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
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setFlagged(any(), any(), any(), any(), any())).thenAnswer((_) async {});

    await repository.markFlagged(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(message.id!))!.isFlagged, isTrue);
    verify(() => transport.setFlagged(any(), any(), any(), message, true)).called(1);
  });

  test('markFlagged reverts the local change and rethrows when the server call fails', () async {
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
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setFlagged(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.markFlagged(account.copyWith(id: accountId), folder, message, true),
      throwsException,
    );

    expect((await messageDao.getById(message.id!))!.isFlagged, isFalse);
    // A revert must never disturb the message's identity on the server.
    expect((await messageDao.getById(message.id!))!.uid, 1);
  });

  test('archiveMessage moves the message to Archive locally and on the server, and adopts the server\'s new uid', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final archiveFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => 42);

    final result = await repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(result.folderId, archiveFolderId);
    expect(result.uid, 42);
    final archived = await messageDao.getForFolder(archiveFolderId);
    expect(archived, hasLength(1));
    expect(archived.first.uid, 42);
    expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
  });

  test('archiveMessage throws and leaves the message in place when the account has no Archive folder', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;

    await expectLater(
      repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsA(isA<StateError>()),
    );

    expect(await messageDao.getForFolder(inboxFolderId), hasLength(1));
  });

  test('archiveMessage reverts the local move and rethrows when the server call fails', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final archiveFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsException,
    );

    final reverted = await messageDao.getForFolder(inboxFolderId);
    expect(reverted, hasLength(1));
    expect(await messageDao.getForFolder(archiveFolderId), isEmpty);
    // The revert must restore the message's ORIGINAL uid. Reverting without
    // one makes MessageDao.moveToFolder synthesize a negative placeholder,
    // permanently losing the real UID: every later fetchBody/flag/mark-read/
    // move on this row would then issue `UID FETCH -1` and fail, and
    // syncHeaders never repairs it (it only fetches above the watermark).
    expect(reverted.first.uid, 5);
    expect((await messageDao.getById(message.id!))!.uid, 5);
  });

  test('deleteMessage moves the message to Trash locally and on the server when a Trash folder exists and it isn\'t already there', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => 77);

    final result = await repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(result.folderId, trashFolderId);
    final trashMessages = await messageDao.getForFolder(trashFolderId);
    expect(trashMessages, hasLength(1));
    expect(trashMessages.first.id, message.id);
    final inboxMessages = await messageDao.getForFolder(inboxFolderId);
    expect(inboxMessages, isEmpty);
  });

  test('deleteMessage permanently removes the message locally (no server call) when no Trash folder exists', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;

    await repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(await messageDao.getById(message.id!), isNull);
    expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
    verifyNever(() => transport.moveMessage(any(), any(), any(), any(), any()));
  });

  test('deleteMessage permanently removes the message locally (no server call) when it is already in the Trash folder', () async {
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final trashFolder = (await folderDao.getById(trashFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: trashFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(trashFolderId)).first;

    await repository.deleteMessage(account.copyWith(id: accountId), trashFolder, message);

    expect(await messageDao.getById(message.id!), isNull);
    expect(await messageDao.getForFolder(trashFolderId), isEmpty);
    verifyNever(() => transport.moveMessage(any(), any(), any(), any(), any()));
  });

  test('deleteMessage reverts the local move and rethrows when the server call fails', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsException,
    );

    final reverted = await messageDao.getForFolder(inboxFolderId);
    expect(reverted, hasLength(1));
    expect(await messageDao.getForFolder(trashFolderId), isEmpty);
    // See the archive revert test above: the original uid must survive.
    expect(reverted.first.uid, 1);
    expect((await messageDao.getById(message.id!))!.uid, 1);
  });

  test(
      'a failed move restores the original uid even when the source folder already holds a synthetic-uid message '
      '(the placeholder the buggy revert would have synthesized)',
      () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final archiveFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 9,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    // A pre-existing local-only row in the same folder pushes the synthetic
    // uid the buggy revert path would pick down to -2, so this test would
    // still catch the bug even if -1 happened to collide with something.
    await messageDao.insertLocal(MailMessage(
      folderId: inboxFolderId,
      uid: 0,
      subject: 'Local draft',
      from: 'me@example.com',
      to: 'b@example.com',
      date: DateTime.utc(2026, 8, 18),
      snippet: 'draft',
    ));
    final message = (await messageDao.getForFolder(inboxFolderId)).firstWhere((m) => m.subject == 'Subject');
    expect(message.uid, 9);
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsException,
    );

    final refreshed = (await messageDao.getById(message.id!))!;
    expect(refreshed.folderId, inboxFolderId);
    expect(refreshed.uid, 9, reason: 'uid must be restored as-is, never re-synthesized');
    expect(await messageDao.getForFolder(archiveFolderId), isEmpty);
  });
}
