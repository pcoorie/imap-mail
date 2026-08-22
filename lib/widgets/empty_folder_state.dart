import 'package:flutter/material.dart';

/// A friendly placeholder for a message list with zero rows — shown instead
/// of a bare blank screen, the way every mainstream mail app fills an empty
/// inbox/folder rather than leaving it looking broken.
class EmptyFolderState extends StatelessWidget {
  const EmptyFolderState({super.key, required this.message});

  /// e.g. "No messages in Trash" or "No messages".
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
