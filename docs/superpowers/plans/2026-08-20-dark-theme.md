# Dark Theme (System + Manual Override) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dark theme that follows the OS setting by default, with a Light/Dark/System override persisted in Settings.

**Architecture:** A Riverpod `Notifier<ThemeMode>` (`themeModeProvider`) loads/persists the chosen mode via `shared_preferences` and is the single source of truth `MaterialApp.themeMode` watches in `app.dart`. Both `theme`/`darkTheme` are Material 3 `ColorScheme.fromSeed` instances built from the existing brand color, so no other file needs brightness-aware logic.

**Tech Stack:** Flutter, `flutter_riverpod` (`Notifier`/`NotifierProvider`), new `shared_preferences` dependency, `flutter_test` + `mocktail` (existing test stack).

## Global Constraints

- Brand seed color: `Color(0xFF0A5BD6)` (Cobalt Mail blue — same value used in the app icon/splash spec). Used for both light and dark `ColorScheme.fromSeed`.
- Persisted preference key: `"theme_mode"`, string values `"light"` / `"dark"` / `"system"`. Any other/missing value defaults to `ThemeMode.system`.
- No new dependency beyond `shared_preferences` — add it via `flutter pub add shared_preferences` so the resolved version constraint is whatever's current, not hand-picked.
- Follow existing patterns: Riverpod providers under `lib/providers/`, tests mirror existing files' structure (`ProviderContainer` + overrides for provider tests, `tester.pumpWidget(ProviderScope(overrides: [...]))` for widget tests).

---

### Task 1: Add `shared_preferences` dependency

**Files:**
- Modify: `pubspec.yaml`

**Interfaces:**
- Produces: `shared_preferences` package available to import as `package:shared_preferences/shared_preferences.dart` throughout the app and tests.

- [ ] **Step 1: Add the dependency**

Run: `cd ~/imap_mail && flutter pub add shared_preferences`

This edits `pubspec.yaml`'s `dependencies:` block and `pubspec.lock` automatically — do not hand-edit the version.

- [ ] **Step 2: Verify it resolves**

Run: `cd ~/imap_mail && flutter pub get`
Expected: completes with no errors, `shared_preferences` listed in `pubspec.lock`.

- [ ] **Step 3: Commit**

```bash
cd ~/imap_mail
git add pubspec.yaml pubspec.lock
git commit -m "chore: add shared_preferences dependency"
```

---

### Task 2: `ThemeModeNotifier` / `themeModeProvider`

**Files:**
- Create: `lib/providers/theme_providers.dart`
- Test: `test/providers/theme_providers_test.dart`

**Interfaces:**
- Consumes: `SharedPreferences.getInstance()` (from `shared_preferences`, added in Task 1).
- Produces:
  - `class ThemeModeNotifier extends Notifier<ThemeMode>` with:
    - `Future<void> get ready` — resolves once the persisted value (if any) has been loaded and applied to state. Tests must `await` this before asserting state; production code doesn't need to.
    - `Future<void> setThemeMode(ThemeMode mode)` — updates state immediately and persists it.
  - `final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);`

- [ ] **Step 1: Write the failing tests**

Create `test/providers/theme_providers_test.dart`:

```dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/imap_mail && flutter test test/providers/theme_providers_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:imap_mail/providers/theme_providers.dart'` (file doesn't exist yet).

- [ ] **Step 3: Implement `ThemeModeNotifier`**

Create `lib/providers/theme_providers.dart`:

```dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/providers/theme_providers_test.dart`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/imap_mail
git add lib/providers/theme_providers.dart test/providers/theme_providers_test.dart
git commit -m "feat(theme): add ThemeModeNotifier persisted via shared_preferences"
```

---

### Task 3: Wire theme into `MaterialApp`

**Files:**
- Modify: `lib/app.dart`
- Modify: `test/widget/app_smoke_test.dart`

**Interfaces:**
- Consumes: `themeModeProvider` (Task 2) — `ThemeMode` value.
- Produces: `ImapMailApp`'s `MaterialApp` now exposes `theme`, `darkTheme`, and `themeMode` properties reflecting the provider, inspectable via `tester.widget<MaterialApp>(find.byType(MaterialApp))` in later tests (e.g. Task 4, and any future spec that needs to assert on theme).

- [ ] **Step 1: Write the failing test**

`app_smoke_test.dart` will break once `app.dart` touches `SharedPreferences` (no mock is set up there yet) — fix that as part of writing the new assertions in the same file. Replace the full contents of `test/widget/app_smoke_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/app.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/database_providers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app builds and shows a MaterialApp', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async {
          return databaseFactory.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
          );
        }),
      ],
      child: const ImapMailApp(),
    ));
    // The loading branch shows a CircularProgressIndicator, whose repeating
    // animation never naturally settles, so pumpAndSettle() would hang here.
    // Pump a bounded sequence instead to let the in-memory database future
    // resolve and the accountsProvider settle into its data/error state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ImapMailApp), findsOneWidget);
  });

  testWidgets('MaterialApp defaults to ThemeMode.system with light/dark schemes seeded from the brand color', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async {
          return databaseFactory.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
          );
        }),
      ],
      child: const ImapMailApp(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.system);
    expect(materialApp.theme?.colorScheme.brightness, Brightness.light);
    expect(materialApp.darkTheme?.colorScheme.brightness, Brightness.dark);
    expect(materialApp.theme?.colorScheme.primary, isNotNull);
  });
}
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `cd ~/imap_mail && flutter test test/widget/app_smoke_test.dart`
Expected: the first test still passes; the new `ThemeMode.system` test FAILS because `MaterialApp.theme`/`darkTheme` are currently `null` (unset in `app.dart`).

- [ ] **Step 3: Wire `theme`/`darkTheme`/`themeMode` into `app.dart`**

Replace `lib/app.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/account_providers.dart';
import 'providers/theme_providers.dart';
import 'screens/account_list_screen.dart';
import 'screens/account_form_screen.dart';

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
            data: (accounts) => accounts.isEmpty
                ? const AccountFormScreen()
                : const AccountListScreen(),
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/widget/app_smoke_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Run the full test suite to check nothing else regressed**

Run: `cd ~/imap_mail && flutter test`
Expected: all tests pass. (Any other widget test that pumps `ImapMailApp` or otherwise ends up constructing `themeModeProvider` without a mocked `SharedPreferences` will fail with a `MissingPluginException` — if that happens, add `SharedPreferences.setMockInitialValues({})` to that file's `setUp`, matching the pattern above.)

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/app.dart test/widget/app_smoke_test.dart
git commit -m "feat(theme): wire ThemeMode into MaterialApp with brand-seeded schemes"
```

---

### Task 4: Theme picker in Settings

**Files:**
- Modify: `lib/screens/settings_screen.dart`
- Modify: `test/widget/settings_screen_test.dart`

**Interfaces:**
- Consumes: `themeModeProvider` / `ThemeModeNotifier.setThemeMode()` (Task 2).
- Produces: `SettingsScreen` renders a `SegmentedButton<ThemeMode>` above the accounts list; no new public interface for other files to consume.

- [ ] **Step 1: Write the failing test**

Add to `test/widget/settings_screen_test.dart` (keep the existing test and imports, add these):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/theme_providers.dart';
import 'package:imap_mail/screens/settings_screen.dart';

void main() {
  const account = MailAccount(
    id: 1,
    displayName: 'Work',
    email: 'me@example.com',
    imapHost: 'imap.example.com',
    imapPort: 993,
    imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com',
    smtpPort: 465,
    smtpSecurity: MailSecurity.ssl,
    username: 'me@example.com',
  );

  testWidgets('tapping Remove shows a confirmation dialog', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Remove this account?'), findsOneWidget);
  });

  testWidgets('theme segmented control reflects the current mode and calls setThemeMode on change', (tester) async {
    final fakeNotifier = _FakeThemeModeNotifier(ThemeMode.dark);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => fakeNotifier),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    final segmented = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(segmented.selected, {ThemeMode.dark});

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(fakeNotifier.state, ThemeMode.light);
  });
}

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeThemeModeNotifier extends ThemeModeNotifier {
  _FakeThemeModeNotifier(this._initial);
  final ThemeMode _initial;

  @override
  ThemeMode build() => _initial;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
  }
}
```

This replaces the entire file (it consolidates the previously separate `_FakeAccountsNotifier` class and adds `_FakeThemeModeNotifier`).

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `cd ~/imap_mail && flutter test test/widget/settings_screen_test.dart`
Expected: the existing "Remove" test still passes (once `themeModeProvider` override is added, which is needed since `SettingsScreen` will read it after Step 3); the new segmented-control test FAILS — `find.byType(SegmentedButton<ThemeMode>)` finds nothing yet.

Note: run this after Step 1 but expect the *first* test to also fail at this point, since `SettingsScreen` doesn't read `themeModeProvider` yet, so overriding it is harmless but the widget tree has no `SegmentedButton` — that's fine, both failures are expected pre-implementation.

- [ ] **Step 3: Add the segmented control to `SettingsScreen`**

Replace `lib/screens/settings_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import '../providers/theme_providers.dart';
import 'account_form_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, int accountId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: const Text('This deletes its cached mail and stored password from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(accountsProvider.notifier).remove(accountId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final themeMode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Text('Theme'),
                const Spacer(),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (selection) =>
                      ref.read(themeModeProvider.notifier).setThemeMode(selection.first),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: accountsAsync.when(
              data: (accounts) => ListView.builder(
                itemCount: accounts.length,
                itemBuilder: (context, index) {
                  final account = accounts[index];
                  return ListTile(
                    title: Text(account.displayName),
                    subtitle: Text(account.email),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => AccountFormScreen(existing: account)),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmRemove(context, ref, account.id!),
                        ),
                      ],
                    ),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/widget/settings_screen_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Run the full test suite**

Run: `cd ~/imap_mail && flutter test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/screens/settings_screen.dart test/widget/settings_screen_test.dart
git commit -m "feat(theme): add Light/Dark/System picker to Settings"
```

---

## Self-Review Notes

- **Spec coverage:** storage/persistence (Task 2), seeded light+dark `ColorScheme`s and single `themeMode` read point in `MaterialApp` (Task 3), Settings `SegmentedButton` (Task 4) — all three spec sections have a task. Verification steps from the spec (§5) are covered by the full-suite runs in Tasks 3 and 4; the manual OS-toggle check is a human step to do after merging, not something a task can automate.
- **Placeholder scan:** none — every step has runnable code and exact commands.
- **Type consistency:** `ThemeModeNotifier`/`themeModeProvider` names and the `ready`/`setThemeMode()` signatures introduced in Task 2 are used identically in Tasks 3 and 4; `_FakeThemeModeNotifier` in Task 4 matches the real class's overridable members.
