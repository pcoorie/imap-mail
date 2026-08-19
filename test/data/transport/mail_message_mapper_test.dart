import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_message_mapper.dart';

void main() {
  test('maps a plain-text MimeMessage to a MailMessage record', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Hello'
      ..text = 'Hi Bob, this is the body.';
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.folderId, 7);
    expect(message.subject, 'Hello');
    expect(message.from, contains('alice@example.com'));
    expect(message.bodyText, contains('Hi Bob'));
    expect(message.bodyHtml, isNull);
  });

  test('maps an HTML MimeMessage, preferring HTML for snippet source', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Report'
      ..addMultipartAlternative(
        plainText: 'Plain body',
        htmlText: '<p>HTML body</p>',
      );
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.bodyHtml, contains('HTML body'));
    expect(message.bodyText, contains('Plain body'));
    expect(message.snippet, isNotEmpty);
  });
}
