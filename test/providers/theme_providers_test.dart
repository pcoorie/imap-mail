import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:imap_mail/providers/theme_providers.dart';

void main() {
  test('defaults to ThemeMode.system when nothing is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;

    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('loads a previously persisted mode on startup', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;

    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  test('an unrecognized persisted value falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'not-a-real-mode'});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;

    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('setThemeMode updates state and persists the choice', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;

    await notifier.setThemeMode(ThemeMode.light);
    expect(container.read(themeModeProvider), ThemeMode.light);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
  });

  test('a fresh notifier picks up a mode persisted by a previous one', () async {
    SharedPreferences.setMockInitialValues({});
    final container1 = ProviderContainer();
    addTearDown(container1.dispose);
    final notifier1 = container1.read(themeModeProvider.notifier);
    await notifier1.ready;
    await notifier1.setThemeMode(ThemeMode.dark);

    final container2 = ProviderContainer();
    addTearDown(container2.dispose);
    final notifier2 = container2.read(themeModeProvider.notifier);
    await notifier2.ready;

    expect(container2.read(themeModeProvider), ThemeMode.dark);
  });
}
