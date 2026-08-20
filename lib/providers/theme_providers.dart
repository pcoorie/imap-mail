import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModeKey = 'theme_mode';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  late Future<void> _readyFuture;

  /// Resolves once a persisted preference (if any) has been loaded and
  /// applied to state. `build()` can't await this itself — Riverpod
  /// `Notifier.build()` must return synchronously — so state starts at
  /// `ThemeMode.system` and is corrected once the load completes. Tests
  /// await this getter before asserting state; production UI just watches
  /// the provider normally and will rebuild when state updates.
  Future<void> get ready => _readyFuture;

  @override
  ThemeMode build() {
    _readyFuture = _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _fromName(prefs.getString(_themeModeKey));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
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
