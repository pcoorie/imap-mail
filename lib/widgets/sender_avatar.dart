import 'package:flutter/material.dart';
import 'account_color.dart';

/// Outlook-style 2-letter initials for a sender.
///
/// Prefers [name] (the sender's display name, e.g. "Chris Quinones" → "CQ"):
/// first letter of the first word + first letter of the last word when there
/// are 2+ words, or the first two letters of a single word. Falls back to
/// deriving a pseudo-name from [email]'s local part (before the `@`) when
/// [name] is null/blank — separators like `.`/`_`/`-`/`+` are treated as
/// word breaks so `chris.quinones@...` also yields "CQ", the same way
/// `noreply@...` yields "NO".
String senderInitials({String? name, required String email}) {
  final trimmedName = name?.trim();
  final label = (trimmedName != null && trimmedName.isNotEmpty)
      ? trimmedName
      : email.split('@').first.replaceAll(RegExp(r'[._\-+]+'), ' ');

  final words = label.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';

  if (words.length == 1) {
    final word = words.single;
    return word.length >= 2 ? word.substring(0, 2).toUpperCase() : word.toUpperCase();
  }
  return (words.first[0] + words.last[0]).toUpperCase();
}

/// A round, colored initials avatar for a message's sender — Outlook's
/// inbox-row avatar style. Color is deterministic per [email] (via
/// [senderColorFor]) so the same sender always gets the same color;
/// initials come from [senderInitials].
class SenderAvatar extends StatelessWidget {
  const SenderAvatar({super.key, this.name, required this.email, this.diameter = 40});

  final String? name;
  final String email;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: diameter / 2,
      backgroundColor: senderColorFor(email),
      child: Text(
        senderInitials(name: name, email: email),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: diameter * 0.38,
        ),
      ),
    );
  }
}
