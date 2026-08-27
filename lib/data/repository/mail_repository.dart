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

/// The outcome of a bulk [MailRepository.moveMessages]/[MailRepository.deleteMessages]
/// call: proceed-and-report, not all-or-nothing — some messages in a batch
/// can succeed while others fail. [failed] is keyed by message id.
class BulkResult {
  const BulkResult({required this.succeeded, required this.failed});

  final List<MailMessage> succeeded;
  final Map<int, Object> failed;
}

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

  /// Recomputes [folderId]'s unread count from the messages actually
  /// present locally and persists it. The transport layer never populates
  /// `MailFolder.unreadCount` (no extra IMAP round trip for it — see the
  /// design spec's "no extra sync" property for `totalUnreadCountProvider`),
  /// so this is the only place that count is ever kept truthful: called
  /// after anything that changes what "unread" means for a folder (new
  /// headers arriving, a read/unread flip, or a message moving in/out).
  Future<void> _refreshUnreadCount(int folderId) async {
    final unread = await _messageDao.countUnread(folderId);
    await _folderDao.updateUnreadCount(folderId, unread);
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
    //
    // Re-read the folder row from the DB rather than trusting the `folder`
    // argument: callers (e.g. messagesProvider) pass a MailFolder snapshotted
    // whenever foldersProvider last ran, which can be stale by the time this
    // method runs again later in the same session — the watermark this method
    // itself just wrote on a prior call would otherwise never be seen.
    final current = await _folderDao.getById(folder.id!);
    final sinceUid = current?.lastSyncedUid ?? folder.lastSyncedUid;
    final newHeaders = await _transport.fetchHeadersSince(account, password, folder, sinceUid);
    if (newHeaders.isNotEmpty) {
      await _messageDao.upsertHeaders(newHeaders);
      final maxFetchedUid = newHeaders.map((m) => m.uid).reduce((a, b) => a > b ? a : b);
      if (maxFetchedUid > sinceUid) {
        await _folderDao.updateLastSyncedUid(folder.id!, maxFetchedUid);
      }
    }
    // Recomputed unconditionally, not only when newHeaders is non-empty:
    // an is_read change made server-side (or by markRead, whose own
    // optimistic write already recomputes) can otherwise leave a stale
    // count sitting in the folder row indefinitely whenever a sync finds no
    // new mail. A local COUNT(*) query is not the "extra sync" the design
    // spec rules out — that refers to IMAP round trips, not local DB reads.
    await _refreshUnreadCount(folder.id!);
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
    try {
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
    } on MessageNotFoundException {
      // Confirmed gone from the server — deleted (or expunged) on another
      // device before this device's cached header row caught up. The local
      // row is now permanently stale: drop it so a Retry (or reopening the
      // folder) doesn't keep hitting the same "gone" fetch forever, and so
      // the folder's unread count doesn't stay off if it was unread.
      await _messageDao.deleteMessage(current.id!);
      await _refreshUnreadCount(folder.id!);
      rethrow;
    }
  }

  /// Moves [message] from [from] to [to], locally and on the server.
  /// Optimistic: the local row moves first (instant UI feedback), then the
  /// server-side move happens; once the server confirms with a new UID, the
  /// local row is corrected to use it (so a subsequent move — e.g. an Undo
  /// — addresses the right message). On failure, the local move is reverted
  /// and the error rethrown so callers can retry.
  Future<MailMessage> moveMessage(
    MailAccount account,
    MailFolder from,
    MailFolder to,
    MailMessage message,
  ) async {
    await _messageDao.moveToFolder(message.id!, to.id!);
    // A message leaving `from` and landing in `to` changes both folders'
    // true unread counts (if it was unread) — recompute both, not just the
    // one this call happens to be "about".
    await _refreshUnreadCount(from.id!);
    await _refreshUnreadCount(to.id!);
    try {
      final password = await _passwordFor(account);
      final newUid = await _transport.moveMessage(account, password, from, message, to);
      if (newUid != null) {
        await _messageDao.moveToFolder(message.id!, to.id!, newUid: newUid);
      }
      return message.copyWith(folderId: to.id!, uid: newUid ?? message.uid);
    } catch (_) {
      // Restore the ORIGINAL uid explicitly. `message` is the untouched
      // method parameter (never reassigned above), so message.uid is still
      // the pre-move value. Reverting without it would make
      // MessageDao.moveToFolder synthesize a fresh negative placeholder,
      // permanently destroying the message's real server UID on every
      // failed move — i.e. exactly the offline/server-error case this
      // revert exists for.
      await _messageDao.moveToFolder(message.id!, from.id!, newUid: message.uid);
      await _refreshUnreadCount(from.id!);
      await _refreshUnreadCount(to.id!);
      rethrow;
    }
  }

  /// Moves [message] to the account's Archive folder. Throws [StateError]
  /// if the account has no Archive folder — nothing is moved in that case.
  Future<MailMessage> archiveMessage(
    MailAccount account,
    MailFolder currentFolder,
    MailMessage message,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final archiveFolder = folders.where((f) => f.type == MailFolderType.archive).firstOrNull;
    if (archiveFolder == null) {
      throw StateError('No Archive folder found for account ${currentFolder.accountId}');
    }
    return moveMessage(account, currentFolder, archiveFolder, message);
  }

  /// Whether [message] carries a UID the IMAP server would actually
  /// recognise. Negative uids are this codebase's synthetic local
  /// placeholders (see [MessageDao.moveToFolder] / [MessageDao.insertLocal])
  /// — assigned to locally-created rows, and to moved rows whose server
  /// didn't report a post-move UID (no UIDPLUS/`COPYUID`). Addressing the
  /// server with one would send a meaningless `UID STORE -1 ...`, which
  /// `MessageSequence.fromId` does not validate.
  static bool _hasServerUid(MailMessage message) => message.uid >= 0;

  /// Marks a message's read status both locally and on the IMAP server.
  /// Optimistic: the local row updates first, then the `\Seen` flag is
  /// stored on the server. On failure the local row is reverted to its
  /// prior value and the error rethrown.
  ///
  /// Set [revertLocalOnFailure] to false for call sites that have no retry
  /// affordance (the automatic mark-read-when-opened path): those still
  /// attempt the server sync and still rethrow, but keep the local read
  /// flag so reading a cached message offline isn't silently undone.
  Future<void> markRead(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    bool isRead, {
    bool revertLocalOnFailure = true,
  }) async {
    final previous = message.isRead;
    await _messageDao.updateReadStatus(message.id!, isRead);
    await _refreshUnreadCount(folder.id!);
    // Local-only/placeholder-uid rows have nothing addressable on the
    // server; the local write above is the whole operation.
    if (!_hasServerUid(message)) return;
    try {
      final password = await _passwordFor(account);
      await _transport.setSeen(account, password, folder, message, isRead);
    } catch (_) {
      if (revertLocalOnFailure) {
        await _messageDao.updateReadStatus(message.id!, previous);
        // The persisted unread_count must always match whatever is_read
        // state actually ended up persisted — including a reverted one.
        await _refreshUnreadCount(folder.id!);
      }
      rethrow;
    }
  }

  /// Same optimistic-then-revert-on-failure pattern as [markRead], for the
  /// `\Flagged` flag.
  Future<void> markFlagged(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    bool isFlagged,
  ) async {
    final previous = message.isFlagged;
    await _messageDao.updateFlagStatus(message.id!, isFlagged);
    // See markRead: never address the server with a synthetic uid.
    if (!_hasServerUid(message)) return;
    try {
      final password = await _passwordFor(account);
      await _transport.setFlagged(account, password, folder, message, isFlagged);
    } catch (_) {
      await _messageDao.updateFlagStatus(message.id!, previous);
      rethrow;
    }
  }

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

  /// Deletes a message by moving it to Trash (locally and on the server), or
  /// permanently removing it locally when there's no Trash folder to move it
  /// to, or when it's already in Trash. Those permanent-removal branches
  /// stay local-only — deliberately: this app doesn't implement IMAP
  /// permanent delete (STORE \Deleted + EXPUNGE), only the move-based path
  /// that's the day-to-day case. Returns the resulting message so callers
  /// can tell which branch ran (`result.folderId != currentFolder.id` means
  /// it moved to Trash).
  Future<MailMessage> deleteMessage(
    MailAccount account,
    MailFolder currentFolder,
    MailMessage message,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final trashFolder = folders.where((f) => f.type == MailFolderType.trash).firstOrNull;
    if (trashFolder != null && trashFolder.id != currentFolder.id) {
      return moveMessage(account, currentFolder, trashFolder, message);
    }
    await _messageDao.deleteMessage(message.id!);
    // Permanently removing a message changes currentFolder's true unread
    // count too (the moveMessage branch above already handles this for the
    // move-to-Trash case via its own recompute of both folders).
    await _refreshUnreadCount(currentFolder.id!);
    return message;
  }

  /// Bulk version of [moveMessage]: moves every message in [messages] from
  /// [from] to [to], batched over a single [MailTransport] connection
  /// (`_transport.moveMessages`) rather than one connection per message.
  /// Proceed-and-report: one message's server-side failure reverts only
  /// that message, not the rest of the batch (see [BulkResult]).
  Future<BulkResult> moveMessages(
    MailAccount account,
    MailFolder from,
    MailFolder to,
    List<MailMessage> messages,
  ) async {
    for (final message in messages) {
      await _messageDao.moveToFolder(message.id!, to.id!);
    }
    await _refreshUnreadCount(from.id!);
    await _refreshUnreadCount(to.id!);

    Map<int, int?> newUids;
    try {
      final password = await _passwordFor(account);
      newUids = await _transport.moveMessages(account, password, from, messages, to);
    } catch (_) {
      // The whole batch's connection/setup failed before any per-message
      // result could be determined (offline, destination not found, etc.)
      // — treat every message in the batch as failed.
      newUids = const {};
    }

    final succeeded = <MailMessage>[];
    final failed = <int, Object>{};
    for (final message in messages) {
      final id = message.id!;
      if (newUids.containsKey(id)) {
        final newUid = newUids[id];
        if (newUid != null) {
          await _messageDao.moveToFolder(id, to.id!, newUid: newUid);
        }
        succeeded.add(message.copyWith(folderId: to.id!, uid: newUid ?? message.uid));
      } else {
        failed[id] = StateError('Failed to move message $id to ${to.name}');
        // Restore the ORIGINAL uid, exactly like moveMessage's single-message
        // revert — never let MessageDao.moveToFolder synthesize a fresh
        // placeholder and destroy the message's real server uid.
        await _messageDao.moveToFolder(id, from.id!, newUid: message.uid);
      }
    }
    await _refreshUnreadCount(from.id!);
    await _refreshUnreadCount(to.id!);
    return BulkResult(succeeded: succeeded, failed: failed);
  }

  /// Bulk version of [deleteMessage]: moves every message in [messages] to
  /// Trash via [moveMessages], or permanently removes them all locally when
  /// there's no Trash folder to move them to, or when [currentFolder] is
  /// already Trash — same fallback rules as [deleteMessage], applied once
  /// for the whole batch (they depend only on the account/folder, not on
  /// which messages are selected).
  Future<BulkResult> deleteMessages(
    MailAccount account,
    MailFolder currentFolder,
    List<MailMessage> messages,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final trashFolder = folders.where((f) => f.type == MailFolderType.trash).firstOrNull;
    if (trashFolder != null && trashFolder.id != currentFolder.id) {
      return moveMessages(account, currentFolder, trashFolder, messages);
    }
    for (final message in messages) {
      await _messageDao.deleteMessage(message.id!);
    }
    await _refreshUnreadCount(currentFolder.id!);
    return BulkResult(succeeded: messages, failed: const {});
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
