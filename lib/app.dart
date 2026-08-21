import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/account_providers.dart';
import 'providers/theme_providers.dart';
import 'screens/account_list_screen.dart';
import 'screens/account_form_screen.dart';
import 'screens/folder_view_screen.dart';

const _brandSeed = Color(0xFF0A5BD6);

class ImapMailApp extends ConsumerWidget {
  const ImapMailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Cobalt Mail',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _brandSeed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandSeed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: themeMode,
      home: Consumer(
        builder: (context, ref, _) {
          final accountsAsync = ref.watch(accountsProvider);
          return accountsAsync.when(
            data: (accounts) => switch (accounts.length) {
              0 => const AccountFormScreen(),
              1 => FolderViewScreen(accountId: accounts.single.id!),
              _ => const AccountListScreen(),
            },
            loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
            error: (error, _) => Scaffold(
              body: Center(child: Text('Failed to load accounts: $error')),
            ),
          );
        },
      ),
    );
  }
}
