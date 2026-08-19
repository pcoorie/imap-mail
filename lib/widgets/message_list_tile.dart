import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/mail_message.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({super.key, required this.message, required this.onTap});

  final MailMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final failed = message.sendStatus == MailSendStatus.failed;
    return ListTile(
      leading: failed
          ? const Icon(Icons.error_outline, color: Colors.red)
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
      trailing: Text('${message.date.toLocal().month}/${message.date.toLocal().day}'),
      onTap: onTap,
    );
  }
}
