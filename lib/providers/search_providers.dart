import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_message.dart';
import '../models/unified_message.dart';
import 'account_providers.dart';
import 'repository_providers.dart';
import 'sync_status_providers.dart';

/// Matches [query] (case-insensitive substring) against a message's
/// subject, sender name, sender address, or snippet — the fields already
/// cached locally and already shown in every list row. Per the design
/// spec's non-goal on full-body search: bodies aren't searched here, only
/// what's already cached without opening the message.
bool _matches(MailMessage message, String query) {
  final q = query.toLowerCase();
  return message.subject.toLowerCase().contains(q) ||
      (message.fromName?.toLowerCase().contains(q) ?? false) ||
      message.from.toLowerCase().contains(q) ||
      message.snippet.toLowerCase().contains(q);
}

/// Every account's every non-local-only folder, filtered to messages
/// matching [query] and merged into one newest-first list — "global"
/// search across every account and every folder, not just whichever screen
/// launched it. Deliberately reads only the local cache
/// (`getCachedFolders`/`getCachedMessages`, not `foldersProvider`'s or
/// `messagesProvider`'s live IMAP sync) — see the design spec's non-goal on
/// live server search. A blank/whitespace-only query short-circuits to `[]`
/// without touching the repository at all, so an empty search field never
/// triggers N accounts' worth of local DB reads for nothing.
final searchResultsProvider = FutureProvider.autoDispose.family<List<UnifiedMessage>, String>((ref, query) async {
  // Re-run whenever anything bumps this tick — every swipe action
  // (archive/delete/flag/toggleRead) and every messagesProvider sync
  // already does, via MessageSwipeController.performSwipeAction. Without
  // this, search results would be frozen at whatever the cache looked
  // like the first time a given query string was searched, for the life
  // of the app — see totalUnreadCountProvider for the same pattern.
  ref.watch(unreadCountRefreshTickProvider);
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final results = <UnifiedMessage>[];
  for (final account in accounts) {
    final folders = await repository.getCachedFolders(account.id!);
    for (final folder in folders.where((f) => !f.isLocalOnly)) {
      final messages = await repository.getCachedMessages(folder.id!);
      for (final message in messages) {
        if (_matches(message, trimmed)) {
          results.add(UnifiedMessage(message: message, folder: folder, account: account));
        }
      }
    }
  }
  results.sort((a, b) => b.message.date.compareTo(a.message.date));
  return results;
});
