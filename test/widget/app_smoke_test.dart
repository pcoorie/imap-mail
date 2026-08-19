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
    await tester.pumpAndSettle();

    expect(find.byType(ImapMailApp), findsOneWidget);
  });
}
