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
    // Use the folder's persisted high-water mark, not the max uid among rows
    // currently present in the folder: deleting/moving the newest message
    // out of the folder must never lower the sync watermark, or the next
    // sync will re-fetch and re-insert it (duplicating it wherever it moved).
    final sinceUid = folder.lastSyncedUid;
    final newHeaders = await _transport.fetchHeadersSince(account, password, folder, sinceUid);
    if (newHeaders.isNotEmpty) {
      await _messageDao.upsertHeaders(newHeaders);
      final maxFetchedUid = newHeaders.map((m) => m.uid).reduce((a, b) => a > b ? a : b);
      if (maxFetchedUid > sinceUid) {
        await _folderDao.updateLastSyncedUid(folder.id!, maxFetchedUid);
      }
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
    var current = message;
    if (!current.isDownloaded && current.id != null) {
      // The passed-in message may come from a cached provider list that was
      // never invalidated after a previous body fetch. Fall back to the
      // freshly-read DB row's actual isDownloaded state before deciding
      // whether a fetch is really needed, so re-opening an already-fetched
      // message doesn't re-hit IMAP and re-insert its attachments.
      final dbRow = await _messageDao.getById(current.id!);
      if (dbRow != null) {
        current = dbRow;
      }
    }
    if (current.isDownloaded) {
      return current;
    }
    final password = await _passwordFor(account);
    final fetched = await _transport.fetchBody(account, password, folder, current);
    await _messageDao.updateBody(
      current.id!,
      bodyText: fetched.bodyText,
      bodyHtml: fetched.bodyHtml,
    );
    final attachments = await _transport.fetchAttachmentList(account, password, folder, current);
    if (attachments.isNotEmpty) {
      await _attachmentDao.insertAll(attachments);
    }
    return fetched;
  }

  /// Marks a message as read locally. Deliberately minimal: folder-level
  /// unread COUNTS are not recalculated here (see FolderDao/discoverFolders
  /// — that's a larger, deliberately deferred feature; see final review
  /// report).
  Future<void> markAsRead(int messageId) => _messageDao.updateReadStatus(messageId, true);

  Future<List<MailAttachment>> getAttachments(int messageId) {
    return _attachmentDao.getForMessage(messageId);
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

    try {
      final folders = await _folderDao.getForAccount(account.id!);
      final sentFolder = folders.where((f) => f.type == MailFolderType.sent).firstOrNull;
      if (sentFolder != null) {
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
      }
    } catch (_) {
      // Best-effort local cache write; the send itself already succeeded.
    }
  }

  Future<void> deleteMessage(MailFolder currentFolder, MailMessage message) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final trashFolder = folders.where((f) => f.type == MailFolderType.trash).firstOrNull;
    if (trashFolder != null && trashFolder.id != currentFolder.id) {
      await _messageDao.moveToFolder(message.id!, trashFolder.id!);
    } else {
      await _messageDao.deleteMessage(message.id!);
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
