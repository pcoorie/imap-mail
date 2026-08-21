import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/mail_message.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({super.key, required this.message, required this.onTap, this.accountColor});

  final MailMessage message;
  final VoidCallback onTap;

  /// Set by callers showing rows from multiple accounts at once (the
  /// unified inbox) so each row is visually attributable to its account.
  /// Null in the single-account folder view, where every row is obviously
  /// the same account and a dot would just be noise.
  final Color? accountColor;

  @override
  Widget build(BuildContext context) {
    final failed = message.sendStatus == MailSendStatus.failed;
    return ListTile(
      tileColor: message.isFlagged ? Colors.orange.withValues(alpha: 0.08) : null,
      leading: failed
          ? const Icon(Icons.error_outline, color: Colors.red)
          : accountColor != null
              ? Container(
                  key: const Key('accountColorDot'),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: accountColor, shape: BoxShape.circle),
                )
              : null,
      title: Text(
        message.subject,
        style: TextStyle(fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold),
      ),
      subtitle: Text(
        failed
            ? '${message.from} — Failed to send'
            : '${message.from} — ${message.snippet}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.isFlagged) const Icon(Icons.flag, size: 16, color: Colors.orange),
          Text('${message.date.toLocal().month}/${message.date.toLocal().day}'),
        ],
      ),
      onTap: onTap,
    );
  }
}
