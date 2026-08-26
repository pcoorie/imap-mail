/// Strips HTML tags from [html], leaving a readable plain-text
/// approximation.
///
/// Two things a bare tag-removal regex gets wrong for real mail, both
/// fixed here:
///   - Block-level boundaries (`<br>`, `</p>`, `</div>`, list items, table
///     cells/rows, headings, blockquotes) become line breaks *before* tags
///     are stripped, so sentences that were on separate lines/cells in the
///     original don't get glued together (e.g. "...ends on
///     17/09/2026.We have attached..." instead of two sentences).
///   - A handful of the most common HTML entities are decoded — numeric and
///     hex character references (`&#160;`, `&#x2019;`, ...) and the usual
///     named ones (`&nbsp;`, `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`)
///     — rather than left showing up literally as `&#160;` in the output.
///     `&amp;` is decoded last so a source `&amp;lt;` (a literal "&lt;",
///     not a real tag) doesn't get double-unescaped into "<".
///
/// Still not a full HTML renderer — no styling, no images, no links as
/// links — good enough for a truncated list snippet or a quoted forward
/// body. Deliberately doesn't collapse the runs of blank lines this can
/// leave behind (a pretty-printed HTML source's own indentation, mostly) —
/// see compose_screen.dart's _collapseBlankLines for that, applied only
/// where a human is about to read the result start-to-finish.
String stripHtml(String html) {
  final withLineBreaks = html.replaceAll(
    RegExp(
      r'<\s*br\s*/?\s*>|<\s*/\s*(p|div|li|tr|td|th|h[1-6]|blockquote)\s*>',
      caseSensitive: false,
    ),
    '\n',
  );
  final withoutTags = withLineBreaks.replaceAll(RegExp('<[^>]*>'), '');
  return _decodeEntities(withoutTags);
}

/// Non-breaking space (U+00A0) — what `&nbsp;`/`&#160;` decode to. Mapped
/// to a plain space for our purposes: nothing here needs to preserve
/// "don't wrap here" semantics, and leaving it as U+00A0 just risks it
/// looking like stray/invisible junk instead of a normal space.
const String _nbsp = ' ';

String _decodeEntities(String text) {
  return text
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
      .replaceAllMapped(
        RegExp(r'&#[xX]([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      )
      .replaceAll('&nbsp;', ' ')
      .replaceAll(_nbsp, ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}
