# Swipe Gestures (Delete / Archive / Flag / Mark Read-Unread) — Design Spec

Date: 2026-08-20
Status: Approved

## 1. Purpose

Add swipeable triage actions to the message list — delete, archive, flag/unflag, and mark read/unread — with the action-to-swipe-slot mapping fully customizable in Settings. These sync to the IMAP server, not just the local cache.

## 2. Goals / Non-goals

**Goals**
- Swipe left or right on a message row reveals up to 2 tappable action buttons per side; swiping all the way through auto-triggers the primary (first) action for that side.
- 4 available actions: Archive, Delete, Flag/Unflag, Mark read/unread (label and icon reflect current state — "Mark unread" on a read message, "Mark read" on an unread one).
- Fully assignable in Settings: 4 slots (left-primary, left-secondary, right-primary, right-secondary), each choosing from the 4 actions or "None". Defaults: Left = Archive, Flag. Right = Delete, Mark unread.
- Actions sync to the IMAP server (not just local cache) — reflected when checking mail from another client.
- Snappy UX: local DB updates instantly (optimistic), IMAP call happens in the background.

**Non-goals**
- No persistent offline queue/outbox for these actions (that exists today only for failed sends). If the IMAP call fails, revert the optimistic local change and surface a retry affordance — no durable retry-on-reconnect.
- No new swipe directions beyond left/right (no vertical swipe).
- Bulk/multi-select actions are a separate spec — this one is single-row swipe only.

## 3. Current-state gap this closes

Today, `MailRepository.deleteMessage()` and `.markAsRead()` only mutate the local SQLite cache (`MessageDao`) — nothing is written back to the IMAP server. This works today only because `syncHeaders()` never re-fetches UIDs below the folder's high-water mark, so a locally-deleted message doesn't reappear — but the server-side mailbox is never actually updated. This spec introduces real IMAP write-back and generalizes it to all 4 actions.

## 4. Approach

### Data model changes

- `MailFolderType` gains `archive`. `EnoughMailTransport._folderTypeFor()` checks `box.isArchive` (from `enough_mail`'s IMAP special-use flag support) alongside the existing `isInbox`/`isSent`/`isTrash` checks.
- `MailMessage` gains `isFlagged` (`bool`, default `false`). New SQLite column, added via a schema migration in `app_database.dart` following the existing migration pattern there.

### Transport layer

`MailTransport` (interface) and `EnoughMailTransport` (impl) gain three UID-level methods — none require fetching the full message body:

```dart
Future<void> setSeen(MailAccount account, String password, MailFolder folder, MailMessage message, bool value);
Future<void> setFlagged(MailAccount account, String password, MailFolder folder, MailMessage message, bool value);
Future<void> moveMessage(MailAccount account, String password, MailFolder source, MailMessage message, MailFolder destination);
```

`setSeen`/`setFlagged` use `enough_mail`'s `MailClient.store(MessageSequence.fromUid(...), [...], action: add|remove)` against `\Seen`/`\Flagged`. `moveMessage` takes the actual destination `MailFolder` (not just a `MailFolderType`) so it can address any folder, including one that isn't uniquely typed (e.g. a custom "other" folder being restored to via Undo) — it selects the source mailbox and calls `MailClient.moveMessages(..., target: <destination's mailbox>)`. Callers resolve *which* `MailFolder` to pass: `archiveMessage()`/`deleteMessage()` look up the account's archive/trash folder by `MailFolderType` from the already-cached folder list; Undo passes the message's recorded originating `MailFolder` straight through.

### Repository layer

`MailRepository` gains `markRead(bool)`, `markFlagged(bool)`, and `archiveMessage()`, alongside the existing `deleteMessage()` (which is updated to resolve the account's trash folder and call the new `moveMessage()` transport method instead of only touching the DAO). All four follow the same pattern:

1. Update the local `MessageDao` row immediately (instant UI feedback).
2. Fire the corresponding transport call.
3. On failure: revert the local DAO change to its prior value, then rethrow.

Callers (the swipe UI) catch the rethrown error and show a snackbar: `"Couldn't archive — <error>"` with a **Retry** button that re-invokes the same repository call.

### Swipe UI

Add the `flutter_slidable` package. In `FolderViewScreen`'s `_MessageList`, each `MessageListTile` is wrapped in a `Slidable` with a `startActionPane` and `endActionPane`, each built from the user's configured slot assignment (see Settings below) — up to 2 `SlidableAction`s per side, `motion: DrawerMotion` (or similar `flutter_slidable` built-in), full swipe-through auto-dismissing and firing the primary action for that side via `Slidable`'s own dismissible behavior. A partial swipe stops and shows the button row for an explicit tap.

Delete/archive additionally show a brief `SnackBar` with an "Undo" action after firing — since the operation is already optimistic-and-fired, Undo moves the message back to whichever folder it was actually in before the swipe (not hardcoded to Inbox — archiving/deleting from a non-Inbox folder must undo back to that same folder), rather than delaying the original action. `archiveMessage()`/`deleteMessage()` record the message's originating `MailFolder` before moving it, so the snackbar's Undo callback can pass it straight back into `moveMessage()` as the destination.

### Settings — swipe customization

New section in `SettingsScreen`: 4 dropdowns (Left primary / Left secondary / Right primary / Right secondary), each a choice of {Archive, Delete, Flag/Unflag, Mark read/unread, None}. Persisted via the same `shared_preferences` dependency introduced in the dark-theme spec (keys e.g. `"swipe_left_primary"`, etc., storing the action's enum name). A `SwipeActionConfig` (Riverpod `Notifier`) loads/persists these and exposes the resolved action list per side for the UI to consume.

## 5. Testing

- Repository tests (mocked `MailTransport`): each of the 4 actions does optimistic-update-then-commit on success, and optimistic-update-then-revert on transport failure.
- DAO test: new `isFlagged` column read/write and migration from the prior schema version.
- Widget test: with a given `SwipeActionConfig`, a full swipe on either side invokes the correct repository method; tapping a partial-swipe button invokes the correct one too.
- Widget test: `SettingsScreen` dropdown changes persist and are reflected in a freshly-built `Slidable`'s action set.

## 6. Verification

- Manual: swipe each direction on a real/test IMAP account, confirm the mailbox state changes are visible when checking the same account in another mail client (e.g. webmail).
- Manual: disable network, swipe, confirm the row reverts and the retry snackbar appears; retry succeeds once network is restored.
- Run `flutter test`.
