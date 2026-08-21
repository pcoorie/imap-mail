import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'providers/theme_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Preloaded before the first frame so the persisted theme is available
  // synchronously — otherwise frame 1 renders ThemeMode.system and users who
  // overrode the OS theme see a flash of the wrong brightness.
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const ImapMailApp(),
    ),
  );
}
