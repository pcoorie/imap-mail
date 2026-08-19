import 'package:collection/collection.dart';

import '../../models/enums.dart';
import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';
import '../local/attachment_dao.dart';
import '../local/folder_dao.dart';
import '../local/message_dao.dart';
import '../secure/credential_store.dart';
import '../transport/mail_transport.dart';
import '../transport/mail_sender.dart';

class MailRepository {
  MailRepository(
    this._folderDao,
    this._messageDao,
    this._attachmentDao,
    this._transport,
    this._credentialStore,
    this._sender,
  );

  final FolderDao _folderDao;
  final MessageDao _messageDao;
  final AttachmentDao _attachmentDao;
  final MailTransport _transport;
  final SecureCredentialStore _credentialStore;
  final MailSender _sender;

  Future<String> _passwordFor(MailAccount account) async {
    final password = await _credentialStore.getPassword(account.id!);
    if (password == null) {
      throw StateError('No stored password for account ${account.id}');
    }
    return password;
  }

  Future<int> ensureOutboxFolder(int accountId) async {
    return _folderDao.upsert(MailFolder(
      accountId: accountId,
      name: 'Outbox',
      path: 'Outbox',
      type: MailFolderType.other,
      isLocalOnly: true,
    ));
  }

  Future<List<MailFolder>> syncFolders(MailAccount account) async {
    final password = await _passwordFor(account);
    final discovered = await _transport.discoverFolders(account, password, account.id!);
    for (final folder in discovered) {
      await _folderDao.upsert(folder);
    }
    await ensureOutboxFolder(account.id!);
    return _folderDao.getForAccount(account.id!);
  }

  Future<List<MailFolder>> getCachedFolders(int accountId) {
    return _folderDao.getForAccount(accountId);
  }

  Future<List<MailMessage>> syncHeaders(MailAccount account, MailFolder folder) async {
    if (folder.isLocalOnly) {
      return _messageDao.getForFolder(folder.id!);
    }
    final password = await _passwordFor(account);
    final sinceUid = await _messageDao.getMaxUid(folder.id!);
    final newHeaders = await _transport.fetchHeadersSince(account, password, folder, sinceUid);
    if (newHeaders.isNotEmpty) {
      await _messageDao.upsertHeaders(newHeaders);
    }
    return _messageDao.getForFolder(folder.id!);
  }

  Future<List<MailMessage>> getCachedMessages(int folderId) {
    return _messageDao.getForFolder(folderId);
  }

  Future<MailMessage> fetchBodyIfNeeded(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
  ) async {
    if (message.isDownloaded) {
      return message;
    }
    final password = await _passwordFor(account);
    final fetched = await _transport.fetchBody(account, password, folder, message);
    await _messageDao.updateBody(
      message.id!,
      bodyText: fetched.bodyText,
      bodyHtml: fetched.bodyHtml,
    );
    return fetched;
  }

  Future<List<int>> downloadAttachment(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async {
    final password = await _passwordFor(account);
    return _transport.fetchAttachmentBytes(account, password, folder, message, attachment);
  }

  Future<void> recordAttachmentLocalPath(int attachmentId, String localPath) {
    return _attachmentDao.updateLocalPath(attachmentId, localPath);
  }

  Future<void> sendMessage(MailAccount account, ComposedMessage composed) async {
    final password = await _passwordFor(account);
    try {
      await _sender.send(account, password, composed);
    } catch (_) {
      final outboxId = await ensureOutboxFolder(account.id!);
      await _messageDao.insertLocal(MailMessage(
        folderId: outboxId,
        uid: 0,
        subject: composed.subject,
        from: account.email,
        to: composed.to.join(', '),
        date: DateTime.now().toUtc(),
        snippet: composed.bodyText.length > 140
            ? composed.bodyText.substring(0, 140)
            : composed.bodyText,
        bodyText: composed.bodyText,
        bodyHtml: composed.bodyHtml,
        isRead: true,
        isDownloaded: true,
        sendStatus: MailSendStatus.failed,
      ));
      rethrow;
    }

    final folders = await _folderDao.getForAccount(account.id!);
    final sentFolder = folders.where((f) => f.type == MailFolderType.sent).firstOrNull;
    if (sentFolder != null) {
      try {
        await _messageDao.insertLocal(MailMessage(
          folderId: sentFolder.id!,
          uid: 0,
          subject: composed.subject,
          from: account.email,
          to: composed.to.join(', '),
          date: DateTime.now().toUtc(),
          snippet: composed.bodyText.length > 140
              ? composed.bodyText.substring(0, 140)
              : composed.bodyText,
          bodyText: composed.bodyText,
          bodyHtml: composed.bodyHtml,
          isRead: true,
          isDownloaded: true,
          sendStatus: MailSendStatus.sent,
        ));
      } catch (_) {
        // Best-effort local cache write; the send itself already succeeded.
      }
    }
  }

  Future<void> retryFailedMessage(MailAccount account, MailMessage failedMessage) async {
    final composed = ComposedMessage(
      to: failedMessage.to.split(', ').where((e) => e.isNotEmpty).toList(),
      cc: const [],
      bcc: const [],
      subject: failedMessage.subject,
      bodyText: failedMessage.bodyText ?? '',
      bodyHtml: failedMessage.bodyHtml,
      attachmentFilePaths: const [],
    );
    await sendMessage(account, composed);
    await _messageDao.deleteMessage(failedMessage.id!);
  }
}
