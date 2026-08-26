/// Strips HTML tags from [html], leaving a plain-text-ish approximation.
///
/// Deliberately simple (no entity decoding, no whitespace normalization) —
/// good enough for a truncated list snippet or a quoted forward body, not a
/// full HTML-to-text renderer. Shared by mail_message_mapper.dart (list
/// snippets) and compose_screen.dart (quoting an HTML-only message being
/// forwarded) so both fall back the same way when a message has no
/// text/plain part.
String stripHtml(String html) => html.replaceAll(RegExp('<[^>]*>'), '');
