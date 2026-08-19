import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/account_providers.dart';
import 'screens/account_list_screen.dart';
import 'screens/account_form_screen.dart';

class ImapMailApp extends ConsumerWidget {
  const ImapMailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'IMAP Mail',
      home: Consumer(
        builder: (context, ref, _) {
          final accountsAsync = ref.watch(accountsProvider);
          return accountsAsync.when(
            data: (accounts) => accounts.isEmpty
                ? const AccountFormScreen()
                : const AccountListScreen(),
            loading: () => const Scaffold(body: Center(child: SizedBox())),
            error: (error, _) => Scaffold(
              body: Center(child: Text('Failed to load accounts: $error')),
            ),
          );
        },
      ),
    );
  }
}
