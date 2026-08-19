import 'dart:io';
import 'package:enough_mail/enough_mail.dart' as enough;
import '../../models/enums.dart';
import '../../models/mail_account.dart';
import 'mail_sender.dart';

// NOTE: both our own domain model and enough_mail export a class named
// `MailAccount`. The enough_mail import is aliased to `enough` throughout
// this file specifically to keep that unambiguous — do not remove the alias.
class EnoughMailSender implements MailSender {
  @override
  Future<void> send(
    MailAccount account,
    String password,
    ComposedMessage message,
  ) async {
    final enoughAccount = enough.MailAccount.fromManualSettings(
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

    final builder = enough.MessageBuilder()
      ..from = [enough.MailAddress(account.displayName, account.email)]
      ..to = message.to.map((e) => enough.MailAddress('', e)).toList()
      ..cc = message.cc.map((e) => enough.MailAddress('', e)).toList()
      ..bcc = message.bcc.map((e) => enough.MailAddress('', e)).toList()
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
      // NOTE: deviates from the brief's `builder.addFile(File(path))`.
      // The installed enough_mail 2.1.7 `MessageBuilder.addFile` requires a
      // second positional `MediaType mediaType` argument (not optional as
      // the brief implies). Use `MediaType.guessFromFileName` to infer it
      // from the file extension, preserving the intent of attaching the
      // file with an appropriate content type.
      final file = File(path);
      await builder.addFile(
        file,
        enough.MediaType.guessFromFileName(path),
      );
    }

    // NOTE: deviates from the brief's `final mime = builder.buildMimeMessage();
    // if (mime == null) throw StateError(...)`. The installed enough_mail
    // 2.1.7 `MessageBuilder.buildMimeMessage()` returns a non-nullable
    // `MimeMessage`, so the null check is unreachable dead code and is
    // omitted here.
    final mime = builder.buildMimeMessage();

    final client = enough.MailClient(enoughAccount);
    try {
      await client.connect();
      await client.sendMessage(mime);
    } finally {
      await client.disconnect();
    }
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
}
