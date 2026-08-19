import 'package:flutter/material.dart';

class FolderViewScreen extends StatelessWidget {
  const FolderViewScreen({super.key, required this.accountId});

  final int accountId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Inbox')));
  }
}
