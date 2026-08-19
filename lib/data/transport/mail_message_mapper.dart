import 'package:enough_mail/enough_mail.dart';
import '../../models/mail_message.dart';

MailMessage mapMimeMessageToRecord(MimeMessage mime, {required int folderId}) {
  final bodyText = mime.decodeTextPlainPart();
  final bodyHtml = mime.decodeTextHtmlPart();
  final snippetSource = bodyText ?? _stripHtml(bodyHtml ?? '');
  final snippet = snippetSource.trim().length > 140
      ? '${snippetSource.trim().substring(0, 140)}...'
      : snippetSource.trim();

  return MailMessage(
    folderId: folderId,
    uid: mime.uid ?? 0,
    subject: mime.decodeSubject() ?? '(no subject)',
    from: mime.from?.map((a) => a.email).join(', ') ?? '',
    to: mime.to?.map((a) => a.email).join(', ') ?? '',
    date: mime.decodeDate() ?? DateTime.now().toUtc(),
    snippet: snippet,
    bodyText: bodyText,
    bodyHtml: bodyHtml,
    isRead: mime.isSeen,
    isDownloaded: bodyText != null || bodyHtml != null,
  );
}

String _stripHtml(String html) => html.replaceAll(RegExp('<[^>]*>'), '');
