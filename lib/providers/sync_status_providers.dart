import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set whenever a folders/messages sync falls back to cached data after a
/// failure (auth/connection errors), and cleared on the next successful
/// sync. Keyed per account (not global) so that when multiple accounts sync
/// concurrently — the unified inbox does this — one account's failure can't
/// overwrite another's, or clear a real failure the moment any other
/// account happens to succeed.
final syncErrorProvider = StateProvider.family<String?, int>((ref, accountId) => null);
