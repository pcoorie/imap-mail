# Unified Inbox + App Icon Unread Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the home screen's bare account list with a merged "All Inboxes" view across all accounts (with the per-account list still available beneath it), and add an OS-level unread-count badge on the app icon (iOS/Android).

**Architecture:** A new `unifiedInboxProvider` merges each account's already-existing `messagesProvider(inboxFolder)` results (no new sync path — reuses existing sync/cache/error-fallback logic per account) into one sorted `List<UnifiedMessage>`. A new `UnifiedInboxScreen` renders that list, sharing swipe-action logic with the existing `FolderViewScreen` via an extracted `MessageSwipeController`. `totalUnreadCountProvider` derives the badge count from the same per-account inbox folders and drives both the home screen's "All Inboxes" tile and the OS icon badge via `ref.listen`.

**Tech Stack:** Flutter, Riverpod (`flutter_riverpod`), `flutter_slidable`, `app_badge_plus` (new), `permission_handler` (new), `mocktail` + `flutter_test` for tests.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-21-unified-inbox-design.md` — follow it exactly; this plan implements it task-by-task.
- No unified view for any folder type other than Inbox.
- No background sync/push is added. The badge only updates while the app is foregrounded (via `ref.listen`) — this is intentional, not a bug to fix.
- Badge wiring targets iOS + Android only. It must no-op silently (never throw, never block UI) on every other platform, including web (`kIsWeb`).
- With exactly 1 account configured, the app must route straight to that account's `FolderViewScreen` — no unified tile shown anywhere.
- Every new/changed provider and widget gets a test in the same task that introduces it — no task is "done" until its own tests pass.
- Run `flutter test` at the end of every task; only commit on green.

---

### Task 1: `UnifiedMessage` model

**Files:**
- Create: `lib/models/unified_message.dart`
- Test: `test/models/unified_message_test.dart`

**Interfaces:**
- Produces: `UnifiedMessage { final MailMessage message; final MailFolder folder; final MailAccount account; }`, used by every later task that touches the merged inbox.

- [ ] **Step 1: Write the failing test**

```dart
// test/models/unified_message_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/unified_message.dart';

void main() {
  test('bundles a message with the folder and account it came from', () {
    const account = MailAccount(
      id: 1,
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    );
    final folder = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
    final message = MailMessage(
      id: 100,
      folderId: 10,
      uid: 1,
      subject: 'Hello',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'Hi',
    );

    final unified = UnifiedMessage(message: message, folder: folder, account: account);

    expect(unified.message, message);
    expect(unified.folder, folder);
    expect(unified.account, account);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/unified_message_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'imap_mail/models/unified_message.dart'` (file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```dart
// lib/models/unified_message.dart
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';

/// Bundles a message with the folder and account it belongs to. Produced by
/// `unifiedInboxProvider`, which merges every account's Inbox into one
/// chronological list — without this, a merged row would need to re-look-up
/// its own account/folder by id (folderId only tells you a local database
/// row, not which account owns it) before anything (opening the message,
/// swiping, resolving a color) could act on it correctly.
class UnifiedMessage {
  const UnifiedMessage({required this.message, required this.folder, required this.account});

  final MailMessage message;
  final MailFolder folder;
  final MailAccount account;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/unified_message_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/models/unified_message.dart test/models/unified_message_test.dart
git commit -m "feat(unified-inbox): add UnifiedMessage model

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 2: Rename `lastSyncErrorProvider` to a per-account `syncErrorProvider` family

**Files:**
- Modify: `lib/providers/sync_status_providers.dart`
- Modify: `lib/providers/message_providers.dart:14,19`
- Modify: `lib/providers/folder_providers.dart:13,18`
- Modify: `lib/screens/folder_view_screen.dart:40,74`
- Modify: `test/providers/sync_status_providers_test.dart`

**Why:** `lastSyncErrorProvider` is a single global `StateProvider<String?>`. That's harmless today because only one account's `messagesProvider`/`foldersProvider` is ever active on screen at once. The unified inbox (Task 4 onward) runs every account's sync concurrently — as a shared global, one account's error/success would stomp on another's, and the unified banner (Task 8) couldn't tell which account actually failed. This task must land before Task 4.

**Interfaces:**
- Produces: `syncErrorProvider = StateProvider.family<String?, int>(...)`, keyed by `accountId`. All later tasks that need per-account sync error state use `syncErrorProvider(accountId)`.

- [ ] **Step 1: Update the failing tests first**

Edit `test/providers/sync_status_providers_test.dart`: add the import and change every `container.read(lastSyncErrorProvider)` to `container.read(syncErrorProvider(accountId))`.

```dart
// test/providers/sync_status_providers_test.dart
// Add this import alongside the existing ones:
import 'package:imap_mail/providers/sync_status_providers.dart';
```

Replace every occurrence of `lastSyncErrorProvider` in the file's two `test(...)` bodies with `syncErrorProvider(accountId)` — e.g.:

```dart
    final first = await container.read(foldersProvider(accountId).future);
    expect(first.map((f) => f.name), contains('INBOX'));
    expect(container.read(syncErrorProvider(accountId)), isNull);

    container.invalidate(foldersProvider(accountId));
    final second = await container.read(foldersProvider(accountId).future);

    expect(second, isNotEmpty);
    expect(container.read(syncErrorProvider(accountId)), isNotNull);
    expect(container.read(syncErrorProvider(accountId)), contains('connection refused'));
```

...and the same substitution in the second `test(...)` block (the `messagesProvider` one), which already has `accountId` and `folderId` in scope — use `accountId` there too (not `folderId`; the state is keyed by account, not folder).

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/providers/sync_status_providers_test.dart`
Expected: FAIL — `Undefined name 'syncErrorProvider'`.

- [ ] **Step 3: Rename the provider**

```dart
// lib/providers/sync_status_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set whenever a folders/messages sync falls back to cached data after a
/// failure (auth/connection errors), and cleared on the next successful
/// sync. Keyed per account (not global) so that when multiple accounts sync
/// concurrently — the unified inbox does this — one account's failure can't
/// overwrite another's, or clear a real failure the moment any other
/// account happens to succeed.
final syncErrorProvider = StateProvider.family<String?, int>((ref, accountId) => null);
```

- [ ] **Step 4: Update the two providers that write to it**

```dart
// lib/providers/message_providers.dart — replace the whole file body with:
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import 'account_providers.dart';
import 'repository_providers.dart';
import 'sync_status_providers.dart';

final messagesProvider = FutureProvider.family<List<MailMessage>, MailFolder>((ref, folder) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == folder.accountId);
  try {
    final messages = await repository.syncHeaders(account, folder);
    ref.read(syncErrorProvider(folder.accountId).notifier).state = null;
    return messages;
  } catch (e) {
    final cached = await repository.getCachedMessages(folder.id!);
    if (cached.isEmpty) rethrow;
    ref.read(syncErrorProvider(folder.accountId).notifier).state = e.toString();
    return cached;
  }
});
```

```dart
// lib/providers/folder_providers.dart — replace the whole file body with:
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_folder.dart';
import 'account_providers.dart';
import 'repository_providers.dart';
import 'sync_status_providers.dart';

final foldersProvider = FutureProvider.family<List<MailFolder>, int>((ref, accountId) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == accountId);
  try {
    final folders = await repository.syncFolders(account);
    ref.read(syncErrorProvider(accountId).notifier).state = null;
    return folders;
  } catch (e) {
    final cached = await repository.getCachedFolders(accountId);
    if (cached.isEmpty) rethrow;
    ref.read(syncErrorProvider(accountId).notifier).state = e.toString();
    return cached;
  }
});
```

- [ ] **Step 5: Update `FolderViewScreen`'s two read sites**

In `lib/screens/folder_view_screen.dart`, change:
```dart
    final syncError = ref.watch(lastSyncErrorProvider);
```
to:
```dart
    final syncError = ref.watch(syncErrorProvider(widget.accountId));
```
and change:
```dart
                      onPressed: () => ref.read(lastSyncErrorProvider.notifier).state = null,
```
to:
```dart
                      onPressed: () => ref.read(syncErrorProvider(widget.accountId).notifier).state = null,
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/providers/sync_status_providers_test.dart test/widget/folder_view_screen_test.dart`
Expected: PASS (the widget test file needs no source edits — it never referenced `lastSyncErrorProvider` directly — but re-run it here since it's the other consumer of `FolderViewScreen`).

- [ ] **Step 7: Commit**

```bash
git add lib/providers/sync_status_providers.dart lib/providers/message_providers.dart lib/providers/folder_providers.dart lib/screens/folder_view_screen.dart test/providers/sync_status_providers_test.dart
git commit -m "refactor: key sync-error state per account instead of globally

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 3: Account color helper

**Files:**
- Create: `lib/widgets/account_color.dart`
- Test: `test/widget/account_color_test.dart`

**Interfaces:**
- Produces: `Color accountColorFor(int accountId)` — deterministic, used by `MessageListTile` (Task 5) and `UnifiedInboxScreen` (Task 8).

- [ ] **Step 1: Write the failing test**

```dart
// test/widget/account_color_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/widgets/account_color.dart';

void main() {
  test('is deterministic for the same account id', () {
    expect(accountColorFor(7), accountColorFor(7));
  });

  test('differs for different account ids, in general', () {
    // Not a strict guarantee (palette wraps), but with a small set of ids
    // relative to the palette size this must hold for the mapping to be
    // useful at all.
    final colors = {for (var id = 1; id <= 6; id++) id: accountColorFor(id)};
    expect(colors.values.toSet().length, greaterThan(1));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/account_color_test.dart`
Expected: FAIL — file `lib/widgets/account_color.dart` doesn't exist.

- [ ] **Step 3: Write the implementation**

```dart
// lib/widgets/account_color.dart
import 'package:flutter/material.dart';

/// A small, fixed palette cycled by account id — same approach already used
/// for swipe-action colors elsewhere in this codebase (see
/// FolderViewScreen's `_colorFor`), rather than pulling in a new dependency
/// for something this simple. Deterministic per id so the same account
/// always gets the same dot color across app restarts and across the two
/// screens (unified inbox, message tile) that use it.
const _palette = [
  Colors.blue,
  Colors.teal,
  Colors.deepOrange,
  Colors.purple,
  Colors.green,
  Colors.pink,
  Colors.indigo,
  Colors.brown,
];

Color accountColorFor(int accountId) => _palette[accountId.abs() % _palette.length];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/account_color_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/account_color.dart test/widget/account_color_test.dart
git commit -m "feat(unified-inbox): add deterministic per-account color helper

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 4: `totalUnreadCountProvider` and `unifiedInboxProvider`

**Files:**
- Create: `lib/providers/unified_inbox_providers.dart`
- Test: `test/providers/unified_inbox_providers_test.dart`

**Interfaces:**
- Consumes: `accountsProvider` (`account_providers.dart`), `foldersProvider.family<List<MailFolder>, int>` (`folder_providers.dart`), `messagesProvider.family<List<MailMessage>, MailFolder>` (`message_providers.dart`), `syncErrorProvider.family<String?, int>` (Task 2), `UnifiedMessage` (Task 1).
- Produces: `totalUnreadCountProvider = FutureProvider<int>`, `unifiedInboxProvider = FutureProvider<List<UnifiedMessage>>`. Used by `UnifiedInboxScreen` (Task 8), the home screen tile (Task 9), and the app icon badge (Task 11).

- [ ] **Step 1: Write the failing tests**

```dart
// test/providers/unified_inbox_providers_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  const workAccount = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personalAccount = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 3);
  final workSent = MailFolder(id: 11, accountId: 1, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 5);

  MailMessage msg({required int id, required int folderId, required DateTime date}) => MailMessage(
        id: id, folderId: folderId, uid: id, subject: 'Subject $id', from: 'a@example.com',
        to: 'me@example.com', date: date, snippet: 'snippet',
      );

  test('unifiedInboxProvider merges only Inbox folders across accounts, sorted newest-first', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) {
          return [msg(id: 1, folderId: 10, date: DateTime.utc(2026, 8, 20))];
        }
        if (folder.id == personalInbox.id) {
          return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
        }
        fail('messagesProvider should never be called for a non-inbox folder');
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2, 1]); // personal (8/21) before work (8/20)
    expect(result[0].account, personalAccount);
    expect(result[1].account, workAccount);
  });

  test('unifiedInboxProvider treats a failed, cache-empty account as contributing zero rows, and records its error', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) throw Exception('connection refused');
        return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2]);
    expect(container.read(syncErrorProvider(1)), contains('connection refused'));
  });

  test('totalUnreadCountProvider sums unread counts across accounts\' Inbox folders only', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 8); // 3 + 5
  });

  test('totalUnreadCountProvider treats a failed account as contributing zero, not throwing', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async {
        if (accountId == 1) throw Exception('offline');
        return [personalInbox];
      }),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 5);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/providers/unified_inbox_providers_test.dart`
Expected: FAIL — `lib/providers/unified_inbox_providers.dart` doesn't exist.

- [ ] **Step 3: Write the implementation**

```dart
// lib/providers/unified_inbox_providers.dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/providers/unified_inbox_providers_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/providers/unified_inbox_providers.dart test/providers/unified_inbox_providers_test.dart
git commit -m "feat(unified-inbox): add unifiedInboxProvider and totalUnreadCountProvider

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 5: Extract `MessageSwipeController` out of `FolderViewScreen`

**Files:**
- Create: `lib/widgets/message_swipe_controller.dart`
- Modify: `lib/screens/folder_view_screen.dart`
- Test: `test/widget/folder_view_screen_test.dart` (existing — must keep passing unmodified; it's the regression suite for this extraction)

**Why:** `FolderViewScreen`'s `_MessageListState` currently builds swipe action panes and performs archive/delete/flag/mark-read against one ambient `folder`/account. `UnifiedInboxScreen` (Task 8) needs the exact same behavior per-row against a *different* account per row. Extracting it now — as a faithful move, not a rewrite — means Task 8 reuses it instead of duplicating ~250 lines, and this task's own job is to prove the extraction changed nothing observable (the existing widget test suite is the proof).

**Interfaces:**
- Produces:
  ```dart
  class MessageSwipeController {
    MessageSwipeController(this.ref, {required this.isMounted, required this.messengerOf});
    void dispose();
    ActionPane? buildActionPane({
      required SwipeAction primary,
      required SwipeAction secondary,
      required MailAccount account,
      required MailFolder folder,
      required MailMessage message,
      required void Function(int messageId) onRemoved,
    });
  }
  ```
  Used by `FolderViewScreen` (this task) and `UnifiedInboxScreen` (Task 8).

- [ ] **Step 1: Create the controller by moving the existing logic**

This step is a *move*, not new behavior — copy the bodies of `_buildActionPane`, `_iconFor`, `_colorFor`, `_performSwipeAction`, `_showUndoSnackBar`, and `_showAutoDismissingSnackBar` out of `lib/screens/folder_view_screen.dart`'s `_MessageListState` (current lines 174–416) into the new file below, with these mechanical changes: `mounted` → `isMounted()`, `context`-based `ScaffoldMessenger.maybeOf(context)` → `messengerOf()`, and every method gains an explicit `MailAccount account` parameter instead of resolving `accounts.firstWhere((a) => a.id == folder.accountId)` internally.

```dart
// lib/widgets/message_swipe_controller.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../models/swipe_action.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';

IconData swipeActionIcon(SwipeAction action) => switch (action) {
      SwipeAction.archive => Icons.archive_outlined,
      SwipeAction.delete => Icons.delete_outline,
      SwipeAction.flag => Icons.flag_outlined,
      SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
      SwipeAction.none => Icons.block,
    };

Color swipeActionColor(SwipeAction action) => switch (action) {
      SwipeAction.archive => Colors.blueGrey,
      SwipeAction.delete => Colors.red,
      SwipeAction.flag => Colors.orange,
      SwipeAction.toggleRead => Colors.teal,
      SwipeAction.none => Colors.grey,
    };

/// Owns the archive/delete/flag/mark-read swipe-action behavior for one
/// message list (Slidable pane construction, the actual repository calls,
/// undo, and error snackbars). Extracted out of `FolderViewScreen` so
/// `UnifiedInboxScreen` (which shows rows from many accounts at once, not
/// one ambient account/folder) can reuse it unchanged — every method takes
/// the row's own `MailAccount`/`MailFolder`/`MailMessage` explicitly rather
/// than assuming a single shared one.
///
/// [isMounted] and [messengerOf] are supplied by the owning State so this
/// controller can safely no-op after that State is disposed, exactly as
/// the original inline implementation did via its own `mounted` checks.
class MessageSwipeController {
  MessageSwipeController(this.ref, {required this.isMounted, required this.messengerOf});

  final WidgetRef ref;
  final bool Function() isMounted;
  final ScaffoldMessengerState? Function() messengerOf;

  Timer? _snackBarDismissTimer;

  void dispose() {
    _snackBarDismissTimer?.cancel();
  }

  /// Shows [snackBar] via [messenger] and guarantees it disappears after
  /// [snackBar]'s own `duration`, even if its built-in auto-dismiss timer
  /// doesn't fire (observed happening in this screen but not root-caused).
  /// Also clears any snackbar already showing/queued first, so a new
  /// action's feedback is never stuck waiting behind a stale one.
  void _showAutoDismissingSnackBar(ScaffoldMessengerState messenger, SnackBar snackBar) {
    _snackBarDismissTimer?.cancel();
    messenger.clearSnackBars();
    messenger.showSnackBar(snackBar);
    _snackBarDismissTimer = Timer(snackBar.duration, () {
      if (messenger.mounted) {
        messenger.hideCurrentSnackBar();
      }
    });
  }

  /// Builds one side's ActionPane from its configured primary/secondary
  /// actions. Returns null (no pane) if both slots are SwipeAction.none. A
  /// full swipe dismisses using the primary action; if primary is none but
  /// secondary isn't, secondary becomes the dismiss action too.
  ActionPane? buildActionPane({
    required SwipeAction primary,
    required SwipeAction secondary,
    required MailAccount account,
    required MailFolder folder,
    required MailMessage message,
    required void Function(int messageId) onRemoved,
  }) {
    final configured = [primary, secondary].where((a) => a != SwipeAction.none).toList();
    if (configured.isEmpty) return null;
    final dismissAction = primary != SwipeAction.none ? primary : secondary;

    return ActionPane(
      motion: const DrawerMotion(),
      dismissible: DismissiblePane(
        // The action runs here, not in onDismissed: confirmDismiss is
        // awaited *before* flutter_slidable commits to the resize/dismiss
        // animation, so returning false vetoes the animation entirely.
        // Running the action in onDismissed instead would commit to the
        // resize animation first, leaving a zombie row whenever the
        // message doesn't actually leave this folder.
        confirmDismiss: () => performSwipeAction(account: account, folder: folder, action: dismissAction, message: message),
        closeOnCancel: true,
        onDismissed: () {
          if (isMounted() && message.id != null) {
            onRemoved(message.id!);
          }
        },
      ),
      children: [
        for (final action in configured)
          SlidableAction(
            onPressed: (_) => performSwipeAction(account: account, folder: folder, action: action, message: message),
            icon: swipeActionIcon(action),
            label: action.label,
            backgroundColor: swipeActionColor(action),
          ),
      ],
    );
  }

  /// Runs [action] against [message] in [folder], belonging to [account].
  /// Returns true if the message actually left [folder] (archive, or a
  /// delete that moved-to-Trash or permanently removed it) — also used by
  /// `confirmDismiss` to decide whether the dismiss/resize animation should
  /// proceed. Returns false for non-removing actions (flag, toggleRead) or
  /// if the repository call threw.
  Future<bool> performSwipeAction({
    required MailAccount account,
    required MailFolder folder,
    required SwipeAction action,
    required MailMessage message,
  }) async {
    if (action == SwipeAction.none) return false;
    final messenger = isMounted() ? messengerOf() : null;
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      if (!isMounted()) return false;
      switch (action) {
        case SwipeAction.archive:
          final moved = await repository.archiveMessage(account, folder, message);
          if (!isMounted()) return false;
          ref.invalidate(messagesProvider(folder));
          final freshList = await repository.getCachedMessages(moved.folderId);
          if (!isMounted()) return false;
          final freshMessage = freshList.firstWhere((m) => m.id == moved.id, orElse: () => moved);
          _showUndoSnackBar(account, folder, freshMessage, 'Archived');
          return true;
        case SwipeAction.delete:
          final result = await repository.deleteMessage(account, folder, message);
          if (!isMounted()) return false;
          ref.invalidate(messagesProvider(folder));
          if (result.folderId != folder.id) {
            final freshList = await repository.getCachedMessages(result.folderId);
            if (!isMounted()) return false;
            final freshMessage = freshList.firstWhere((m) => m.id == result.id, orElse: () => result);
            _showUndoSnackBar(account, folder, freshMessage, 'Deleted');
          }
          return true;
        case SwipeAction.flag:
          await repository.markFlagged(account, folder, message, !message.isFlagged);
          break;
        case SwipeAction.toggleRead:
          await repository.markRead(account, folder, message, !message.isRead);
          break;
        case SwipeAction.none:
          break;
      }
      if (!isMounted()) return false;
      ref.invalidate(messagesProvider(folder));
      return false;
    } catch (e) {
      if (isMounted()) {
        ref.invalidate(messagesProvider(folder));
      }
      if (messenger != null && messenger.mounted) {
        _showAutoDismissingSnackBar(
          messenger,
          SnackBar(
            content: Text("Couldn't ${action.label.toLowerCase()} — $e"),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => performSwipeAction(account: account, folder: folder, action: action, message: message),
            ),
          ),
        );
      }
      return false;
    }
  }

  void _showUndoSnackBar(MailAccount account, MailFolder originalFolder, MailMessage movedMessage, String verb) {
    if (!isMounted()) return;
    final messenger = messengerOf();
    if (messenger == null) return;

    // A move whose server didn't report a post-move UID (no UIDPLUS) is
    // persisted under a synthetic negative placeholder uid. Undoing it
    // would send e.g. `UID MOVE -1 ...`, which the server cannot honour.
    final canUndo = movedMessage.uid >= 0;

    _showAutoDismissingSnackBar(
      messenger,
      SnackBar(
        content: Text(canUndo ? verb : "$verb — can't be undone"),
        action: canUndo
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  try {
                    if (!isMounted()) {
                      throw StateError('the message list is no longer open');
                    }
                    final repository = await ref.read(mailRepositoryProvider.future);
                    final folders = await repository.getCachedFolders(originalFolder.accountId);
                    final currentFolder = folders.firstWhere(
                      (f) => f.id == movedMessage.folderId,
                      orElse: () => throw StateError('the folder it was moved to is no longer available'),
                    );
                    await repository.moveMessage(account, currentFolder, originalFolder, movedMessage);
                    if (!isMounted()) return;
                    ref.invalidate(messagesProvider(originalFolder));
                  } catch (e) {
                    if (messenger.mounted) {
                      _showAutoDismissingSnackBar(messenger, SnackBar(content: Text("Couldn't undo — $e")));
                    }
                  }
                },
              )
            : null,
      ),
    );
  }
}
```

This mirrors exactly what the original inline code did — `ref.invalidate(messagesProvider(folder))` — the four call sites above just call it directly, with `messagesProvider` now imported alongside the controller's other provider imports.

- [ ] **Step 2: Rewire `FolderViewScreen` to use the controller**

In `lib/screens/folder_view_screen.dart`:

1. Add the import: `import '../widgets/message_swipe_controller.dart';`
2. Delete `_iconFor`, `_colorFor`, `_buildActionPane`, `_performSwipeAction`, `_showUndoSnackBar`, `_showAutoDismissingSnackBar`, and the `_snackBarDismissTimer` field from `_MessageListState` — they now live in the controller.
3. Add a controller field and construct it in `initState`/tear it down in `dispose`:

```dart
class _MessageListState extends ConsumerState<_MessageList> {
  final Set<int> _pendingRemoval = {};
  late final MessageSwipeController _swipeController;

  MailFolder get folder => widget.folder;

  @override
  void initState() {
    super.initState();
    _swipeController = MessageSwipeController(
      ref,
      isMounted: () => mounted,
      messengerOf: () => mounted ? ScaffoldMessenger.maybeOf(context) : null,
    );
  }

  @override
  void dispose() {
    _swipeController.dispose();
    super.dispose();
  }
```

4. `_MessageList` needs the resolved `MailAccount`, not just the folder — its parent (`FolderViewScreen`) already resolves the account list via `accountsProvider` for `_findAccount()`. Widen `_MessageList`'s constructor:

```dart
class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({required this.account, required this.folder});

  final MailAccount account;
  final MailFolder folder;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}
```

   and update its one call site inside `FolderViewScreen.build`'s `data:` branch:

```dart
              if (current != null) Expanded(child: _MessageList(account: _requireAccount(), folder: current)),
```

   adding this small helper to `_FolderViewScreenState` (it mirrors `_findAccount()`'s lookup, but throws instead of returning null — by the time `foldersAsync` has data, `accountsProvider` has already resolved, since `foldersProvider` itself awaits `accountsProvider.future` before it can succeed). `ref` is already available as this State's own field, same as `_findAccount()` uses below it:

```dart
  MailAccount _requireAccount() {
    final accounts = ref.watch(accountsProvider).value!;
    return accounts.firstWhere((a) => a.id == widget.accountId);
  }
```

5. In `_MessageListState.build`, update the `Slidable` construction to call the controller instead of the deleted private methods:

```dart
              return Slidable(
                key: ValueKey(message.id),
                startActionPane: _swipeController.buildActionPane(
                  primary: swipeConfig.leftPrimary,
                  secondary: swipeConfig.leftSecondary,
                  account: widget.account,
                  folder: folder,
                  message: message,
                  onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                ),
                endActionPane: _swipeController.buildActionPane(
                  primary: swipeConfig.rightPrimary,
                  secondary: swipeConfig.rightSecondary,
                  account: widget.account,
                  folder: folder,
                  message: message,
                  onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                ),
                child: MessageListTile(
                  message: message,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => MessageDetailScreen(folder: folder, message: message)),
                  ),
                ),
              );
```

   (Drop the old `swipeFolder` local and the `_performSwipeAction`/`_showUndoSnackBar`/`_iconFor`/`_colorFor` method bodies entirely — they're gone from this file now.)

- [ ] **Step 3: Run the full existing regression suite**

Run: `flutter test test/widget/folder_view_screen_test.dart`
Expected: PASS, all pre-existing cases unchanged — this is the proof the extraction is behavior-preserving. If anything fails, the extraction introduced a behavior change; fix the controller/screen wiring (not the test) until it's green again.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/message_swipe_controller.dart lib/screens/folder_view_screen.dart
git commit -m "refactor: extract MessageSwipeController from FolderViewScreen

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 6: `MessageListTile` gains an account-color dot

**Files:**
- Modify: `lib/widgets/message_list_tile.dart`
- Modify: `test/widget/message_list_tile_test.dart` (add cases; existing cases must stay green)

**Interfaces:**
- Produces: `MessageListTile(..., accountColor: Color?)` — optional, defaults to `null` (no dot), used by `UnifiedInboxScreen` (Task 8). `FolderViewScreen`'s existing call site is unaffected (omits the new param).

- [ ] **Step 1: Add the failing tests**

Append to `test/widget/message_list_tile_test.dart` (keep the existing `import`s and the existing `message()` helper):

```dart
  testWidgets('shows a colored dot in the leading slot when accountColor is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          accountColor: Colors.teal,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.leading, isNotNull);
    final container = tester.widget<Container>(find.byKey(const Key('accountColorDot')));
    expect((container.decoration as BoxDecoration).color, Colors.teal);
  });

  testWidgets('shows no leading widget when accountColor is null and the message did not fail to send', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.leading, isNull);
  });

  testWidgets('a failed-send message shows the error icon even when accountColor is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.failed),
          onTap: () {},
          accountColor: Colors.teal,
        ),
      ),
    ));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byKey(const Key('accountColorDot')), findsNothing);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/message_list_tile_test.dart`
Expected: FAIL — `accountColor` is not a defined named parameter.

- [ ] **Step 3: Implement**

```dart
// lib/widgets/message_list_tile.dart
import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/mail_message.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({super.key, required this.message, required this.onTap, this.accountColor});

  final MailMessage message;
  final VoidCallback onTap;

  /// Set by callers showing rows from multiple accounts at once (the
  /// unified inbox) so each row is visually attributable to its account.
  /// Null in the single-account folder view, where every row is obviously
  /// the same account and a dot would just be noise.
  final Color? accountColor;

  @override
  Widget build(BuildContext context) {
    final failed = message.sendStatus == MailSendStatus.failed;
    return ListTile(
      tileColor: message.isFlagged ? Colors.orange.withValues(alpha: 0.08) : null,
      leading: failed
          ? const Icon(Icons.error_outline, color: Colors.red)
          : accountColor != null
              ? Container(
                  key: const Key('accountColorDot'),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: accountColor, shape: BoxShape.circle),
                )
              : null,
      title: Text(
        message.subject,
        style: TextStyle(fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold),
      ),
      subtitle: Text(
        failed
            ? '${message.from} — Failed to send'
            : '${message.from} — ${message.snippet}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.isFlagged) const Icon(Icons.flag, size: 16, color: Colors.orange),
          Text('${message.date.toLocal().month}/${message.date.toLocal().day}'),
        ],
      ),
      onTap: onTap,
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/message_list_tile_test.dart`
Expected: PASS, including all pre-existing cases.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/message_list_tile.dart test/widget/message_list_tile_test.dart
git commit -m "feat(unified-inbox): add optional account-color dot to MessageListTile

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 7: Compose account picker

**Files:**
- Create: `lib/widgets/compose_account_picker.dart`
- Test: `test/widget/compose_account_picker_test.dart`

**Interfaces:**
- Produces: `Future<MailAccount?> showComposeAccountPicker(BuildContext context, List<MailAccount> accounts)`. Used by `UnifiedInboxScreen` (Task 8).

- [ ] **Step 1: Write the failing test**

```dart
// test/widget/compose_account_picker_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/widgets/compose_account_picker.dart';

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );

  testWidgets('lists every account and resolves with the one tapped', (tester) async {
    MailAccount? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            picked = await showComposeAccountPicker(context, [work, personal]);
          },
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(picked, personal);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/compose_account_picker_test.dart`
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/widgets/compose_account_picker.dart
import 'package:flutter/material.dart';
import '../models/mail_account.dart';

/// A bottom sheet listing [accounts] to compose from; resolves with the
/// tapped account, or null if dismissed without a choice. Used by
/// `UnifiedInboxScreen`'s compose FAB, which has no single "current
/// account" the way `FolderViewScreen`'s does.
Future<MailAccount?> showComposeAccountPicker(BuildContext context, List<MailAccount> accounts) {
  return showModalBottomSheet<MailAccount>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Compose from', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final account in accounts)
            ListTile(
              title: Text(account.displayName),
              subtitle: Text(account.email),
              onTap: () => Navigator.of(context).pop(account),
            ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/compose_account_picker_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/compose_account_picker.dart test/widget/compose_account_picker_test.dart
git commit -m "feat(unified-inbox): add compose account picker bottom sheet

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 8: `UnifiedInboxScreen`

**Files:**
- Create: `lib/screens/unified_inbox_screen.dart`
- Test: `test/widget/unified_inbox_screen_test.dart`

**Interfaces:**
- Consumes: `unifiedInboxProvider`, `syncErrorProvider.family<String?, int>`, `accountsProvider`, `swipeActionConfigProvider`, `MessageSwipeController`, `accountColorFor`, `showComposeAccountPicker`, `MessageListTile(accountColor:)`, `messagesProvider.family`.
- Produces: `UnifiedInboxScreen` (no constructor params — reads accounts itself), pushed from the home screen (Task 9).

- [ ] **Step 1: Write the failing tests**

```dart
// test/widget/unified_inbox_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/models/unified_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/screens/unified_inbox_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  _FakeSwipeActionConfigNotifier(this._initial);
  final SwipeActionConfig _initial;
  @override
  SwipeActionConfig build() => _initial;
}

class MockMailRepository extends Mock implements MailRepository {}

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final workMessage = MailMessage(
    id: 100, folderId: 10, uid: 1, subject: 'From work', from: 'a@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 20), snippet: 'Hi',
  );
  final personalMessage = MailMessage(
    id: 200, folderId: 20, uid: 1, subject: 'From personal', from: 'b@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 21), snippet: 'Hey',
  );

  setUpAll(() {
    registerFallbackValue(work);
    registerFallbackValue(workInbox);
    registerFallbackValue(workMessage);
  });

  testWidgets('renders merged rows from every account, newest first', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => [
              UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
              UnifiedMessage(message: workMessage, folder: workInbox, account: work),
            ]),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('From work'), findsOneWidget);
    expect(find.text('From personal'), findsOneWidget);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles[0].title as Text).data, 'From personal'); // newest first
    expect((tiles[1].title as Text).data, 'From work');
  });

  testWidgets('a full swipe archives the row against its OWN account, not a fixed one', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = personalMessage.copyWith(folderId: 999);
    var archived = false;
    when(() => repository.archiveMessage(personal, personalInbox, personalMessage)).thenAnswer((_) async {
      archived = true;
      return archivedMessage;
    });
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => archived
            ? [UnifiedMessage(message: workMessage, folder: workInbox, account: work)]
            : [
                UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
                UnifiedMessage(message: workMessage, folder: workInbox, account: work),
              ]),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.timedDrag(find.text('From personal'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    verify(() => repository.archiveMessage(personal, personalInbox, personalMessage)).called(1);
  });

  testWidgets('compose FAB opens the account picker with 2+ accounts and pushes ComposeScreen for the chosen one', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    expect(find.text('Compose from'), findsOneWidget);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(find.text('Compose'), findsOneWidget); // ComposeScreen's AppBar title
  });

  testWidgets('a sync error for one account shows a dismissible banner naming the failure count', (tester) async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
      unifiedInboxProvider.overrideWith((ref) async => [
            UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
          ]),
      swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
    ]);
    addTearDown(container.dispose);
    container.read(syncErrorProvider(1).notifier).state = 'connection refused';

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 account'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Dismiss'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 account'), findsNothing);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/unified_inbox_screen_test.dart`
Expected: FAIL — `lib/screens/unified_inbox_screen.dart` doesn't exist.

- [ ] **Step 3: Implement**

```dart
// lib/screens/unified_inbox_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/mail_account.dart';
import '../models/unified_message.dart';
import '../providers/account_providers.dart';
import '../providers/message_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../providers/sync_status_providers.dart';
import '../providers/unified_inbox_providers.dart';
import '../widgets/account_color.dart';
import '../widgets/compose_account_picker.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/message_swipe_controller.dart';
import '../widgets/sync_error_banner.dart';
import 'compose_screen.dart';
import 'message_detail_screen.dart';

class UnifiedInboxScreen extends ConsumerWidget {
  const UnifiedInboxScreen({super.key});

  Future<void> _compose(BuildContext context, WidgetRef ref) async {
    final accounts = await ref.read(accountsProvider.future);
    if (!context.mounted) return;
    final MailAccount? chosen =
        accounts.length == 1 ? accounts.single : await showComposeAccountPicker(context, accounts);
    if (chosen == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ComposeScreen(accountId: chosen.id!)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('All Inboxes')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _compose(context, ref),
        child: const Icon(Icons.edit),
      ),
      body: const _UnifiedMessageList(),
    );
  }
}

class _UnifiedMessageList extends ConsumerStatefulWidget {
  const _UnifiedMessageList();

  @override
  ConsumerState<_UnifiedMessageList> createState() => _UnifiedMessageListState();
}

class _UnifiedMessageListState extends ConsumerState<_UnifiedMessageList> {
  // Same purpose as FolderViewScreen's _pendingRemoval: a dismissed Slidable
  // must not be resurrected by a stale/in-flight unifiedInboxProvider
  // refresh before that refresh actually lands.
  final Set<int> _pendingRemoval = {};
  late final MessageSwipeController _swipeController;

  @override
  void initState() {
    super.initState();
    _swipeController = MessageSwipeController(
      ref,
      isMounted: () => mounted,
      messengerOf: () => mounted ? ScaffoldMessenger.maybeOf(context) : null,
    );
  }

  @override
  void dispose() {
    _swipeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unifiedAsync = ref.watch(unifiedInboxProvider);
    final accountsAsync = ref.watch(accountsProvider);
    final swipeConfig = ref.watch(swipeActionConfigProvider);

    // One sync-error banner covering every contributing account, rather
    // than one per account — mirrors FolderViewScreen's single banner, just
    // aggregated. Only meaningful once we know which accounts exist.
    final failedAccountCount = accountsAsync.valueOrNull
            ?.where((a) => ref.watch(syncErrorProvider(a.id!)) != null)
            .length ??
        0;

    return unifiedAsync.when(
      data: (messages) {
        _pendingRemoval.retainAll(messages.map((u) => u.message.id).whereType<int>());
        final visible = messages.where((u) => !_pendingRemoval.contains(u.message.id)).toList();

        return Column(
          children: [
            if (failedAccountCount > 0)
              MaterialBanner(
                content: Text(
                  '$failedAccountCount account${failedAccountCount == 1 ? '' : 's'} failed to sync — showing saved data',
                ),
                actions: [
                  TextButton(
                    onPressed: () => ref.invalidate(unifiedInboxProvider),
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: () {
                      for (final account in accountsAsync.valueOrNull ?? const []) {
                        ref.read(syncErrorProvider(account.id!).notifier).state = null;
                      }
                    },
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  final current = ref.read(unifiedInboxProvider).valueOrNull ?? const [];
                  final folders = {for (final u in current) u.folder.id: u.folder}.values;
                  for (final folder in folders) {
                    ref.invalidate(messagesProvider(folder));
                  }
                  ref.invalidate(unifiedInboxProvider);
                },
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final UnifiedMessage unified = visible[index];
                    return Slidable(
                      key: ValueKey(unified.message.id),
                      startActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.leftPrimary,
                        secondary: swipeConfig.leftSecondary,
                        account: unified.account,
                        folder: unified.folder,
                        message: unified.message,
                        onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                      ),
                      endActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.rightPrimary,
                        secondary: swipeConfig.rightSecondary,
                        account: unified.account,
                        folder: unified.folder,
                        message: unified.message,
                        onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                      ),
                      child: MessageListTile(
                        message: unified.message,
                        accountColor: accountColorFor(unified.account.id!),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MessageDetailScreen(folder: unified.folder, message: unified.message),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SyncErrorBanner(
        message: error.toString(),
        onRetry: () => ref.invalidate(unifiedInboxProvider),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/unified_inbox_screen_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/screens/unified_inbox_screen.dart test/widget/unified_inbox_screen_test.dart
git commit -m "feat(unified-inbox): add UnifiedInboxScreen

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 9: Home screen — "All Inboxes" tile above the account list

**Files:**
- Modify: `lib/screens/account_list_screen.dart`
- Test: Create `test/widget/account_list_screen_test.dart`

**Interfaces:**
- Consumes: `totalUnreadCountProvider`, `UnifiedInboxScreen` (Task 8).
- No new exports — `AccountListScreen`'s public constructor is unchanged.

- [ ] **Step 1: Write the failing tests**

```dart
// test/widget/account_list_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/screens/account_list_screen.dart';
import 'package:imap_mail/screens/unified_inbox_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );

  testWidgets('shows an "All Inboxes" tile above the unchanged per-account rows, with the total unread count', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        totalUnreadCountProvider.overrideWith((ref) async => 8),
      ],
      child: const MaterialApp(home: AccountListScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('All Inboxes'), findsOneWidget);
    expect(find.text('2 accounts'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
  });

  testWidgets('tapping "All Inboxes" opens UnifiedInboxScreen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        totalUnreadCountProvider.overrideWith((ref) async => 0),
      ],
      child: const MaterialApp(home: AccountListScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('All Inboxes'));
    await tester.pumpAndSettle();

    expect(find.byType(UnifiedInboxScreen), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/account_list_screen_test.dart`
Expected: FAIL — no "All Inboxes" text found.

- [ ] **Step 3: Implement**

```dart
// lib/screens/account_list_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import '../providers/unified_inbox_providers.dart';
import 'account_form_screen.dart';
import 'folder_view_screen.dart';
import 'settings_screen.dart';
import 'unified_inbox_screen.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final unreadAsync = ref.watch(totalUnreadCountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts'), actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountFormScreen()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ]),
      body: accountsAsync.when(
        data: (accounts) => ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('All Inboxes'),
              subtitle: Text('${accounts.length} accounts'),
              trailing: unreadAsync.maybeWhen(
                data: (count) => count > 0 ? Text('$count') : null,
                orElse: () => null,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UnifiedInboxScreen()),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(alignment: Alignment.centerLeft, child: Text('Accounts')),
            ),
            for (final account in accounts)
              ListTile(
                title: Text(account.displayName),
                subtitle: Text(account.email),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => FolderViewScreen(accountId: account.id!)),
                ),
              ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/account_list_screen_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/screens/account_list_screen.dart test/widget/account_list_screen_test.dart
git commit -m "feat(unified-inbox): add All Inboxes tile to the home screen

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 10: Route straight to the single account when there's only one

**Files:**
- Modify: `lib/app.dart`
- Modify: `test/widget/app_smoke_test.dart` (add a case)

**Interfaces:**
- No new exports; `ImapMailApp`'s constructor is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `test/widget/app_smoke_test.dart` (it already has `databaseOverride()`/`preferencesOverride()` helpers and the sqflite ffi `setUpAll` — reuse them):

```dart
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
```

Add this one new import at the top of the file, alongside the existing ones: `import 'package:imap_mail/providers/folder_providers.dart';`. (`database_providers.dart` is already imported; `sqflite`'s `OpenDatabaseOptions`/`inMemoryDatabasePath` are already in scope via the existing `sqflite_common_ffi` import, which re-exports them — no changes needed for either.)

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/app_smoke_test.dart`
Expected: FAIL — finds "Accounts" (today's behavior routes every non-empty account list, including 1, to `AccountListScreen`).

- [ ] **Step 3: Implement**

In `lib/app.dart`, change the `home:` builder's `data:` branch:

```dart
      home: Consumer(
        builder: (context, ref, _) {
          final accountsAsync = ref.watch(accountsProvider);
          return accountsAsync.when(
            data: (accounts) => switch (accounts.length) {
              0 => const AccountFormScreen(),
              1 => FolderViewScreen(accountId: accounts.single.id!),
              _ => const AccountListScreen(),
            },
            loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
            error: (error, _) => Scaffold(
              body: Center(child: Text('Failed to load accounts: $error')),
            ),
          );
        },
      ),
```

Add the import: `import 'screens/folder_view_screen.dart';`

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/app_smoke_test.dart`
Expected: PASS, including the pre-existing cases (which all use an empty account list, so still hit the `AccountFormScreen` branch unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/app.dart test/widget/app_smoke_test.dart
git commit -m "feat(unified-inbox): skip the account list when only one account exists

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

### Task 11: App icon unread badge (iOS + Android)

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/services/app_icon_badge.dart`
- Create: `lib/providers/badge_providers.dart`
- Modify: `lib/app.dart`
- Test: `test/providers/badge_providers_test.dart`

**Interfaces:**
- Produces: `abstract class AppIconBadge { Future<void> setCount(int count); }`, `PlatformAppIconBadge implements AppIconBadge`, `appIconBadgeProvider = Provider<AppIconBadge>`. Consumes `totalUnreadCountProvider` (Task 4).

- [ ] **Step 1: Add the dependencies**

```yaml
# pubspec.yaml — add under dependencies:
  app_badge_plus: ^1.2.2
  permission_handler: ^11.3.1
```

Run: `flutter pub get`
Expected: resolves cleanly (no version conflicts with existing dependencies).

- [ ] **Step 2: Write the failing test**

```dart
// test/providers/badge_providers_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/badge_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/services/app_icon_badge.dart';
import 'package:imap_mail/models/mail_folder.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeAppIconBadge implements AppIconBadge {
  final List<int> calls = [];
  @override
  Future<void> setCount(int count) async => calls.add(count);
}

void main() {
  const account = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  final inbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 3);

  test('listening to totalUnreadCountProvider pushes its value to AppIconBadge', () async {
    final fakeBadge = _FakeAppIconBadge();
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      foldersProvider.overrideWith((ref, accountId) async => [inbox]),
      appIconBadgeProvider.overrideWithValue(fakeBadge),
    ]);
    addTearDown(container.dispose);

    // Mirrors what app.dart's root-level ref.listen does.
    container.listen<AsyncValue<int>>(totalUnreadCountProvider, (previous, next) {
      final count = next.valueOrNull;
      if (count != null) container.read(appIconBadgeProvider).setCount(count);
    }, fireImmediately: true);

    await container.read(totalUnreadCountProvider.future);
    // Let the listener's fire-immediately callback's inner Future settle.
    await Future<void>.delayed(Duration.zero);

    expect(fakeBadge.calls, [3]);
  });

  test('reaching zero unread sends setCount(0), clearing a stale badge', () async {
    final fakeBadge = _FakeAppIconBadge();
    final zeroInbox = inbox.copyWith(unreadCount: 0);
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      foldersProvider.overrideWith((ref, accountId) async => [zeroInbox]),
      appIconBadgeProvider.overrideWithValue(fakeBadge),
    ]);
    addTearDown(container.dispose);

    container.listen<AsyncValue<int>>(totalUnreadCountProvider, (previous, next) {
      final count = next.valueOrNull;
      if (count != null) container.read(appIconBadgeProvider).setCount(count);
    }, fireImmediately: true);

    await container.read(totalUnreadCountProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(fakeBadge.calls, [0]);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/providers/badge_providers_test.dart`
Expected: FAIL — `lib/services/app_icon_badge.dart` and `lib/providers/badge_providers.dart` don't exist.

- [ ] **Step 4: Implement the badge service**

```dart
// lib/services/app_icon_badge.dart
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Sets the OS-level unread-count badge on the app icon. Cosmetic only —
/// every implementation must never throw out of `setCount` and never block
/// the caller on anything beyond what's needed to attempt the update.
abstract class AppIconBadge {
  Future<void> setCount(int count);
}

/// iOS + Android only, per this feature's design spec — badges are
/// meaningless on desktop/web platforms this app also ships to, so this
/// no-ops everywhere else rather than attempting anything.
class PlatformAppIconBadge implements AppIconBadge {
  bool _permissionChecked = false;
  bool _permissionGranted = true; // Android needs no explicit grant for this.

  @override
  Future<void> setCount(int count) async {
    if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
      return;
    }
    try {
      if (!_permissionChecked) {
        _permissionChecked = true;
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          // Badge-setting on iOS is gated behind notification authorization
          // (the `.badge` option specifically). Requested here — lazily, on
          // the first real badge update — rather than at cold start, so a
          // fresh install with zero accounts never sees a permission prompt
          // before it's done anything.
          final status = await Permission.notification.request();
          _permissionGranted = status.isGranted;
        }
      }
      if (!_permissionGranted) return;
      await AppBadgePlus.updateBadge(count);
    } catch (_) {
      // Cosmetic feature: a plugin/platform failure (e.g. an Android
      // launcher with no badge support) must never surface to the user or
      // block anything else in the app.
    }
  }
}
```

- [ ] **Step 5: Implement the provider**

```dart
// lib/providers/badge_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_icon_badge.dart';

final appIconBadgeProvider = Provider<AppIconBadge>((ref) => PlatformAppIconBadge());
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/providers/badge_providers_test.dart`
Expected: PASS

- [ ] **Step 7: Wire it into the app root**

In `lib/app.dart`, add the imports:
```dart
import 'providers/badge_providers.dart';
import 'providers/unified_inbox_providers.dart';
```

Change `ImapMailApp` from a `ConsumerWidget` to a `ConsumerStatefulWidget` so the listener is registered exactly once, alongside the theme:

```dart
class ImapMailApp extends ConsumerStatefulWidget {
  const ImapMailApp({super.key});

  @override
  ConsumerState<ImapMailApp> createState() => _ImapMailAppState();
}

class _ImapMailAppState extends ConsumerState<ImapMailApp> {
  @override
  void initState() {
    super.initState();
    // Foreground-only by design (see the design spec's Non-goals): this app
    // has no background sync, so the badge can only reflect the count as of
    // the last time the app was open. ref.listen only fires while this
    // widget is alive, which is exactly what makes that true without any
    // extra lifecycle plumbing. Riverpod supports calling ref.listen
    // directly in initState (unlike ref.watch, which build() would need) —
    // this registers the listener once for the app's whole lifetime.
    ref.listen<AsyncValue<int>>(totalUnreadCountProvider, (previous, next) {
      final count = next.valueOrNull;
      if (count != null) {
        ref.read(appIconBadgeProvider).setCount(count);
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Cobalt Mail',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _brandSeed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandSeed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: themeMode,
      home: Consumer(
        builder: (context, ref, _) {
          final accountsAsync = ref.watch(accountsProvider);
          return accountsAsync.when(
            data: (accounts) => switch (accounts.length) {
              0 => const AccountFormScreen(),
              1 => FolderViewScreen(accountId: accounts.single.id!),
              _ => const AccountListScreen(),
            },
            loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
            error: (error, _) => Scaffold(
              body: Center(child: Text('Failed to load accounts: $error')),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 8: Run the full app smoke suite**

Run: `flutter test test/widget/app_smoke_test.dart`
Expected: PASS — confirms wiring the listener didn't break app startup. (The smoke tests don't assert anything about the badge itself; that's covered by Step 6's provider-level test plus the manual on-device check below.)

- [ ] **Step 9: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/services/app_icon_badge.dart lib/providers/badge_providers.dart lib/app.dart test/providers/badge_providers_test.dart
git commit -m "feat(unified-inbox): add app icon unread badge for iOS/Android

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T1yfopK8StmrjKBFVMcJpe"
```

---

## Final verification (after all 11 tasks)

- [ ] Run the full suite: `flutter test` — expect all tests (pre-existing + new) green.
- [ ] Run `flutter analyze` — expect no new warnings/errors introduced by this feature.
- [ ] Manual, per the spec's Verification section:
  - With 2+ configured accounts: home screen shows "All Inboxes" with the correct total unread, opens a correctly merged/sorted list.
  - Swipe archive/delete/flag/mark-read on unified-view rows from two different accounts; confirm each hits the correct account's mailbox (check via another client).
  - With exactly 1 account: app opens straight into its folders.
  - On a real iOS device/simulator and an Android device with a badge-supporting launcher (e.g. Pixel): confirm the badge appears/updates and clears at zero unread.
