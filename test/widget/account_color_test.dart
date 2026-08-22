import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/widgets/account_color.dart';

void main() {
  test('is deterministic for the same account id', () {
    expect(accountColorFor(7), accountColorFor(7));
  });

  test('differs for different account ids, in general', () {
    // Not a strict guarantee (palette wraps), but with a small set of ids
    // relative to the palette size this must hold for the mapping to be
    // useful at all.
    final colors = {for (var id = 1; id <= 6; id++) id: accountColorFor(id)};
    expect(colors.values.toSet().length, greaterThan(1));
  });

  group('senderColorFor', () {
    test('is deterministic for the same key', () {
      expect(senderColorFor('chris@example.com'), senderColorFor('chris@example.com'));
    });

    test('differs for different keys, in general', () {
      final colors = {
        for (final email in ['a@example.com', 'b@example.com', 'c@example.com', 'd@example.com', 'e@example.com'])
          email: senderColorFor(email),
      };
      expect(colors.values.toSet().length, greaterThan(1));
    });

    test('pins a known key to a known color — catches an accidental hash algorithm change '
        '(e.g. swapping back to String.hashCode, which carries no cross-version guarantee)', () {
      expect(senderColorFor('chris@example.com'), Colors.green);
    });
  });
}
