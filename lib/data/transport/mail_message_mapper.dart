import 'package:enough_mail/enough_mail.dart';
import '../../models/mail_attachment.dart';
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
    // Only the primary (first) From address's display name — a message
    // with multiple From addresses is rare, and the avatar only has room
    // for one sender's initials anyway.
    fromName: (mime.from?.isNotEmpty ?? false) ? mime.from!.first.personalName : null,
    to: mime.to?.map((a) => a.email).join(', ') ?? '',
    date: mime.decodeDate() ?? DateTime.now().toUtc(),
    snippet: snippet,
    bodyText: bodyText,
    bodyHtml: bodyHtml,
    isRead: mime.isSeen,
    isFlagged: mime.isFlagged,
    isDownloaded: bodyText != null || bodyHtml != null,
  );
}

List<MailAttachment> mapMimeMessageAttachments(MimeMessage mime, {required int messageId}) {
  final infos = mime.findContentInfo(disposition: ContentDisposition.attachment);
  return infos.map((info) {
    return MailAttachment(
      messageId: messageId,
      filename: info.fileName ?? 'attachment',
      mimeType: info.mediaType?.text ?? 'application/octet-stream',
      // ContentInfo.size reads Content-Disposition's `size` parameter (set by
      // enough_mail's MessageBuilder.addFile from the source file's byte
      // length). Verified against the installed enough_mail 2.1.7 source
      // (lib/src/mime_message.dart, ContentInfo.size). Servers/senders that
      // omit that parameter leave it null, so fall back to 0 as best-effort.
      size: info.size ?? 0,
    );
  }).toList();
}

String _stripHtml(String html) => html.replaceAll(RegExp('<[^>]*>'), '');
