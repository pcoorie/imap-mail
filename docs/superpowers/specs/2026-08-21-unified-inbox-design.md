# Unified Inbox + App Icon Unread Badge — Design Spec

Date: 2026-08-21
Status: Approved

## 1. Purpose

Replace the app's plain, unappealing account-name list as the first thing a multi-account user sees with something more useful: a merged "All Inboxes" view across all accounts, with the ability to drill into an individual account still available underneath it. Additionally, surface the total unread count as a badge on the app icon (iOS/Android).

## 2. Goals / Non-goals

**Goals**
- A single merged, chronologically-sorted view of every account's Inbox folder ("All Inboxes"), reachable from a prominent tile on the home screen, showing a total unread badge.
- The existing per-account list stays available directly beneath that tile, unchanged in behavior — tapping an account still opens just that account's folders as today.
- Merged rows show a small per-account color indicator, support the same swipe actions (archive/delete/flag/mark read) as a single-account view, and open the same `MessageDetailScreen` on tap.
- Composing from the unified view's FAB prompts for which account to send from (skipped when only one account exists).
- With exactly one account configured, skip straight to that account's folders — no unified tile, no extra tap (matches today's effective behavior).
- An OS-level app icon badge (iOS + Android only) showing total unread count, updated whenever the app is in the foreground and syncs.

**Non-goals**
- No unified view for folder types other than Inbox (no unified Sent, unified Trash, etc.) — out of scope for this spec.
- No background sync / push. The app has none today; adding it is a separate, much larger project. The badge is foreground-only and goes stale while the app is closed — an accepted v1 limitation.
- No badge support for macOS/Windows/Linux/web — OS support is inconsistent-to-nonexistent there; only iOS and Android get the badge.
- No bulk/multi-select actions in the unified view.

## 3. Current-state gap this closes

`AccountsListScreen` is the app's home screen whenever 2+ accounts exist, and shows nothing but a bare `ListTile` per account (name + email) — no unread counts, no way to see mail across accounts without picking one first. `app.dart` routes here for any non-empty account list, including a single account, forcing an extra tap even in the common one-account case. Separately, `lastSyncErrorProvider` (`sync_status_providers.dart`) is a single global `StateProvider<String?>` — safe today because only one account's `messagesProvider` is ever active on screen at once, but a real bug once multiple accounts sync concurrently, which the unified view introduces.

## 4. Approach

### Data model

New wrapper type, `UnifiedMessage`:
```dart
class UnifiedMessage {
  final MailMessage message;
  final MailFolder folder;
  final MailAccount account;
}
```
Bundles everything a merged row or its swipe actions need, avoiding re-lookups by id.

### Providers

- `unifiedInboxProvider` (`FutureProvider<List<UnifiedMessage>>`): watches `accountsProvider`; for each account watches `foldersProvider(accountId)` and selects the folder with `type == MailFolderType.inbox`; for each of those folders watches the existing `messagesProvider(folder)` unchanged, reusing its sync-then-cache-fallback behavior as-is. Merges all accounts' results into one list sorted by `date` descending.
- `totalUnreadCountProvider` (`int`): sums `unreadCount` across each account's Inbox `MailFolder` row (already fetched by `foldersProvider`; no extra sync). Consumed by both the home screen's "All Inboxes" tile badge and the app icon badge (section on badge below).
- `lastSyncErrorProvider` **becomes** `syncErrorProvider`, a `StateProvider.family<String?, int>` keyed by `accountId`, replacing the current single global instance. Required because the unified view runs multiple accounts' `messagesProvider` concurrently, and a shared global would let one account's error/success overwrite another's. `message_providers.dart` and `folder_providers.dart` update their two call sites; `FolderViewScreen`'s existing banner reads the keyed version for its own account (mechanical change, no behavior difference for the single-account case).

### Screens

**Home screen** (today's `AccountListScreen`, restructured, class kept): adds an "All Inboxes" `ListTile` above the existing per-account rows — leading inbox icon, trailing badge from `totalUnreadCountProvider`, subtitle "N accounts". Tapping it pushes `UnifiedInboxScreen`. The existing per-account rows below are unchanged. `app.dart` routing: 0 accounts → `AccountFormScreen` (unchanged); exactly 1 account → straight to `FolderViewScreen(accountId)` (unchanged behavior, now made explicit rather than incidental); 2+ accounts → this home screen.

**`UnifiedInboxScreen`** (new): structurally a trimmed `FolderViewScreen` — no folder tabs (Inbox-only), `AppBar` titled "All Inboxes", body driven by `unifiedInboxProvider`. Pull-to-refresh invalidates every underlying `messagesProvider(folder)` in the merge. Row tap opens `MessageDetailScreen(folder: um.folder, message: um.message)` — unchanged signature, no unified-specific handling needed there. FAB: if 2+ accounts, opens a bottom sheet listing accounts to compose from; if only 1 (defensive; routing already avoids showing this screen for 1 account), opens `ComposeScreen(accountId)` directly.

If any contributing account currently has a sync error (see `syncErrorProvider` above) with no cached fallback for its Inbox, that account simply contributes zero rows rather than failing the whole screen — consistent with today's per-folder cache-fallback behavior, just scoped down to "this one account is temporarily empty" instead of "the whole list is empty."

**Swipe actions**: `FolderViewScreen`'s `_MessageListState` currently assumes one ambient `folder`/account for `_performSwipeAction`/`_showUndoSnackBar`. Extracted into a shared `MessageSwipeController`, parameterized per-call by `MailAccount` + `MailFolder` + `MailMessage` instead of reading a single ambient `folder` field. Used by both `FolderViewScreen` (passing its one ambient account/folder) and `UnifiedInboxScreen` (passing each row's own `UnifiedMessage` fields) — removes duplication rather than copy-pasting the existing ~250 lines of swipe/undo logic.

**`MessageListTile`**: gains one new optional param, `accountColor` (`Color?`). When set, renders a small colored dot in the leading slot; falls back to today's "failed send" error icon if both would apply (not reachable in practice — failed-send rows live only in an account's local Outbox, which is never `MailFolderType.inbox` and never appears in the unified list). Account→color mapping: deterministic, `account.id % palette.length` against a fixed set of ~8 `Colors.*` values, computed once and passed down — matching the existing hardcoded-`Color` style already used for swipe-action colors elsewhere in this codebase (no new dependency).

### App icon badge

- New `AppIconBadge` interface (`Future<void> setCount(int count)`), backed by the `app_badge_plus` package (covers iOS + Android under one API; no-ops harmlessly on Android launchers that don't support badges). Kept behind an interface so tests substitute a fake instead of touching platform channels.
- Near the app root (`app.dart`), `ref.listen(totalUnreadCountProvider, ...)` pushes each new count to `AppIconBadge.setCount()`. This only fires while the widget tree is alive, which is what makes it foreground-only per the accepted limitation in Goals/Non-goals — no extra lifecycle plumbing needed.
- iOS: setting a badge requires notification authorization (the `.badge` option). Requested lazily, the first time a badge update is about to happen with a nonzero count (e.g. right after the first account's first successful sync) — not as a cold-start prompt on an empty app. A denial is cached and not re-prompted; subsequent `setCount` calls silently no-op.
- Android: no permission dialog; display is entirely launcher-dependent. Plugin failures are always caught and swallowed — cosmetic feature, must never surface an error or block the UI.
- Removing the last account, or total unread reaching zero, sends `setCount(0)` to clear a stale badge.

## 5. Testing

- **Providers**: `unifiedInboxProvider` merges/sorts correctly across fixture accounts and excludes non-inbox folders; `totalUnreadCountProvider` sums correctly; `syncErrorProvider` family isolates one account's error from another's (regression test for the global-state bug this spec fixes).
- **Widgets**: `UnifiedInboxScreen` renders merged rows with correct account-color dots; `MessageSwipeController`-driven swipe actions (archive/delete/flag/mark read) act against the correct account/folder per row — the key regression to guard, since a wrong-account lookup here would silently mutate the wrong mailbox; compose FAB shows the account picker for 2+ accounts and skips it for 1.
- **Home screen**: "All Inboxes" tile shows the correct aggregate badge and navigates to `UnifiedInboxScreen`; routing test confirming exactly 1 account skips straight to `FolderViewScreen`.
- **Badge**: unit test that `totalUnreadCountProvider`'s value changes drive a fake `AppIconBadge.setCount()` call with the right count, including the zero-on-last-account-removed case. No automated test touches the real OS badge — that is a manual on-device/simulator check.

## 6. Verification

- Manual: with 2+ configured accounts, confirm the home screen shows the "All Inboxes" tile with correct total unread, and that it opens a correctly merged, chronologically sorted list.
- Manual: swipe archive/delete/flag/mark-read on unified-view rows from at least two different accounts, confirm each affects the correct account's mailbox (check via another client, per the existing swipe-gestures spec's verification approach).
- Manual: with exactly 1 account, confirm the app opens straight into that account's folders, no unified tile shown anywhere.
- Manual, on-device: confirm the app icon badge appears/updates on iOS and on an Android launcher that supports it (e.g. Pixel), and clears when unread reaches zero.
- Run `flutter test`.
