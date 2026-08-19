// NOTE: deviates from the brief, which imports enough_mail unqualified here.
// Both enough_mail and our own domain model export a class named
// `MailAccount`; unqualified imports of both collide at compile time
// ("'MailAccount' is imported from both ..."). `hide MailAccount` resolves
// the collision while keeping enough_mail's other types (MimeMessage,
// MessageBuilder, MailAddress, MediaType) unqualified, matching the brief's
// code shape.
import 'dart:io';
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

// This is the single source of truth for turning a ComposedMessage into a
// MimeMessage, including the zero-recipients validation guard. It is used
// both directly by tests and by EnoughMailSender.send(), so the validated
// path is guaranteed to be the one that actually runs a real send — not a
// second, divergent reimplementation.
//
// Async (rather than the originally-synchronous shape) because attaching
// files via enough_mail's `MessageBuilder.addFile` is itself async; folding
// attachment handling in here (instead of leaving EnoughMailSender to bolt
// it on afterwards) keeps there being exactly one MIME-construction code
// path.
Future<MimeMessage> buildMimeMessage(MailAccount account, ComposedMessage message) async {
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

  for (final path in message.attachmentFilePaths) {
    // NOTE: deviates from the brief's `builder.addFile(File(path))`. The
    // installed enough_mail 2.1.7 `MessageBuilder.addFile` requires a second
    // positional `MediaType mediaType` argument (not optional as the brief
    // implies). Use `MediaType.guessFromFileName` to infer it from the file
    // extension, preserving the intent of attaching the file with an
    // appropriate content type.
    final file = File(path);
    await builder.addFile(file, MediaType.guessFromFileName(path));
  }

  return builder.buildMimeMessage();
}
