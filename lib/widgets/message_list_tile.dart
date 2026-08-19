import 'package:flutter/material.dart';
import '../models/mail_message.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({super.key, required this.message, required this.onTap});

  final MailMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        message.subject,
        style: TextStyle(fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold),
      ),
      subtitle: Text('${message.from} — ${message.snippet}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text('${message.date.toLocal().month}/${message.date.toLocal().day}'),
      onTap: onTap,
    );
  }
}
