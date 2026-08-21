import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'theme_mode';

/// The app's [SharedPreferences] instance, preloaded before the first frame.
///
/// It has no default implementation on purpose: `main()` awaits
/// `SharedPreferences.getInstance()` and overrides this provider in the root
/// `ProviderScope`, which is what lets [ThemeModeNotifier.build] resolve the
/// persisted theme synchronously instead of flashing the wrong brightness.
/// Tests override it with a mock-backed instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider must be overridden in main()'),
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // Synchronous by design: the preference is already in memory, so frame 1
    // renders the user's real choice.
    return _fromName(ref.watch(sharedPreferencesProvider).getString(_themeModeKey));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final previous = state;
    state = mode;
    try {
      await ref.read(sharedPreferencesProvider).setString(_themeModeKey, mode.name);
    } catch (_) {
      // Don't let in-memory state diverge from what's actually stored.
      state = previous;
      rethrow;
    }
  }

  ThemeMode _fromName(String? name) {
    switch (name) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
