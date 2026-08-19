import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

class FolderTabBar extends StatelessWidget {
  const FolderTabBar({super.key, required this.folders, required this.selected, required this.onSelect});

  final List<MailFolder> folders;
  final MailFolder? selected;
  final ValueChanged<MailFolder> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: folders.map((folder) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(folder.name),
              selected: selected?.id == folder.id,
              onSelected: (_) => onSelect(folder),
            ),
          );
        }).toList(),
      ),
    );
  }
}
