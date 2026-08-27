import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/utils/html_text.dart';

void main() {
  group('stripHtml', () {
    test('removes simple tags, leaving the inline text untouched', () {
      expect(stripHtml('Hello <b>Bob</b>'), 'Hello Bob');
    });

    test('inserts a line break at </p>, </div>, and <br> boundaries '
        '(regression: block-level content used to run together into one line, '
        'e.g. "...ends on 17/09/2026.We have attached..." with no separation '
        'between what were two distinct sentences)', () {
      final html = '<div>First paragraph.</div><div>Second paragraph.</div>'
          '<p>Third.<br>Fourth on its own line.</p>';
      final result = stripHtml(html);
      expect(result, contains('First paragraph.\nSecond paragraph.'));
      expect(result, contains('Third.\nFourth on its own line.'));
    });

    test('is case-insensitive and tolerates attributes/whitespace on the closing tags', () {
      // Adjacent boundaries (a </DIV> immediately followed by a <br/>) each
      // contribute their own line break — stripHtml doesn't collapse the
      // resulting blank line itself, that's compose_screen.dart's
      // _collapseBlankLines' job once a human is about to read the result.
      final html = '<DIV>One</DIV > <BR >Two';
      final result = stripHtml(html);
      expect(result, contains('One'));
      expect(result, contains('Two'));
      expect(result.indexOf('One'), lessThan(result.indexOf('Two')));
    });

    test('decodes numeric and hex character references '
        '(regression: &#160; used to show up literally instead of becoming a space)', () {
      expect(stripHtml('End of lease.&#160;New agreement starts.'), 'End of lease. New agreement starts.');
      expect(stripHtml('Price: &#x24;100'), r'Price: $100');
    });

    test('decodes the common named entities', () {
      expect(stripHtml('Tom &amp; Jerry'), 'Tom & Jerry');
      expect(stripHtml('5 &lt; 10 &gt; 2'), '5 < 10 > 2');
      expect(stripHtml('She said &quot;hi&quot;'), 'She said "hi"');
      expect(stripHtml('It&apos;s fine'), "It's fine");
      expect(stripHtml('It&#39;s fine'), "It's fine");
    });

    test('decodes &amp; last, so a literal "&lt;" in the source is not double-unescaped into "<"', () {
      expect(stripHtml('Use &amp;lt; to show a literal &lt;'), 'Use &lt; to show a literal <');
    });

    test('a real-world fragment: entity decoding and paragraph breaks together', () {
      final html = '<p>...re-signed their lease for a further 12 months.&#160;'
          'Their new agreement ends on 17/09/2026.</p>'
          '<p>We have attached a copy of the completed lease for your records.</p>';
      final result = stripHtml(html);
      expect(result, contains('12 months. Their new agreement ends on 17/09/2026.'));
      expect(result, contains('17/09/2026.\nWe have attached'));
    });
  });
}
