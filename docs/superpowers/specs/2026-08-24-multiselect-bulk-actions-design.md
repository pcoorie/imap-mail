# Multi-Select & Bulk Actions (FolderViewScreen) — Design Spec

## Overview

Add long-press multi-select to `FolderViewScreen`'s message list, with a
contextual action bar for bulk **delete (move to Trash)** and **move to
folder**. Modeled visually on Apple Mail / Outlook Mobile's round,
left-aligned selection checkbox.

## Goals

- Long-press any message row to enter selection mode; tap rows to add/remove
  them from the selection.
- Contextual app bar while selecting: exit (X), "N selected" title, bulk
  Trash and bulk Move-to-folder actions.
- Bulk delete and bulk move reuse the existing single-message
  optimistic-move/revert semantics in `MailRepository`, batched over one IMAP
  connection instead of one connection per message.
- A single Undo action reverts the whole batch, mirroring the existing
  per-message undo snackbar.

## Non-Goals (this iteration)

- **Select All** — explicitly deferred.
- Unified Inbox multi-select (cross-account selections). This spec is
  `FolderViewScreen` only.
- Bulk mark read/unread, flag/unflag, or archive. Only Trash and Move ship
  now; the action-bar structure should not preclude adding these later.
- Drag-to-reorder or any multi-folder drag-and-drop.

## UX Design

### Entering / exiting selection mode

- Long-press on a message row enters selection mode with that row selected.
- While selecting, a tap anywhere on a row (not just the checkbox) toggles
  its selection — matches the reference screenshot's full-row tap target and
  full-row highlight on selected rows.
- Tapping the AppBar's leading **X** exits selection mode and clears the
  selection, returning to the normal AppBar (search/settings icons,
  tap-to-open behavior).
- Switching folder tabs or the folder tree while selecting exits selection
  mode and clears it — a selection is scoped to the folder it was made in,
  and there's no sane cross-folder meaning for it.
- If a selected message disappears from `messages` (sync removed it,
  another device deleted it, pull-to-refresh reshuffled the list), it's
  silently dropped from the selection set rather than erroring — same
  spirit as the existing `_pendingRemoval` handling.

### Selection checkbox visual

Round checkbox, left of the existing leading content (avatar / account-color
badge / failed-send icon), per the Apple Mail / Outlook reference:

- **Unselected:** hollow circle, ~24dp, neutral gray outline, no fill.
- **Selected:** filled circle in the theme's primary color, white checkmark
  (`Icons.check`) centered, no outline.
- Selection mode only: the checkbox column doesn't exist (zero width) when
  not selecting, so normal browsing looks exactly as it does today. Entering
  selection mode inserts it before the current leading widget — implemented
  as `MessageListTile` gaining an optional `selectionState` (null =
  no-checkbox / current behavior; `bool` = selecting, render the round
  indicator at that value) rather than changing what `leading` means when
  not selecting.
- Selected rows also get a light background tint (matches the reference
  screenshot's gray row highlight) so a selection is visible without staring
  at the checkbox column.

### Contextual app bar

Replaces `FolderViewScreen`'s normal `AppBar` while selecting (a branch in
the existing `build()`, not a second screen):

- Leading: **X** — exit selection mode.
- Title: **"N selected"**.
- Actions: **Move to folder** icon, **Trash** icon (delete). No overflow
  menu needed for just two actions.
- The FAB (compose) is hidden while selecting — composing isn't a
  meaningful action mid-bulk-selection and the space is better left clear.

### Swipe actions while selecting

`Slidable`'s per-row swipe actions are disabled while selection mode is
active (`enabled: false` on the `Slidable`, or by not providing action
panes at all in this mode) — otherwise a horizontal drag meant to reveal a
swipe action conflicts with the tap-to-toggle gesture, and a swipe-delete
mid-selection would silently invalidate whatever else was selected.

## Architecture

### `_MessageListState` (`folder_view_screen.dart`)

New local state, no new Riverpod provider (selection is inherently scoped
to one screen instance, same reasoning as the existing `_pendingRemoval`
set):

```dart
bool _selecting = false;
final Set<int> _selectedIds = {};
```

- `_enterSelection(int id)` — sets `_selecting = true`, adds `id`.
- `_toggle(int id)` — adds/removes from `_selectedIds`; if it becomes empty,
  falls back out of selection mode automatically (matches the reference
  apps: deselecting the last item exits selection).
- `_exitSelection()` — clears both.
- The `_pendingRemoval.retainAll(...)` line that already prunes stale ids
  each build gets a sibling for `_selectedIds`.

### `MessageListTile` (`message_list_tile.dart`)

Add an optional parameter, e.g. `selected: bool?` (`null` = not in selection
mode, current rendering; non-null = selection mode, render the round
indicator reflecting that value) and an `onLongPress` callback alongside the
existing `onTap`. `onTap`'s meaning is decided by the caller (`_MessageList`
already knows whether it's selecting), not by the tile itself — keeps the
tile a dumb presentation widget.

### `MailRepository` — batched connection methods

New methods alongside the existing single-message ones:

```dart
Future<BulkResult> moveMessages(
  MailAccount account,
  MailFolder from,
  MailFolder to,
  List<MailMessage> messages,
);

Future<BulkResult> deleteMessages(
  MailAccount account,
  MailFolder from,
  List<MailMessage> messages,
);
```

`BulkResult` carries, per message, either the moved/deleted `MailMessage`
(for undo) or the error — keyed by message **id** (`int`), not by
`MailMessage` value equality (`MailMessage extends Equatable` over all its
fields, so the pre- and post-move copies of the same message compare
unequal and can't be used as the same map key): e.g.
`{List<MailMessage> succeeded, Map<int, Object> failed}`.

Each method performs the *same* per-message optimistic-local-then-server
logic as today's `moveMessage`/`deleteMessage` (local DB move first, then
the server call, revert that one row on failure), looped — but the server
calls all reuse **one** `MailTransport`-level connection instead of
reconnecting per message. `deleteMessages` is implemented in terms of
`moveMessages` to Trash, exactly like today's single-message
`deleteMessage` delegates to `moveMessage` — same Trash-folder-missing /
already-in-Trash fallback to permanent local delete applies per message.

### `MailTransport` — batched connection

New transport method:

```dart
Future<Map<int, int?>> moveMessages(
  MailAccount account,
  String password,
  MailFolder from,
  List<MailMessage> messages,
  MailFolder to,
);
```

Opens **one** `enough.MailClient`, connects once, then loops a `UID MOVE`
per message (same single-UID `MessageSequence.fromId` calls as today —
this is not a switch to a true batched IMAP `MessageSequence.fromIds`
command, just amortizing the connect/select-mailbox/disconnect cost across
the whole batch), and disconnects once at the end. Returns each message's
new UID (or `null`, same meaning as today's single-message return) keyed by
the message's **id** (not the `MailMessage` itself — see the `BulkResult`
note above), so the repository layer can reconcile each row exactly as it
does now.

A true single-IMAP-command batch move (`MessageSequence.fromIds` +
`client.moveMessages(sequence, target)`) is explicitly out of scope for
this iteration — noted as future work if per-message round-trip latency
still matters after the connection-reuse fix.

### Folder picker (move-to-folder)

No existing reusable "pick a destination folder" widget — `compose_account_picker.dart`'s
`showModalBottomSheet` picks an *account*, not a folder. Build a new
lightweight bottom sheet listing the current account's folders (excluding
the folder currently being viewed), reusing the same `folders` data
`FolderViewScreen` already loads via `foldersProvider`. Flat list is enough
for v1 — no need to reuse `FolderTreeExpander`'s nested-tree rendering
unless the account has meaningfully deep folder nesting.

## Undo & Partial Failure Handling

- Bulk actions **proceed and report**, not all-or-nothing: a message that
  fails (offline mid-batch, server error) is reverted individually (same as
  today's single-message revert-on-failure) while the rest of the batch
  continues.
- One summary snackbar after the batch completes:
  - All succeeded: `"12 moved to Trash"` / `"12 moved to Archive"`, with
    **Undo**.
  - Partial: `"10 moved, 2 failed"`, with **Undo** (undoes only the 10 that
    succeeded — nothing to undo for the 2 that never moved).
  - All failed: `"Couldn't move 12 messages"`, no Undo, matches today's
    error-snackbar tone for a single failed action.
- **Undo** loops `moveMessage` (or the new batched `moveMessages`) back to
  the original folder for exactly the succeeded subset, reusing the
  existing `canUndo` (uid ≥ 0) guard per message — some messages in a
  batch may be undoable and others not (no UIDPLUS on the move), so undo
  itself is also proceed-and-report, silently skipping non-undoable ones
  rather than surfacing a second layer of partial-failure UI.
- Selection mode exits automatically once the bulk action is dispatched
  (don't wait for it to finish) — same "fire the action, get instant UI
  feedback" feel as the existing single-swipe actions.

## Error Handling

- A destination-folder fetch failure (opening the move sheet) shows the
  sheet with an inline error and a retry, doesn't crash the screen.
- Repository/transport errors during the bulk call are caught per-message
  inside `moveMessages`/`deleteMessages` (never let one message's failure
  abort the loop for the rest) and surfaced via the summary snackbar above.

## Testing Plan

- Widget tests (`folder_view_screen_test.dart` or a new file): long-press
  enters selection mode, tap toggles, X exits, deselecting the last item
  auto-exits, Slidable disabled while selecting, contextual app bar renders
  the right count and actions.
- Repository tests: `moveMessages`/`deleteMessages` — full-batch success,
  partial failure (one message's server call throws), Trash-fallback
  delegation, and that only one transport connection is opened per batch
  (mock/fake transport asserting call count).
- Widget tests for the bulk undo snackbar text (all/partial/none) and that
  Undo only reverts the succeeded subset.

## Open Questions — resolved

- Scope: FolderViewScreen only, not Unified Inbox. *(resolved)*
- Execution model: loop existing per-message logic, batched over one
  connection rather than reconnecting per message. *(resolved)*
- Select All: deferred, not in this iteration. *(resolved)*
- Partial failure: proceed-and-report, not all-or-nothing. *(resolved)*
