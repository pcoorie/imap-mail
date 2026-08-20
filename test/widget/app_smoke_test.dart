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
