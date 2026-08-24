import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

/// A bottom sheet listing [folders] as move-to-folder destinations; resolves
/// with the tapped folder, or null if dismissed without a choice. Mirrors
/// `showComposeAccountPicker`'s shape.
Future<MailFolder?> showFolderPicker(BuildContext context, List<MailFolder> folders) {
  return showModalBottomSheet<MailFolder>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Move to', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final folder in folders)
            ListTile(
              title: Text(folder.name),
              onTap: () => Navigator.of(context).pop(folder),
            ),
        ],
      ),
    ),
  );
}
