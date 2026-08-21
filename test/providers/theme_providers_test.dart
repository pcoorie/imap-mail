import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:imap_mail/providers/theme_providers.dart';

/// Builds a container whose [sharedPreferencesProvider] is backed by a freshly
/// mocked, explicitly injected [SharedPreferences] instance.
Future<ProviderContainer> _containerWith(Map<String, Object> initialValues) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  test('sharedPreferencesProvider must be overridden', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(() => container.read(sharedPreferencesProvider), throwsUnimplementedError);
  });

  test('defaults to ThemeMode.system when nothing is persisted', () async {
    final container = await _containerWith({});
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('a persisted mode is the very first value read — no ThemeMode.system flash', () async {
    final container = await _containerWith({'theme_mode': 'dark'});
    addTearDown(container.dispose);

    // Deliberately no await/pump between build and this read: the first frame
    // must already see the persisted mode.
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  test('a persisted light mode is also read synchronously', () async {
    final container = await _containerWith({'theme_mode': 'light'});
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.light);
  });

  test('an unrecognized persisted value falls back to system', () async {
    final container = await _containerWith({'theme_mode': 'not-a-real-mode'});
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('setThemeMode updates state and persists the choice', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.light);

    expect(container.read(themeModeProvider), ThemeMode.light);
    expect(prefs.getString('theme_mode'), 'light');
  });

  test('a fresh notifier backed by an independent SharedPreferences instance '
      'picks up a mode persisted by a previous one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs1 = await SharedPreferences.getInstance();
    final container1 = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs1)],
    );
    addTearDown(container1.dispose);
    await container1.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark);

    // Drop the cached singleton so the second instance genuinely re-reads the
    // underlying store instead of sharing prefs1's in-memory cache. Without
    // this the assertion below would pass even if the write never landed.
    SharedPreferences.resetStatic();
    final prefs2 = await SharedPreferences.getInstance();
    expect(identical(prefs1, prefs2), isFalse,
        reason: 'the round-trip must go through a second, independent instance');

    final container2 = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs2)],
    );
    addTearDown(container2.dispose);

    expect(container2.read(themeModeProvider), ThemeMode.dark);
  });

  test('setThemeMode reverts state and rethrows when the write fails', () async {
    final prefs = _WriteFailingPreferences({'theme_mode': 'light'});
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(themeModeProvider), ThemeMode.light);

    await expectLater(
      container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark),
      throwsA(isA<Exception>()),
    );

    // State must not diverge from what actually made it to storage.
    expect(container.read(themeModeProvider), ThemeMode.light);
  });
}

/// A [SharedPreferences] whose writes always fail, to exercise the
/// revert-on-failure path. Only the members the notifier touches are
/// implemented; anything else throws via [noSuchMethod].
class _WriteFailingPreferences implements SharedPreferences {
  _WriteFailingPreferences(this._values);

  final Map<String, String> _values;

  @override
  String? getString(String key) => _values[key];

  @override
  Future<bool> setString(String key, String value) async {
    throw Exception('simulated storage failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
