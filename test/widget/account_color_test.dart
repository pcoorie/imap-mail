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
}
