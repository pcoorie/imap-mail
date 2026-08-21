import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';

abstract class MailTransport {
  Future<void> testConnection(MailAccount account, String password);

  Future<List<MailFolder>> discoverFolders(
    MailAccount account,
    String password,
    int accountId,
  );

  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  );

  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  );

  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  );

  Future<List<MailAttachment>> fetchAttachmentList(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  );

  Future<void> setSeen(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  );

  Future<void> setFlagged(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  );

  /// Moves [message] from [source] to [destination] on the server. Returns
  /// the message's new UID in [destination] if the server reports one (IMAP
  /// MOVE/COPY typically assigns a new UID in the destination mailbox), or
  /// `null` if it couldn't be determined.
  Future<int?> moveMessage(
    MailAccount account,
    String password,
    MailFolder source,
    MailMessage message,
    MailFolder destination,
  );
}
