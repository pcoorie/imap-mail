import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';

/// Bundles a message with the folder and account it belongs to. Produced by
/// `unifiedInboxProvider`, which merges every account's Inbox into one
/// chronological list — without this, a merged row would need to re-look-up
/// its own account/folder by id (folderId only tells you a local database
/// row, not which account owns it) before anything (opening the message,
/// swiping, resolving a color) could act on it correctly.
class UnifiedMessage {
  const UnifiedMessage({required this.message, required this.folder, required this.account});

  final MailMessage message;
  final MailFolder folder;
  final MailAccount account;
}
