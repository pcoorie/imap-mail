import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import '../providers/unified_inbox_providers.dart';
import 'account_form_screen.dart';
import 'folder_view_screen.dart';
import 'settings_screen.dart';
import 'unified_inbox_screen.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final unreadAsync = ref.watch(totalUnreadCountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts'), actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountFormScreen()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ]),
      body: accountsAsync.when(
        data: (accounts) => ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('All Inboxes'),
              subtitle: Text('${accounts.length} accounts'),
              trailing: unreadAsync.maybeWhen(
                data: (count) => count > 0 ? Text('$count') : null,
                orElse: () => null,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UnifiedInboxScreen()),
              ),
            ),
            for (final account in accounts)
              ListTile(
                title: Text(account.displayName),
                subtitle: Text(account.email),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => FolderViewScreen(accountId: account.id!)),
                ),
              ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
      ),
    );
  }
}
