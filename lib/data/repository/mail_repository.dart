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

class MailRepository {
  MailRepository(
    this._folderDao,
    this._messageDao,
    this._attachmentDao,
    this._transport,
    this._credentialStore,
  );

  final FolderDao _folderDao;
  final MessageDao _messageDao;
  final AttachmentDao _attachmentDao;
  final MailTransport _transport;
  final SecureCredentialStore _credentialStore;

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
}
