import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/widgets/message_date_format.dart';

void main() {
  // A fixed "now" so every test is independent of the actual wall-clock date.
  final now = DateTime(2026, 8, 22, 15, 30); // Saturday, 3:30 PM

  test('shows a 12-hour time for a message from earlier today', () {
    expect(formatMessageDate(DateTime(2026, 8, 22, 14, 45), now: now), '2:45 PM');
  });

  test('pads single-digit minutes', () {
    expect(formatMessageDate(DateTime(2026, 8, 22, 9, 5), now: now), '9:05 AM');
  });

  test('shows 12, not 0, for midnight and noon', () {
    expect(formatMessageDate(DateTime(2026, 8, 22, 0, 15), now: now), '12:15 AM');
    expect(formatMessageDate(DateTime(2026, 8, 22, 12, 0), now: now), '12:00 PM');
  });

  test('shows "Yesterday" for a message from the day before', () {
    expect(formatMessageDate(DateTime(2026, 8, 21, 9, 0), now: now), 'Yesterday');
  });

  test('shows the weekday name for a message from earlier this week (2-6 days ago)', () {
    expect(formatMessageDate(DateTime(2026, 8, 19, 9, 0), now: now), 'Wed');
    expect(formatMessageDate(DateTime(2026, 8, 17, 9, 0), now: now), 'Mon');
  });

  test('shows abbreviated month + day for an older message in the same year', () {
    expect(formatMessageDate(DateTime(2026, 8, 10, 9, 0), now: now), 'Aug 10');
  });

  test('shows month + day + year for a message from a previous year', () {
    expect(formatMessageDate(DateTime(2025, 12, 24, 9, 0), now: now), 'Dec 24, 2025');
  });

  test('treats a message dated in the future (clock skew) as "today", not a weekday', () {
    expect(formatMessageDate(DateTime(2026, 8, 22, 23, 0), now: DateTime(2026, 8, 22, 1, 0)), '11:00 PM');
  });

  test('exactly 7 days ago falls back to the month/day form, not the weekday form', () {
    // Guards the boundary: "this week" means the 6 days before today, not 7+.
    expect(formatMessageDate(DateTime(2026, 8, 15, 9, 0), now: now), 'Aug 15');
  });
}
