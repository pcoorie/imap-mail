import 'dart:io';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_message_mapper.dart';
import 'package:imap_mail/models/mail_attachment.dart';
import 'package:path/path.dart' as p;

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

  test('maps attachment parts of a MimeMessage to MailAttachment records', () async {
    final tempDir = await Directory.systemTemp.createTemp('mail_message_mapper_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File(p.join(tempDir.path, 'report.pdf'));
    await file.writeAsBytes(List<int>.filled(1234, 0));

    final builder = MessageBuilder.prepareMultipartMixedMessage()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Files attached'
      ..text = 'See attached.';
    await builder.addFile(file, MediaType.fromText('application/pdf'));
    final mime = builder.buildMimeMessage();

    final attachments = mapMimeMessageAttachments(mime, messageId: 42);

    expect(attachments, hasLength(1));
    final attachment = attachments.first;
    expect(attachment, isA<MailAttachment>());
    expect(attachment.messageId, 42);
    expect(attachment.filename, 'report.pdf');
    expect(attachment.mimeType, 'application/pdf');
    expect(attachment.size, 1234);
  });

  test('maps the primary From address\'s personalName into fromName', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Hello'
      ..text = 'Hi Bob.';
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.fromName, 'Alice');
  });

  test('leaves fromName null when the From address has no personalName', () {
    final builder = MessageBuilder()
      ..from = [MailAddress(null, 'noreply@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Hello'
      ..text = 'Hi Bob.';
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.fromName, isNull);
  });

  test('maps isFlagged from the underlying MimeMessage flag', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Important'
      ..text = 'Please flag this.';
    final mime = builder.buildMimeMessage();
    mime.isFlagged = true;

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.isFlagged, isTrue);
  });
}
