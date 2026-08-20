# Dark Theme (System + Manual Override) — Design Spec

Date: 2026-08-20
Status: Approved

## 1. Purpose

Add a dark theme that follows the OS light/dark setting by default, with a manual override in Settings for users who want to force one regardless of OS.

## 2. Goals / Non-goals

**Goals**
- App defaults to mirroring the OS theme (`ThemeMode.system`).
- Settings screen offers a Light / Dark / System picker; the choice persists across app restarts.
- Both light and dark schemes are seeded from the existing Cobalt Mail brand color (`#0A5BD6`, same as the app icon and splash screen) so the two modes feel like one brand, not a bolted-on dark palette.

**Non-goals**
- No per-screen or per-widget custom theming beyond what Material 3's seeded `ColorScheme` produces automatically.
- No animated theme transition — an instant switch is fine.

## 3. Approach

### Storage

Add `shared_preferences` as a new dependency (not currently used anywhere in the app — the app currently persists everything either in the sqflite DB or `flutter_secure_storage`). This is the first "simple app preference" the app needs, and `shared_preferences` is the standard fit for that rather than adding a table to the mail database for a single string value.

A `ThemeModeNotifier extends Notifier<ThemeMode>` (Riverpod) loads the persisted value on `build()` (key: `"theme_mode"`, values `"light"` / `"dark"` / `"system"`, default `"system"` if unset or unrecognized) and exposes:

```dart
Future<void> setThemeMode(ThemeMode mode)
```

which writes through to `SharedPreferences` and updates state. Exposed as `themeModeProvider`.

### Theming

In `app.dart`, `MaterialApp` gains:

```dart
theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF0A5BD6)), useMaterial3: true),
darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF0A5BD6), brightness: Brightness.dark), useMaterial3: true),
themeMode: ref.watch(themeModeProvider),
```

This is the only place theme mode is read — no manual `MediaQuery.platformBrightnessOf` checks anywhere else in the app; `MaterialApp`'s own `themeMode` handling does the work of following system brightness when set to `ThemeMode.system`.

### Settings UI

`SettingsScreen` gains a new top section (above the existing accounts list) with a `SegmentedButton<ThemeMode>` (Light / Dark / System), selection bound to `themeModeProvider`, `onSelectionChanged` calling `setThemeMode`.

## 4. Testing

- Provider test: `ThemeModeNotifier` persists a chosen mode and reloads it on a fresh provider container, using a fake/in-memory `SharedPreferences` (the package ships a test-mode implementation for this).
- Widget test: selecting each segment in `SettingsScreen` updates the ambient `MaterialApp.themeMode` (verified via `Theme.of(context)` / pumping and checking `MaterialApp` widget properties).

## 5. Verification

- Manual: toggle OS dark mode with the in-app setting on "System" → app follows. Set in-app to "Dark" → app stays dark even if OS switches to light, and vice versa.
- Run `flutter test` for the new provider/widget tests.
