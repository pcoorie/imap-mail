/// Formats a message's date the way mainstream mail apps do, relative to
/// [now] (defaults to the real current time — overridable for tests):
/// a 12-hour time for anything from today, "Yesterday" for the day before,
/// an abbreviated weekday name for the rest of this week, then "Mon D" for
/// an older date this year, or "Mon D, YYYY" once the year differs.
String formatMessageDate(DateTime date, {DateTime? now}) {
  final local = date.toLocal();
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final messageDay = DateTime(local.year, local.month, local.day);
  final daysDiff = today.difference(messageDay).inDays;

  // daysDiff <= 0 covers both "today" and a message dated in the future
  // (clock skew between this device and the sender) — either way, a time is
  // more informative than misreading it as a weekday days away.
  if (daysDiff <= 0) {
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '$hour12:$minute $period';
  }
  if (daysDiff == 1) return 'Yesterday';

  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (daysDiff < 7) return weekdays[local.weekday - 1];

  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final monthDay = '${months[local.month - 1]} ${local.day}';
  return local.year == reference.year ? monthDay : '$monthDay, ${local.year}';
}
