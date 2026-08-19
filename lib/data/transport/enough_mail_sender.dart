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

    // Delegate MIME construction (including the zero-recipients guard and
    // attachment handling) to the shared, unit-tested buildMimeMessage, so
    // this is not a second, divergent reimplementation of the same logic —
    // see mail_sender.dart.
    final mime = await buildMimeMessage(account, message);

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
