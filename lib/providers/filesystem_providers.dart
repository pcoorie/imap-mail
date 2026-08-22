import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Wraps `getApplicationDocumentsDirectory()` behind a provider — same
/// reason `databaseProvider` wraps `AppDatabase.open()` rather than letting
/// callers hit `path_provider` directly: its platform channel never settles
/// under a widget test's async zone (no real iOS/Android host), so tests
/// override this with a temp directory instead of touching path_provider at
/// all.
final documentsDirectoryProvider = FutureProvider<Directory>((ref) => getApplicationDocumentsDirectory());
