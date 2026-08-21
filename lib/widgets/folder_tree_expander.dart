import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

class FolderTreeExpander extends StatefulWidget {
  const FolderTreeExpander({super.key, required this.folders, required this.onSelect});

  final List<MailFolder> folders;
  final ValueChanged<MailFolder> onSelect;

  @override
  State<FolderTreeExpander> createState() => _FolderTreeExpanderState();
}

class _FolderTreeExpanderState extends State<FolderTreeExpander> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.arrow_drop_up : Icons.arrow_drop_down),
          label: const Text('More folders'),
        ),
        if (_expanded)
          ...widget.folders.map((folder) => ListTile(
                dense: true,
                title: Text(folder.name),
                onTap: () => widget.onSelect(folder),
              )),
      ],
    );
  }
}
