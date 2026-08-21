import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/app.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/theme_providers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // Use the no-isolate ffi factory: the new test below pumps a real widget
    // that awaits a real DAO query (through accountsProvider) inside
    // testWidgets' fake-async environment. The default databaseFactoryFfi
    // dispatches SQLite calls to a background worker isolate; cross-isolate
    // message delivery can deadlock under that environment once a query
    // actually returns row data (unaffected when the table is empty, as in
    // the three pre-existing tests below — see the same established fix in
    // message_detail_screen_test.dart). Running SQLite calls directly on the
    // calling isolate avoids the deadlock.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Override databaseOverride() => databaseProvider.overrideWith((ref) async {
        return databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
        );
      });

  /// Mirrors what `main()` does: preload SharedPreferences before the first
  /// frame and inject it into the root scope.
  Future<Override> preferencesOverride(Map<String, Object> initialValues) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final prefs = await SharedPreferences.getInstance();
    return sharedPreferencesProvider.overrideWithValue(prefs);
  }

  testWidgets('app builds and shows a MaterialApp', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseOverride(), await preferencesOverride({})],
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
      overrides: [databaseOverride(), await preferencesOverride({})],
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

  testWidgets('a persisted dark override is applied on the very first frame (no light flash)', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseOverride(), await preferencesOverride({'theme_mode': 'dark'})],
      child: const ImapMailApp(),
    ));

    // No pump beyond the initial build: frame 1 must already be dark, otherwise
    // a user who forced Dark on a light OS sees a full-brightness flash.
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);

    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('with exactly one account, opens straight into its folders — no account list shown', (tester) async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
    );
    await db.insert('accounts', {
      'display_name': 'Work',
      'email': 'me@example.com',
      'imap_host': 'imap.example.com',
      'imap_port': 993,
      'imap_security': 'ssl',
      'smtp_host': 'smtp.example.com',
      'smtp_port': 465,
      'smtp_security': 'ssl',
      'username': 'me@example.com',
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        await preferencesOverride({}),
        // This test only checks routing (1 account -> straight to
        // FolderViewScreen), not FolderViewScreen's own data loading —
        // that's already covered by folder_view_screen_test.dart.
        // Overriding foldersProvider keeps this test from touching the
        // real credential-store/IMAP-transport chain, which has no
        // stored password for this directly-inserted account row.
        foldersProvider.overrideWith((ref, accountId) async => const []),
      ],
      child: const ImapMailApp(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Accounts'), findsNothing); // AccountListScreen's AppBar title
    expect(find.text('Mail'), findsOneWidget); // FolderViewScreen's AppBar title
  });
}
