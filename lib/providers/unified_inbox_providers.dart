import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/unified_message.dart';
import 'account_providers.dart';
import 'folder_providers.dart';
import 'message_providers.dart';
import 'sync_status_providers.dart';

Future<MailFolder?> _inboxFolderFor(Ref ref, int accountId) async {
  final folders = await ref.watch(foldersProvider(accountId).future);
  return folders.firstWhereOrNull((f) => f.type == MailFolderType.inbox);
}

/// One account's contribution to the merged inbox. Never lets a single
/// account's failure propagate out of `unifiedInboxProvider` — an account
/// with a sync error and no cache (the only case `foldersProvider`/
/// `messagesProvider` themselves still rethrow instead of returning cached
/// data) simply contributes zero rows here. `messagesProvider` already
/// records `syncErrorProvider(accountId)` for us when it falls back to a
/// *non-empty* cache; when it rethrows (cache empty too) that state is
/// never set, so this is the one path where we still have to record the
/// failure ourselves for `UnifiedInboxScreen`'s banner (Task 8) to see it.
Future<List<UnifiedMessage>> _fetchForAccount(Ref ref, MailAccount account) async {
  try {
    final inbox = await _inboxFolderFor(ref, account.id!);
    if (inbox == null) return const [];
    final messages = await ref.watch(messagesProvider(inbox).future);
    return [for (final message in messages) UnifiedMessage(message: message, folder: inbox, account: account)];
  } catch (e) {
    ref.read(syncErrorProvider(account.id!).notifier).state = e.toString();
    return const [];
  }
}

/// Every account's Inbox, merged into one chronological (newest-first)
/// list. Reuses `messagesProvider`/`foldersProvider` as-is per account
/// (same sync-then-cache-fallback behavior as a single-account view) rather
/// than duplicating any sync logic — this provider only merges and sorts.
/// Fetches all accounts concurrently so N accounts' IMAP round trips don't
/// serialize into N times the latency.
final unifiedInboxProvider = FutureProvider<List<UnifiedMessage>>((ref) async {
  final accounts = await ref.watch(accountsProvider.future);
  final perAccount = await Future.wait(accounts.map((account) => _fetchForAccount(ref, account)));
  final merged = perAccount.expand((list) => list).toList()
    ..sort((a, b) => b.message.date.compareTo(a.message.date));
  return merged;
});

/// Sum of unread counts across every account's Inbox folder. Cheap: reuses
/// `foldersProvider`'s already-fetched `MailFolder.unreadCount` rather than
/// syncing messages just to count them. A failed account contributes 0
/// rather than failing the whole sum, matching `unifiedInboxProvider`'s
/// per-account resilience — this drives both the home screen's "All
/// Inboxes" badge (Task 9) and the OS app icon badge (Task 11).
final totalUnreadCountProvider = FutureProvider<int>((ref) async {
  final accounts = await ref.watch(accountsProvider.future);
  final perAccountUnread = await Future.wait(accounts.map((account) async {
    try {
      final inbox = await _inboxFolderFor(ref, account.id!);
      return inbox?.unreadCount ?? 0;
    } catch (_) {
      return 0;
    }
  }));
  return perAccountUnread.fold<int>(0, (sum, n) => sum + n);
});
