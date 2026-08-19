import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

void main() {
  const account = MailAccount(
    displayName: 'Alice',
    email: 'alice@example.com',
    imapHost: 'imap.example.com',
    imapPort: 993,
    imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com',
    smtpPort: 465,
    smtpSecurity: MailSecurity.ssl,
    username: 'alice@example.com',
  );

  test('buildMimeMessage sets from/to/cc/subject/body', () {
    final composed = ComposedMessage(
      to: const ['bob@example.com'],
      cc: const ['carol@example.com'],
      bcc: const [],
      subject: 'Hello',
      bodyText: 'Hi Bob',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    final mime = buildMimeMessage(account, composed);

    expect(mime.from?.first.email, 'alice@example.com');
    expect(mime.to?.map((a) => a.email), contains('bob@example.com'));
    expect(mime.cc?.map((a) => a.email), contains('carol@example.com'));
    expect(mime.decodeSubject(), 'Hello');
    expect(mime.decodeTextPlainPart(), contains('Hi Bob'));
  });

  test('buildMimeMessage throws when there are no recipients', () {
    final composed = ComposedMessage(
      to: const [],
      cc: const [],
      bcc: const [],
      subject: 'Hello',
      bodyText: 'Hi',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    expect(() => buildMimeMessage(account, composed), throwsArgumentError);
  });
}
