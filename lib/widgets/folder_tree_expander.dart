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
        // Capped and scrollable so a long folder list can't grow unbounded
        // inside the parent Column — left uncapped, expanding this list
        // pushes past the available height, overflows the RenderFlex, and
        // squeezes the message list below it down to zero height.
        if (_expanded)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView(
              shrinkWrap: true,
              children: widget.folders
                  .map((folder) => ListTile(
                        dense: true,
                        title: Text(folder.name),
                        onTap: () => widget.onSelect(folder),
                      ))
                  .toList(),
            ),
          ),
      ],
    );
  }
}
