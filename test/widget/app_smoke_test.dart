import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/app.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/database_providers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
}
