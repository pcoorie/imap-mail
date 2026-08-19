import 'package:flutter/material.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';

class MessageDetailScreen extends StatelessWidget {
  const MessageDetailScreen({super.key, required this.folder, required this.message});

  final MailFolder folder;
  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(message.subject)));
  }
}
