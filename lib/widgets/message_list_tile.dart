import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/mail_message.dart';
import 'message_date_format.dart';
import 'sender_avatar.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({
    super.key,
    required this.message,
    required this.onTap,
    this.accountColor,
    this.selected,
    this.onLongPress,
  });

  final MailMessage message;
  final VoidCallback onTap;

  /// Set by callers showing rows from multiple accounts at once (the
  /// unified inbox) so each row is visually attributable to its account —
  /// rendered as a small badge on the corner of the sender avatar rather
  /// than replacing it, so multi-account clarity survives alongside the new
  /// avatar. Null in the single-account folder view, where every row is
  /// obviously the same account and a badge would just be noise.
  final Color? accountColor;

  /// `null` (the default) means selection mode is not active — the row
  /// renders exactly as it always has, with no checkbox. Once selection
  /// mode is active, callers pass `true`/`false` for every row (whether
  /// this particular message is selected), and a round checkbox appears
  /// before the existing leading content: a hollow ring when `false`, a
  /// filled circle with a checkmark when `true`.
  final bool? selected;

  /// Wired to [ListTile.onLongPress] — the entry point into selection mode.
  final VoidCallback? onLongPress;

  Widget _selectionCheckbox(BuildContext context, bool isSelected) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('selectionCheckbox'),
      width: 24,
      height: 24,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? scheme.primary : Colors.transparent,
        border: isSelected ? null : Border.all(color: scheme.outline, width: 2),
      ),
      child: isSelected ? Icon(Icons.check, size: 16, color: scheme.onPrimary) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final failed = message.sendStatus == MailSendStatus.failed;
    // `message.from` can hold more than one comma-joined address (a message
    // with multiple From addresses) — the avatar only has room for one
    // sender, so use the primary (first), matching fromName's own mapping
    // (see mail_message_mapper.dart).
    final primaryEmail = message.from.split(',').first.trim();
    final avatar = SenderAvatar(name: message.fromName, email: primaryEmail);
    // Prefer the sender's real name (e.g. "Chris Quinones") — falls back to
    // the email address only when the server never sent a display name for
    // it (common for bare automated senders like noreply@example.com).
    final senderDisplay = message.fromName?.trim().isNotEmpty == true
        ? message.fromName!
        : primaryEmail;
    final leadingContent = failed
        ? const Icon(Icons.error_outline, color: Colors.red)
        : accountColor != null
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  key: const Key('accountColorDot'),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: accountColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          )
        : avatar;
    return ListTile(
      tileColor: selected == true
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
          : message.isFlagged
          ? Colors.orange.withValues(alpha: 0.08)
          : null,
      leading: selected == null
          ? leadingContent
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _selectionCheckbox(context, selected!),
                leadingContent,
              ],
            ),
      title: Text(
        message.subject,
        style: TextStyle(
          fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Text(
        failed
            ? '$senderDisplay — Failed to send'
            : '$senderDisplay — ${message.snippet}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.isFlagged)
            const Icon(Icons.flag, size: 16, color: Colors.orange),
          Text(formatMessageDate(message.date)),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
