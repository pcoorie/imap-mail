import 'package:collection/collection.dart';
import 'package:enough_mail/enough_mail.dart' as enough;
import '../../models/enums.dart';
import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';
import 'mail_message_mapper.dart';
import 'mail_transport.dart';

// NOTE: both our own domain model and enough_mail export a class named
// `MailAccount`. The enough_mail import is aliased to `enough` throughout
// this file specifically to keep that unambiguous — do not remove the alias.
class EnoughMailTransport implements MailTransport {
  enough.MailAccount _toEnoughAccount(MailAccount account, String password) {
    return enough.MailAccount.fromManualSettings(
      name: account.displayName,
      email: account.email,
      incomingHost: account.imapHost,
      incomingPort: account.imapPort,
      incomingSocketType: _toSocketType(account.imapSecurity),
      outgoingHost: account.smtpHost,
      outgoingPort: account.smtpPort,
      outgoingSocketType: _toSocketType(account.smtpSecurity),
      password: password,
      userName: account.displayName,
      loginName: account.username,
    );
  }

  enough.SocketType _toSocketType(MailSecurity security) {
    switch (security) {
      case MailSecurity.ssl:
        return enough.SocketType.ssl;
      case MailSecurity.startTls:
        return enough.SocketType.starttls;
      case MailSecurity.none:
        return enough.SocketType.plain;
    }
  }

  @override
  Future<void> testConnection(MailAccount account, String password) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<List<MailFolder>> discoverFolders(
    MailAccount account,
    String password,
    int accountId,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      final mailboxes = await client.listMailboxes();
      return mailboxes.map((box) {
        return MailFolder(
          accountId: accountId,
          name: box.name,
          path: box.path,
          type: _folderTypeFor(box),
        );
      }).toList();
    } finally {
      await client.disconnect();
    }
  }

  MailFolderType _folderTypeFor(enough.Mailbox box) {
    if (box.isInbox) return MailFolderType.inbox;
    if (box.isSent) return MailFolderType.sent;
    if (box.isTrash) return MailFolderType.trash;
    if (box.isArchive) return MailFolderType.archive;
    return MailFolderType.other;
  }

  @override
  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      // Intent: "all UIDs greater than sinceUid in this mailbox". Verified
      // against the installed enough_mail 2.1.7 API
      // (MessageSequence.fromRangeToLast(start, {isUidSequence})).
      final sequence = enough.MessageSequence.fromRangeToLast(
        sinceUid + 1,
        isUidSequence: true,
      );
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.envelope,
      );
      return mimeMessages
          .map((mime) => mapMimeMessageToRecord(mime, folderId: folder.id!))
          .toList();
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.full,
      );
      // An empty result means the UID is no longer in the mailbox — most
      // commonly because the message was deleted on another device before
      // this device's cached header row caught up. Without this check,
      // `.first` throws a bare, unhelpful StateError('No element').
      if (mimeMessages.isEmpty) {
        throw MessageNotFoundException(message.uid);
      }
      return mapMimeMessageToRecord(mimeMessages.first, folderId: folder.id!)
          .copyWith(id: message.id);
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.full,
      );
      // See fetchBody: an empty result means the UID no longer exists.
      if (mimeMessages.isEmpty) {
        throw MessageNotFoundException(message.uid);
      }
      final mime = mimeMessages.first;
      // Match by decoded filename rather than assuming fetch-id ordering.
      // NOTE: deviates from the brief's `mime.getAttachments()` /
      // `part.decodeFileName()`, which does not exist on the installed
      // enough_mail 2.1.7 API. Instead: findContentInfo() enumerates the
      // attachment-disposition parts (each with an already-decoded
      // `fileName` and a `fetchId`), and getPart(fetchId) resolves the
      // matching MimePart so we can decode its binary content. Same intent:
      // find the attachment part by matching filename.
      final infos = mime.findContentInfo(
        disposition: enough.ContentDisposition.attachment,
      );
      final info = infos
          .where((candidate) => candidate.fileName == attachment.filename)
          .firstOrNull;
      if (info == null) return const [];
      final part = mime.getPart(info.fetchId);
      return part?.decodeContentBinary() ?? const [];
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<List<MailAttachment>> fetchAttachmentList(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.full,
      );
      // See fetchBody: an empty result means the UID no longer exists.
      if (mimeMessages.isEmpty) {
        throw MessageNotFoundException(message.uid);
      }
      return mapMimeMessageAttachments(mimeMessages.first, messageId: message.id!);
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<void> setSeen(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      await client.store(
        sequence,
        [enough.MessageFlags.seen],
        action: value ? enough.StoreAction.add : enough.StoreAction.remove,
      );
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<void> setFlagged(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      await client.store(
        sequence,
        [enough.MessageFlags.flagged],
        action: value ? enough.StoreAction.add : enough.StoreAction.remove,
      );
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<int?> moveMessage(
    MailAccount account,
    String password,
    MailFolder source,
    MailMessage message,
    MailFolder destination,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      // Resolve the destination Mailbox object without selecting it (that
      // would change the client's active mailbox away from the source,
      // which moveMessages needs selected as the move-from mailbox).
      final mailboxes = await client.listMailboxes();
      final targetMailbox = mailboxes.firstWhereOrNull((box) => box.path == destination.path);
      if (targetMailbox == null) {
        throw StateError('Destination folder ${destination.path} not found on server');
      }
      await client.selectMailboxByPath(source.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final result = await client.moveMessages(sequence, targetMailbox);
      return result.targetSequence?.toList().firstOrNull;
    } finally {
      await client.disconnect();
    }
  }
}
