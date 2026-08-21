import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set whenever a folders/messages sync falls back to cached data after a
/// failure (auth/connection errors), and cleared on the next successful
/// sync. Keyed per account (not global) so that when multiple accounts sync
/// concurrently — the unified inbox does this — one account's failure can't
/// overwrite another's, or clear a real failure the moment any other
/// account happens to succeed.
final syncErrorProvider = StateProvider.family<String?, int>((ref, accountId) => null);

/// Bumped whenever something persists a change to a folder's unread count
/// (a successful header sync, mark-read/unread, archive, delete, move, or
/// undo). `totalUnreadCountProvider` watches this purely to know when to
/// re-read — it does NOT read folder data through `foldersProvider`,
/// because that provider caches its result until explicitly invalidated and
/// has no way to know the local `unread_count` column changed underneath it
/// (a real bug: the OS/home-tile badge could go stale for an entire
/// session even though the true count changed, since nothing else in the
/// app ever re-triggers `foldersProvider` after its first sync). Bumping
/// this tick is what makes `totalUnreadCountProvider` re-read fresh,
/// without requiring another IMAP folder-list sync to do it.
final unreadCountRefreshTickProvider = StateProvider<int>((ref) => 0);
