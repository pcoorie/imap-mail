import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set whenever a folders/messages sync falls back to cached data after a
/// failure (auth/connection errors), and cleared on the next successful
/// sync. Without this, `foldersProvider`/`messagesProvider` catching a sync
/// error and silently returning cached data makes every failure after the
/// first successful sync invisible: no banner, no indicator. Screens can
/// watch this to show a lightweight, dismissible, non-blocking banner above
/// otherwise-fine cached content.
final lastSyncErrorProvider = StateProvider<String?>((ref) => null);
