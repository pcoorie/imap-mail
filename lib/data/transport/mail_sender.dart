// NOTE: deviates from the brief, which imports enough_mail unqualified here.
// Both enough_mail and our own domain model export a class named
// `MailAccount`; unqualified imports of both collide at compile time
// ("'MailAccount' is imported from both ..."). `hide MailAccount` resolves
// the collision while keeping enough_mail's other types (MimeMessage,
// MessageBuilder, MailAddress) unqualified, matching the brief's code shape.
import 'package:enough_mail/enough_mail.dart' hide MailAccount;
import '../../models/mail_account.dart';

class ComposedMessage {
  ComposedMessage({
    required this.to,
    required this.cc,
    required this.bcc,
    required this.subject,
    required this.bodyText,
    required this.bodyHtml,
    required this.attachmentFilePaths,
  });

  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String bodyText;
  final String? bodyHtml;
  final List<String> attachmentFilePaths;
}

abstract class MailSender {
  Future<void> send(MailAccount account, String password, ComposedMessage message);
}

MimeMessage buildMimeMessage(MailAccount account, ComposedMessage message) {
  if (message.to.isEmpty && message.cc.isEmpty && message.bcc.isEmpty) {
    throw ArgumentError('ComposedMessage must have at least one recipient');
  }

  final builder = MessageBuilder()
    ..from = [MailAddress(account.displayName, account.email)]
    ..to = message.to.map((e) => MailAddress('', e)).toList()
    ..cc = message.cc.map((e) => MailAddress('', e)).toList()
    ..bcc = message.bcc.map((e) => MailAddress('', e)).toList()
    ..subject = message.subject;

  if (message.bodyHtml != null) {
    builder.addMultipartAlternative(
      plainText: message.bodyText,
      htmlText: message.bodyHtml!,
    );
  } else {
    builder.text = message.bodyText;
  }

  return builder.buildMimeMessage();
}
