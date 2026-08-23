# Global Search — Design Spec

Date: 2026-08-23
Status: Approved

## 1. Purpose

Add search across all of the user's cached mail. Today there is no way to find a message except by browsing folders — the README lists this as a known gap ("No in-app search yet — planned as a fast-follow"). This spec closes it.

## 2. Goals / Non-goals

**Goals**
- One search that covers every folder (Inbox/Sent/Trash/Archive/etc.) of every configured account at once — true "global" search, not scoped to whatever screen you launched it from.
- Matches against subject, sender name, sender address, and snippet — the fields already cached and already shown in list rows.
- Reachable via a search icon in the app bar of both `FolderViewScreen` and `UnifiedInboxScreen`, so it's available whether the user has one account or several.
- Results render exactly like any other message list: same tile, same swipe actions (archive/delete/flag/mark read), same tap-to-open behavior — each result already carries the account/folder it needs to act correctly.
- Live filtering as the user types, debounced so it isn't re-querying on every keystroke.

**Non-goals**
- No live IMAP server-side search — local cache only, consistent with this app's "no extra sync" design principle used elsewhere (e.g. `totalUnreadCountProvider`).
- No full-body search for messages that haven't been opened/downloaded — only what's already cached (subject/sender/snippet). Searching downloaded bodies too is a plausible fast-follow, not v1.
- No relevance ranking — results sort newest-first, same as every other list in the app.
- No search history / recent searches.
- No FTS5 or any schema/migration change — the existing `messages` table and plain `LIKE`-equivalent substring matching is enough at this app's local-cache scale, and matches how the rest of the codebase does DB access (no FTS used anywhere today).

## 3. Current-state gap this closes

There is no search entry point anywhere in the app. `MessageDao` has no query beyond `getForFolder`/`getById`. The only way to find a specific message is to know which folder (and which account, if there's more than one) it's in and scroll to it.

## 4. Approach

### Data model

No new types needed. `UnifiedMessage` (`message`, `folder`, `account`), introduced for the unified inbox, already bundles exactly what a search result row needs — reused as-is.

### Provider

`searchResultsProvider` (`FutureProvider.family<List<UnifiedMessage>, String>`, in a new `providers/search_providers.dart`):

- Empty/whitespace-only query → returns `[]` immediately, no DB reads.
- Otherwise: watches `accountsProvider`; for each account, calls `repository.getCachedFolders(accountId)` and, for every folder where `!folder.isLocalOnly` (excludes Outbox — not a real mailbox), calls `repository.getCachedMessages(folder.id!)`.
- Filters each folder's messages to those where the lowercased query is a substring of `subject`, `fromName`, `from`, or `snippet` (null-safe — `fromName` is nullable).
- Wraps each match as `UnifiedMessage(message: ..., folder: ..., account: ...)`, merges across every account/folder, sorts by `message.date` descending.
- Purely local reads (`getCachedFolders`/`getCachedMessages` are already cache-only, no IMAP calls) — mirrors how `unifiedInboxProvider`'s `_fetchForAccount` is built, just widened from "one Inbox folder" to "every non-local-only folder."

This is a plain `FutureProvider.family` keyed by the search string, not a debounced provider — debouncing is the screen's job (below), keeping the provider itself simple and directly testable with a `ProviderContainer`.

### Screen

New `SearchScreen` (`screens/search_screen.dart`, `ConsumerStatefulWidget`):

- `AppBar` whose `title` is a `TextField` (autofocus, `textInputAction: TextInputAction.search`, a clear (×) button that resets the field), leading back arrow to dismiss.
- Local state: `TextEditingController` plus a debounced `String _query` (`Timer`, 300ms, cancelled/restarted `onChanged`; mirrors the debounce idiom already used for pull-to-refresh's spinner timing elsewhere in this codebase, just applied to text input instead of a refresh future).
- Body, driven by `ref.watch(searchResultsProvider(_query))`:
  - `_query` blank → centered prompt ("Search your mail"), reusing `EmptyFolderState`'s visual style.
  - Non-blank, `AsyncLoading` → spinner (rare in practice — local reads are fast, this mostly covers the debounce window before the first result lands).
  - Non-blank, empty result list → `EmptyFolderState`-style "No results for “…”".
  - Non-blank, results → `ListView.separated`, one `Slidable`-wrapped `MessageListTile` per `UnifiedMessage`, keyed by `message.id` — structurally identical to `UnifiedInboxScreen`'s `_UnifiedMessageList` (same `MessageSwipeController`, same `accountColor: accountColorFor(unified.account.id!)`, same tap → `MessageDetailScreen(folder: unified.folder, message: unified.message)`).
  - `AsyncError` → plain inline error text, no banner/retry — a local DB read failing here isn't the "server unreachable, offer retry" case the sync-error banners exist for.
- Owns its own `MessageSwipeController` instance (`initState`/`dispose`), exactly as `_MessageListState` and `_UnifiedMessageListState` already do — each screen's controller is independent, no shared state needed between them.

### Entry points

- `FolderViewScreen`'s `AppBar.actions`: a new `IconButton(icon: Icons.search)` pushing `SearchScreen`, placed before the existing settings gear.
- `UnifiedInboxScreen`'s `AppBar`: currently has no `actions` — gains the same search `IconButton`.

Both reach the same `SearchScreen`; it doesn't take a folder/account parameter, so it's always the full global search regardless of which screen launched it — satisfying "everything, everywhere" even for single-account users who never see `UnifiedInboxScreen`.

## 5. Testing

- **Provider**: `searchResultsProvider` — empty query short-circuits to `[]` with no repository calls; matches across subject/sender-name/sender-address/snippet, case-insensitively; matches span multiple accounts and multiple non-Inbox folders (regression guard for "global" actually meaning global); results exclude `isLocalOnly` folders (Outbox); results sort newest-first; a folder/account with no matches contributes nothing without erroring the whole query.
- **Widget (`SearchScreen`)**: blank-query prompt shown initially; typing does not query before the debounce window elapses (pump partial time, assert no repository call yet); after the debounce window, results render; no-results state renders for a query that matches nothing; tapping a result opens `MessageDetailScreen` with that result's own folder (not whatever folder the search was launched from); swipe-delete on a result calls `deleteMessage` with that result's own account/folder and removes the row — the key regression to guard, same reasoning as the unified inbox's swipe tests.
- **Entry points**: `FolderViewScreen` and `UnifiedInboxScreen` each show a search icon that pushes `SearchScreen`.

## 6. Verification

- Manual: from a single-account setup, search from `FolderViewScreen`'s icon and confirm results include matches from Sent/Trash, not just Inbox.
- Manual, multi-account: search from both `FolderViewScreen` and `UnifiedInboxScreen` and confirm results include matches from every account, not just the one currently in view.
- Manual: swipe-archive and swipe-delete a search result belonging to a non-default account/folder, confirm it affects the correct mailbox (same cross-check approach as the unified-inbox spec's verification).
- Manual: confirm typing quickly doesn't cause visible flicker/lag (debounce working) and that clearing the field returns to the blank-query prompt.
- Run `flutter test`.
