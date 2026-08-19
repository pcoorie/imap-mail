import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import 'account_form_screen.dart';
import 'folder_view_screen.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts'), actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountFormScreen()),
          ),
        ),
      ]),
      body: accountsAsync.when(
        data: (accounts) => ListView.builder(
          itemCount: accounts.length,
          itemBuilder: (context, index) {
            final account = accounts[index];
            return ListTile(
              title: Text(account.displayName),
              subtitle: Text(account.email),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => FolderViewScreen(accountId: account.id!)),
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
      ),
    );
  }
}
