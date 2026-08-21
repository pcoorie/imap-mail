import 'package:flutter/material.dart';
import '../models/mail_account.dart';

/// A bottom sheet listing [accounts] to compose from; resolves with the
/// tapped account, or null if dismissed without a choice. Used by
/// `UnifiedInboxScreen`'s compose FAB, which has no single "current
/// account" the way `FolderViewScreen`'s does.
Future<MailAccount?> showComposeAccountPicker(BuildContext context, List<MailAccount> accounts) {
  return showModalBottomSheet<MailAccount>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Compose from', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final account in accounts)
            ListTile(
              title: Text(account.displayName),
              subtitle: Text(account.email),
              onTap: () => Navigator.of(context).pop(account),
            ),
        ],
      ),
    ),
  );
}
