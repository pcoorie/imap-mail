# Multi-Select & Bulk Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add long-press multi-select to `FolderViewScreen`'s message list, with a contextual app bar for bulk Trash and bulk move-to-folder, using round Apple Mail/Outlook-style selection checkboxes.

**Architecture:** Selection state (`selecting` + `Set<int> selectedIds`) lives in `_FolderViewScreenState` (not `_MessageListState`) because the contextual app bar it drives is a sibling of the message list in the same `Scaffold`; it's threaded down to `_MessageList` as constructor parameters. Bulk actions call two new `MailRepository` methods (`moveMessages`/`deleteMessages`) that reuse the existing per-message optimistic-local-then-server logic, batched over one new `MailTransport.moveMessages` connection instead of reconnecting per message.

**Tech Stack:** Flutter, Riverpod, `flutter_slidable`, `enough_mail`, `mocktail` for tests.

**Spec:** `docs/superpowers/specs/2026-08-24-multiselect-bulk-actions-design.md`

## Global Constraints

- Scope is `FolderViewScreen` only — no Unified Inbox multi-select.
- No Select All in this iteration.
- No bulk Undo in this iteration — a bulk Trash/move is final; manual recovery via Trash or the destination folder.
- Bulk actions proceed-and-report: one message's failure must not block or revert the rest of the batch.
- Every bulk server call reuses exactly **one** IMAP connection for the whole batch (`MailTransport.moveMessages`), never one connection per message.
- Selection checkbox: round, ~24dp, left of the existing avatar/leading content. Unselected: hollow ring, no fill. Selected: filled with the theme's primary color, white/`onPrimary` checkmark centered. Present only while selection mode is active.

---

### Task 1: `MessageListTile` — selection checkbox and long-press

**Files:**
- Modify: `lib/widgets/message_list_tile.dart`
- Test: `test/widget/message_list_tile_test.dart`

**Interfaces:**
- Produces: `MessageListTile({..., bool? selected, VoidCallback? onLongPress})`. `selected: null` (default) means "not in selection mode" — leading content and tile background render exactly as before. `selected: true/false` means "selection mode is active", rendering a round checkbox (filled+check when `true`, hollow ring when `false`) before the existing leading content, and tinting the tile background when `true`. `onLongPress`, if given, is wired to `ListTile.onLongPress`.

- [ ] **Step 1: Write the failing tests**

Add to `test/widget/message_list_tile_test.dart` (append inside `main()`, after the existing tests):

```dart
  testWidgets('does not show a selection checkbox when selected is null (default browsing)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byKey(const Key('selectionCheckbox')), findsNothing);
  });

  testWidgets('shows an unfilled round checkbox when selected: false', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: false,
        ),
      ),
    ));

    final box = tester.widget<Container>(find.byKey(const Key('selectionCheckbox')));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('shows a filled round checkbox with a checkmark when selected: true', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: true,
        ),
      ),
    ));

    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final box = tester.widget<Container>(find.byKey(const Key('selectionCheckbox')));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, scheme.primary);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tints the row background when selected: true', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: true,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, isNotNull);
  });

  testWidgets('does not tint the row background when selected: false', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: false,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, isNull);
  });

  testWidgets('fires onLongPress when the row is long-pressed', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          onLongPress: () => longPressed = true,
        ),
      ),
    ));

    await tester.longPress(find.byType(ListTile));

    expect(longPressed, isTrue);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/message_list_tile_test.dart`
Expected: FAIL — `selected` and `onLongPress` are not parameters of `MessageListTile` yet (compile error), and `Key('selectionCheckbox')` doesn't exist.

- [ ] **Step 3: Implement**

Replace the whole contents of `lib/widgets/message_list_tile.dart` with:

```dart
import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/mail_message.dart';
import 'message_date_format.dart';
import 'sender_avatar.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({
    super.key,
    required this.message,
    required this.onTap,
    this.accountColor,
    this.selected,
    this.onLongPress,
  });

  final MailMessage message;
  final VoidCallback onTap;

  /// Set by callers showing rows from multiple accounts at once (the
  /// unified inbox) so each row is visually attributable to its account —
  /// rendered as a small badge on the corner of the sender avatar rather
  /// than replacing it, so multi-account clarity survives alongside the new
  /// avatar. Null in the single-account folder view, where every row is
  /// obviously the same account and a badge would just be noise.
  final Color? accountColor;

  /// `null` (the default) means selection mode is not active — the row
  /// renders exactly as it always has, with no checkbox. Once selection
  /// mode is active, callers pass `true`/`false` for every row (whether
  /// this particular message is selected), and a round checkbox appears
  /// before the existing leading content: a hollow ring when `false`, a
  /// filled circle with a checkmark when `true`.
  final bool? selected;

  /// Wired to [ListTile.onLongPress] — the entry point into selection mode.
  final VoidCallback? onLongPress;

  Widget _selectionCheckbox(BuildContext context, bool isSelected) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('selectionCheckbox'),
      width: 24,
      height: 24,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? scheme.primary : Colors.transparent,
        border: isSelected ? null : Border.all(color: scheme.outline, width: 2),
      ),
      child: isSelected ? Icon(Icons.check, size: 16, color: scheme.onPrimary) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final failed = message.sendStatus == MailSendStatus.failed;
    // `message.from` can hold more than one comma-joined address (a message
    // with multiple From addresses) — the avatar only has room for one
    // sender, so use the primary (first), matching fromName's own mapping
    // (see mail_message_mapper.dart).
    final primaryEmail = message.from.split(',').first.trim();
    final avatar = SenderAvatar(name: message.fromName, email: primaryEmail);
    // Prefer the sender's real name (e.g. "Chris Quinones") — falls back to
    // the email address only when the server never sent a display name for
    // it (common for bare automated senders like noreply@example.com).
    final senderDisplay = message.fromName?.trim().isNotEmpty == true
        ? message.fromName!
        : primaryEmail;
    final leadingContent = failed
        ? const Icon(Icons.error_outline, color: Colors.red)
        : accountColor != null
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  key: const Key('accountColorDot'),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: accountColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          )
        : avatar;
    return ListTile(
      tileColor: selected == true
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
          : message.isFlagged
          ? Colors.orange.withValues(alpha: 0.08)
          : null,
      leading: selected == null
          ? leadingContent
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _selectionCheckbox(context, selected!),
                leadingContent,
              ],
            ),
      title: Text(
        message.subject,
        style: TextStyle(
          fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Text(
        failed
            ? '$senderDisplay — Failed to send'
            : '$senderDisplay — ${message.snippet}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.isFlagged)
            const Icon(Icons.flag, size: 16, color: Colors.orange),
          Text(formatMessageDate(message.date)),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/message_list_tile_test.dart`
Expected: PASS (all tests, old and new).

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/message_list_tile.dart test/widget/message_list_tile_test.dart
git commit -m "feat(mail): add a selection checkbox and long-press to MessageListTile

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Batched move/delete — `MailTransport` + `MailRepository`

**Files:**
- Modify: `lib/data/transport/mail_transport.dart`
- Modify: `lib/data/transport/enough_mail_transport.dart`
- Modify: `lib/data/repository/mail_repository.dart`
- Modify: `test/widget/message_detail_screen_test.dart` (hand-written `_FakeMailTransport` must implement the new abstract method or the whole suite fails to compile)
- Test: `test/data/repository/mail_repository_test.dart`

**Interfaces:**
- Produces (on `MailTransport`, implemented by `EnoughMailTransport`): `Future<Map<int, int?>> moveMessages(MailAccount account, String password, MailFolder source, List<MailMessage> messages, MailFolder destination)`. Opens **one** connection for the whole batch. Keyed by each message's **id** (`message.id!`), not the `MailMessage` object (pre-/post-move copies compare unequal under `Equatable`). A message present in the returned map succeeded (value is its new uid, or `null` if the server reported none); a message **absent** from the map failed — the transport swallows that one message's error internally and continues the loop rather than aborting the batch.
- Produces (on `MailRepository`): `class BulkResult { List<MailMessage> succeeded; Map<int, Object> failed; }` and `Future<BulkResult> moveMessages(MailAccount account, MailFolder from, MailFolder to, List<MailMessage> messages)` / `Future<BulkResult> deleteMessages(MailAccount account, MailFolder currentFolder, List<MailMessage> messages)`.
- Consumes: existing `MessageDao.moveToFolder(int messageId, int newFolderId, {int? newUid})`, `MessageDao.deleteMessage(int id)`, `FolderDao.getForAccount(int accountId)`.

- [ ] **Step 1: Write the failing tests**

In `test/data/repository/mail_repository_test.dart`, add to `setUpAll` (after the existing `registerFallbackValue` calls) so `any()` can match a `List<MailMessage>` argument:

```dart
    registerFallbackValue(<MailMessage>[]);
```

Then append these tests inside `main()`, after the existing `deleteMessage`/`archiveMessage` tests:

```dart
  group('moveMessages / deleteMessages (bulk)', () {
    test('moveMessages moves every message locally and on the server, adopting each new uid', () async {
      final inboxFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final archiveFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
      );
      final inboxFolder = (await folderDao.getById(inboxFolderId))!;
      final archiveFolder = (await folderDao.getById(archiveFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: inboxFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
        MailMessage(folderId: inboxFolderId, uid: 2, subject: 'Two', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'two'),
      ]);
      final messages = await messageDao.getForFolder(inboxFolderId);
      when(() => transport.moveMessages(any(), any(), any(), any(), any())).thenAnswer((invocation) async {
        final passed = invocation.positionalArguments[3] as List<MailMessage>;
        return {for (final m in passed) m.id!: m.uid + 100};
      });

      final result = await repository.moveMessages(account.copyWith(id: accountId), inboxFolder, archiveFolder, messages);

      expect(result.succeeded, hasLength(2));
      expect(result.failed, isEmpty);
      final archived = await messageDao.getForFolder(archiveFolderId);
      expect(archived, hasLength(2));
      expect(archived.map((m) => m.uid), containsAll([101, 102]));
      expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
      verify(() => transport.moveMessages(any(), any(), any(), any(), any())).called(1);
    });

    test('moveMessages reverts only the messages the transport reports failed, keeping the rest moved', () async {
      final inboxFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final archiveFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
      );
      final inboxFolder = (await folderDao.getById(inboxFolderId))!;
      final archiveFolder = (await folderDao.getById(archiveFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: inboxFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
        MailMessage(folderId: inboxFolderId, uid: 2, subject: 'Two', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'two'),
      ]);
      final messages = await messageDao.getForFolder(inboxFolderId);
      final succeedingMessage = messages.firstWhere((m) => m.subject == 'One');
      when(() => transport.moveMessages(any(), any(), any(), any(), any()))
          .thenAnswer((_) async => {succeedingMessage.id!: 101});

      final result = await repository.moveMessages(account.copyWith(id: accountId), inboxFolder, archiveFolder, messages);

      expect(result.succeeded, hasLength(1));
      expect(result.failed, hasLength(1));
      final archived = await messageDao.getForFolder(archiveFolderId);
      expect(archived, hasLength(1));
      expect(archived.first.subject, 'One');
      final remainingInInbox = await messageDao.getForFolder(inboxFolderId);
      expect(remainingInInbox, hasLength(1));
      expect(remainingInInbox.first.subject, 'Two');
      expect(remainingInInbox.first.uid, 2, reason: 'the reverted message must keep its original uid');
    });

    test('moveMessages treats a thrown transport error as every message failing, reverting all of them', () async {
      final inboxFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final archiveFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
      );
      final inboxFolder = (await folderDao.getById(inboxFolderId))!;
      final archiveFolder = (await folderDao.getById(archiveFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: inboxFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
      ]);
      final messages = await messageDao.getForFolder(inboxFolderId);
      when(() => transport.moveMessages(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

      final result = await repository.moveMessages(account.copyWith(id: accountId), inboxFolder, archiveFolder, messages);

      expect(result.succeeded, isEmpty);
      expect(result.failed, hasLength(1));
      expect(await messageDao.getForFolder(archiveFolderId), isEmpty);
      final remaining = await messageDao.getForFolder(inboxFolderId);
      expect(remaining, hasLength(1));
      expect(remaining.first.uid, 1);
    });

    test('deleteMessages moves the whole batch to Trash when a Trash folder exists', () async {
      final inboxFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final trashFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
      );
      final inboxFolder = (await folderDao.getById(inboxFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: inboxFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
        MailMessage(folderId: inboxFolderId, uid: 2, subject: 'Two', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'two'),
      ]);
      final messages = await messageDao.getForFolder(inboxFolderId);
      when(() => transport.moveMessages(any(), any(), any(), any(), any())).thenAnswer((invocation) async {
        final passed = invocation.positionalArguments[3] as List<MailMessage>;
        return {for (final m in passed) m.id!: null};
      });

      final result = await repository.deleteMessages(account.copyWith(id: accountId), inboxFolder, messages);

      expect(result.succeeded, hasLength(2));
      expect(await messageDao.getForFolder(trashFolderId), hasLength(2));
      expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
    });

    test('deleteMessages permanently removes every message locally (no server call) when there is no Trash folder', () async {
      final inboxFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final inboxFolder = (await folderDao.getById(inboxFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: inboxFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
        MailMessage(folderId: inboxFolderId, uid: 2, subject: 'Two', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'two'),
      ]);
      final messages = await messageDao.getForFolder(inboxFolderId);

      final result = await repository.deleteMessages(account.copyWith(id: accountId), inboxFolder, messages);

      expect(result.succeeded, hasLength(2));
      expect(result.failed, isEmpty);
      expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
      verifyNever(() => transport.moveMessages(any(), any(), any(), any(), any()));
    });

    test('deleteMessages permanently removes every message locally (no server call) when already in the Trash folder', () async {
      final trashFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
      );
      final trashFolder = (await folderDao.getById(trashFolderId))!;
      await messageDao.upsertHeaders([
        MailMessage(folderId: trashFolderId, uid: 1, subject: 'One', from: 'a@example.com', to: 'me@example.com', date: DateTime.utc(2026, 8, 19), snippet: 'one'),
      ]);
      final messages = await messageDao.getForFolder(trashFolderId);

      final result = await repository.deleteMessages(account.copyWith(id: accountId), trashFolder, messages);

      expect(result.succeeded, hasLength(1));
      expect(await messageDao.getForFolder(trashFolderId), isEmpty);
      verifyNever(() => transport.moveMessages(any(), any(), any(), any(), any()));
    });
  });
```

In `test/widget/message_detail_screen_test.dart`, add this override to `_FakeMailTransport` (right after its existing `moveMessage` override):

```dart
  @override
  Future<Map<int, int?>> moveMessages(
    MailAccount account,
    String password,
    MailFolder source,
    List<MailMessage> messages,
    MailFolder destination,
  ) async =>
      const {};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/data/repository/mail_repository_test.dart test/widget/message_detail_screen_test.dart`
Expected: FAIL to compile — `MailRepository.moveMessages`/`deleteMessages` and `MailTransport.moveMessages` don't exist yet.

- [ ] **Step 3: Implement**

In `lib/data/transport/mail_transport.dart`, add this method to the `MailTransport` abstract class, after `moveMessage`:

```dart
  /// Moves every message in [messages] from [source] to [destination] on
  /// the server, reusing a single connection for the whole batch instead of
  /// reconnecting per message (see the design spec's "Execution model").
  /// Returns each message's new UID in [destination] if the server reports
  /// one, keyed by the message's local database id (`message.id!`) — not by
  /// `MailMessage` itself, since pre- and post-move copies of the same
  /// message compare unequal under its value-equality (`Equatable`). A
  /// message missing from the returned map means that one message's move
  /// failed without aborting the rest of the batch.
  Future<Map<int, int?>> moveMessages(
    MailAccount account,
    String password,
    MailFolder source,
    List<MailMessage> messages,
    MailFolder destination,
  );
```

In `lib/data/transport/enough_mail_transport.dart`, add this method to `EnoughMailTransport`, after the existing `moveMessage`:

```dart
  @override
  Future<Map<int, int?>> moveMessages(
    MailAccount account,
    String password,
    MailFolder source,
    List<MailMessage> messages,
    MailFolder destination,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    final results = <int, int?>{};
    try {
      await client.connect();
      final mailboxes = await client.listMailboxes();
      final targetMailbox = mailboxes.firstWhereOrNull((box) => box.path == destination.path);
      if (targetMailbox == null) {
        throw StateError('Destination folder ${destination.path} not found on server');
      }
      await client.selectMailboxByPath(source.path);
      for (final message in messages) {
        try {
          final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
          final result = await client.moveMessages(sequence, targetMailbox);
          results[message.id!] = result.targetSequence?.toList().firstOrNull;
        } catch (_) {
          // One message's move failing must not abort the rest of the
          // batch — leaving it out of `results` is how the repository layer
          // tells it apart from a successful move with no reported uid.
        }
      }
      return results;
    } finally {
      await client.disconnect();
    }
  }
```

In `lib/data/repository/mail_repository.dart`, add this class above `class MailRepository`:

```dart
/// The outcome of a bulk [MailRepository.moveMessages]/[MailRepository.deleteMessages]
/// call: proceed-and-report, not all-or-nothing — some messages in a batch
/// can succeed while others fail. [failed] is keyed by message id.
class BulkResult {
  const BulkResult({required this.succeeded, required this.failed});

  final List<MailMessage> succeeded;
  final Map<int, Object> failed;
}
```

Then add these two methods to `MailRepository`, after `deleteMessage`:

```dart
  /// Bulk version of [moveMessage]: moves every message in [messages] from
  /// [from] to [to], batched over a single [MailTransport] connection
  /// (`_transport.moveMessages`) rather than one connection per message.
  /// Proceed-and-report: one message's server-side failure reverts only
  /// that message, not the rest of the batch (see [BulkResult]).
  Future<BulkResult> moveMessages(
    MailAccount account,
    MailFolder from,
    MailFolder to,
    List<MailMessage> messages,
  ) async {
    for (final message in messages) {
      await _messageDao.moveToFolder(message.id!, to.id!);
    }
    await _refreshUnreadCount(from.id!);
    await _refreshUnreadCount(to.id!);

    Map<int, int?> newUids;
    try {
      final password = await _passwordFor(account);
      newUids = await _transport.moveMessages(account, password, from, messages, to);
    } catch (_) {
      // The whole batch's connection/setup failed before any per-message
      // result could be determined (offline, destination not found, etc.)
      // — treat every message in the batch as failed.
      newUids = const {};
    }

    final succeeded = <MailMessage>[];
    final failed = <int, Object>{};
    for (final message in messages) {
      final id = message.id!;
      if (newUids.containsKey(id)) {
        final newUid = newUids[id];
        if (newUid != null) {
          await _messageDao.moveToFolder(id, to.id!, newUid: newUid);
        }
        succeeded.add(message.copyWith(folderId: to.id!, uid: newUid ?? message.uid));
      } else {
        failed[id] = StateError('Failed to move message $id to ${to.name}');
        // Restore the ORIGINAL uid, exactly like moveMessage's single-message
        // revert — never let MessageDao.moveToFolder synthesize a fresh
        // placeholder and destroy the message's real server uid.
        await _messageDao.moveToFolder(id, from.id!, newUid: message.uid);
      }
    }
    await _refreshUnreadCount(from.id!);
    await _refreshUnreadCount(to.id!);
    return BulkResult(succeeded: succeeded, failed: failed);
  }

  /// Bulk version of [deleteMessage]: moves every message in [messages] to
  /// Trash via [moveMessages], or permanently removes them all locally when
  /// there's no Trash folder to move them to, or when [currentFolder] is
  /// already Trash — same fallback rules as [deleteMessage], applied once
  /// for the whole batch (they depend only on the account/folder, not on
  /// which messages are selected).
  Future<BulkResult> deleteMessages(
    MailAccount account,
    MailFolder currentFolder,
    List<MailMessage> messages,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final trashFolder = folders.where((f) => f.type == MailFolderType.trash).firstOrNull;
    if (trashFolder != null && trashFolder.id != currentFolder.id) {
      return moveMessages(account, currentFolder, trashFolder, messages);
    }
    for (final message in messages) {
      await _messageDao.deleteMessage(message.id!);
    }
    await _refreshUnreadCount(currentFolder.id!);
    return BulkResult(succeeded: messages, failed: const {});
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/data/repository/mail_repository_test.dart test/widget/message_detail_screen_test.dart`
Expected: PASS (all tests, old and new).

Also run: `flutter analyze` — confirms every other `implements MailTransport`/`Mock implements MailTransport` in the test suite still compiles (the `Mock`-based ones in `test/providers/*.dart` and `test/data/repository/account_repository_test.dart` auto-implement the new method; only the hand-written `_FakeMailTransport` needed a manual override).

- [ ] **Step 5: Commit**

```bash
git add lib/data/transport/mail_transport.dart lib/data/transport/enough_mail_transport.dart lib/data/repository/mail_repository.dart test/data/repository/mail_repository_test.dart test/widget/message_detail_screen_test.dart
git commit -m "feat(mail): add batched moveMessages/deleteMessages to MailRepository

One IMAP connection per bulk action instead of one per message.
Proceed-and-report: a single message's failure reverts only that
message, not the whole batch.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: `FolderViewScreen` — selection mode and bulk Trash

**Files:**
- Modify: `lib/screens/folder_view_screen.dart`
- Test: `test/widget/folder_view_screen_test.dart`

**Interfaces:**
- Consumes: `MessageListTile({..., bool? selected, VoidCallback? onLongPress})` (Task 1), `MailRepository.deleteMessages(MailAccount, MailFolder, List<MailMessage>)` returning `BulkResult` (Task 2).
- Produces: `_FolderViewScreenState` gains `_selecting`, `_selectedIds`, `_enterSelection(int)`, `_toggleSelection(int)`, `_exitSelection()`, `_bulkDelete(MailFolder)`, `_showBulkResultSnackBar(BulkResult, {required String verb})`, and a `_currentFolder(List<MailFolder>?)` helper. `_MessageList` gains constructor fields `selecting`, `selectedIds`, `onEnterSelection`, `onToggleSelection` consumed by later tasks' widgets too.

- [ ] **Step 1: Write the failing tests**

Add this import to `test/widget/folder_view_screen_test.dart` (it isn't there yet):

```dart
import 'package:imap_mail/screens/message_detail_screen.dart';
```

Add `registerFallbackValue(<MailMessage>[]);` to the file's `setUpAll` (needed once `repository.deleteMessages(any(), any(), any())` is mocked below).

Append these tests inside `main()`, after the existing tests:

```dart
  group('multi-select and bulk Trash', () {
    testWidgets('long-pressing a row enters selection mode with a contextual app bar', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('tapping another row while selecting adds it and updates the count instead of opening it',
        (tester) async {
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(MessageDetailScreen), findsNothing);
    });

    testWidgets('tapping the X exits selection mode and restores the normal app bar', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('deselecting the last selected row automatically exits selection mode', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hello'));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
    });

    testWidgets('swipe actions are disabled while selecting (a drag does not trigger the swipe delete)',
        (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessage(any(), any(), any()))
          .thenAnswer((_) async => message.copyWith(folderId: trash.id!));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      expect(find.byType(Slidable), findsNothing);

      await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      verifyNever(() => repository.deleteMessage(any(), any(), any()));
    });

    testWidgets('tapping Delete bulk-deletes every selected message and exits selection mode', (tester) async {
      final repository = MockMailRepository();
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => const BulkResult(succeeded: [], failed: {}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      verify(() => repository.deleteMessages(account, inbox, [message, second])).called(1);
      expect(find.text('Mail'), findsOneWidget);
    });

    testWidgets('the bulk delete summary snackbar never offers an Undo action', (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: [message], failed: const {}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining('moved to Trash'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('switching folder tabs while selecting exits selection mode and restores the normal app bar',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('a bulk delete where every message failed reports it without an Undo action', (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: const [], failed: {100: Exception('offline')}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't move 1 message"), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('a partial bulk-delete failure reports both counts in the summary snackbar', (tester) async {
      final repository = MockMailRepository();
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: [message], failed: {101: Exception('offline')}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 moved, 1 failed'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/folder_view_screen_test.dart`
Expected: FAIL — `_MessageList`/`MessageListTile` don't yet accept selection, no `Icons.close`/`Icons.delete_outline` app bar, `MailRepository.deleteMessages` mock has no caller.

- [ ] **Step 3: Implement**

In `lib/screens/folder_view_screen.dart`, apply these changes to `_FolderViewScreenState`:

1. Add imports at the top of the file: `import '../data/repository/mail_repository.dart';` (for `BulkResult`).

2. Replace the folder-derivation logic and the whole `build()` method of `_FolderViewScreenState` with:

```dart
class _FolderViewScreenState extends ConsumerState<FolderViewScreen> {
  MailFolder? _selected;
  bool _selecting = false;
  final Set<int> _selectedIds = {};

  MailFolder? _currentFolder(List<MailFolder>? folders) {
    if (folders == null) return null;
    final defaults = <MailFolder>[
      for (final type in [
        MailFolderType.inbox,
        MailFolderType.sent,
        MailFolderType.trash,
      ])
        ...folders.where((f) => f.type == type),
    ];
    return _selected ??
        (defaults.isNotEmpty ? defaults.first : (folders.isNotEmpty ? folders.first : null));
  }

  void _enterSelection(int id) => setState(() {
        _selecting = true;
        _selectedIds.add(id);
      });

  void _toggleSelection(int id) => setState(() {
        if (!_selectedIds.remove(id)) {
          _selectedIds.add(id);
        }
        if (_selectedIds.isEmpty) {
          _selecting = false;
        }
      });

  void _exitSelection() => setState(() {
        _selecting = false;
        _selectedIds.clear();
      });

  void _showBulkResultSnackBar(BulkResult result, {required String verb}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final succeededCount = result.succeeded.length;
    final failedCount = result.failed.length;
    final String text;
    if (failedCount == 0) {
      text = '$succeededCount $verb';
    } else if (succeededCount == 0) {
      text = "Couldn't move $failedCount message${failedCount == 1 ? '' : 's'}";
    } else {
      text = '$succeededCount moved, $failedCount failed';
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _bulkDelete(MailFolder folder) async {
    final messages = ref.read(messagesProvider(folder)).valueOrNull ?? const <MailMessage>[];
    final selected = messages.where((m) => _selectedIds.contains(m.id)).toList();
    _exitSelection();
    if (selected.isEmpty) return;
    final account = _findAccount();
    if (account == null) return;
    final repository = await ref.read(mailRepositoryProvider.future);
    final result = await repository.deleteMessages(account, folder, selected);
    if (!mounted) return;
    ref.invalidate(messagesProvider(folder));
    ref.read(unreadCountRefreshTickProvider.notifier).state++;
    _showBulkResultSnackBar(result, verb: 'moved to Trash');
  }

  PreferredSizeWidget _buildDefaultAppBar() {
    return AppBar(
      title: const Text('Mail'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
        ),
        // Single-account routing (app.dart) skips AccountListScreen
        // entirely — its gear icon was the only path to SettingsScreen,
        // so a single-account user would otherwise have no way to reach
        // theme/swipe-action settings at all.
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(MailFolder current) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _bulkDelete(current),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider(widget.accountId));
    final syncError = ref.watch(syncErrorProvider(widget.accountId));
    final current = _currentFolder(foldersAsync.valueOrNull);

    return Scaffold(
      appBar: _selecting && current != null
          ? _buildSelectionAppBar(current)
          : _buildDefaultAppBar(),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ComposeScreen(accountId: widget.accountId),
                ),
              ),
              child: const Icon(Icons.edit),
            ),
      body: foldersAsync.when(
        data: (folders) {
          final defaults = <MailFolder>[
            for (final type in [
              MailFolderType.inbox,
              MailFolderType.sent,
              MailFolderType.trash,
            ])
              ...folders.where((f) => f.type == type),
          ];
          final rest = folders.where((f) => !defaults.contains(f)).toList();
          final current = _currentFolder(folders);

          return Column(
            children: [
              // Informational-only: a sync failure once cached data already
              // exists must not blank the screen (unlike the full-screen
              // `error` branch below, which only fires when there is no
              // cache at all). Dismissible so it doesn't nag forever.
              if (syncError != null)
                MaterialBanner(
                  content: Text('Showing saved data — sync failed: $syncError'),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          ref.invalidate(foldersProvider(widget.accountId)),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref
                                  .read(
                                    syncErrorProvider(
                                      widget.accountId,
                                    ).notifier,
                                  )
                                  .state =
                              null,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FolderTabBar(
                  folders: defaults,
                  selected: current,
                  onSelect: (folder) => setState(() {
                    _selected = folder;
                    _selecting = false;
                    _selectedIds.clear();
                  }),
                ),
              ),
              // Bounded + scrollable: FolderTreeExpander's expanded list is a
              // plain (unscrollable) Column, so with many "other" folders it
              // can be taller than the screen. Without this cap, that would
              // overflow the outer Column and starve the message list
              // (Expanded below) of space. ConstrainedBox+SingleChildScrollView
              // shrink-wraps up to maxHeight — short lists (the common case)
              // still take only their natural height, no wasted space.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: FolderTreeExpander(
                    folders: rest,
                    onSelect: (folder) => setState(() {
                      _selected = folder;
                      _selecting = false;
                      _selectedIds.clear();
                    }),
                  ),
                ),
              ),
              const Divider(height: 1),
              if (current != null)
                Expanded(
                  child: _MessageList(
                    folder: current,
                    selecting: _selecting,
                    selectedIds: _selectedIds,
                    onEnterSelection: _enterSelection,
                    onToggleSelection: _toggleSelection,
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SyncErrorBanner(
          message: error.toString(),
          onRetry: () => ref.invalidate(foldersProvider(widget.accountId)),
          onEditAccount: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AccountFormScreen(existing: _findAccount()),
            ),
          ),
        ),
      ),
    );
  }

  MailAccount? _findAccount() {
    final accounts = ref.read(accountsProvider).valueOrNull;
    if (accounts == null) return null;
    for (final account in accounts) {
      if (account.id == widget.accountId) return account;
    }
    return null;
  }
}
```

3. Update `_MessageList` to accept and thread through the new selection fields — replace its class declaration with:

```dart
class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({
    required this.folder,
    required this.selecting,
    required this.selectedIds,
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  final MailFolder folder;
  final bool selecting;
  final Set<int> selectedIds;
  final ValueChanged<int> onEnterSelection;
  final ValueChanged<int> onToggleSelection;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}
```

4. In `_MessageListState.build()`, replace the `itemBuilder` (inside `ListView.separated`) with:

```dart
                  itemBuilder: (context, index) {
                    final message = visible[index];
                    // firstWhereOrNull, not firstWhere: the account can vanish out
                    // from under an still-mounted FolderViewScreen (e.g. removed
                    // in another screen while this one stays alive) — falling back
                    // to the same loading state used above rather than crashing
                    // with an unguarded StateError, exactly like the pre-Task-5
                    // inline version handled this same lookup failing inside
                    // _performSwipeAction's try block.
                    final account = accounts!.firstWhereOrNull(
                      (a) => a.id == folder.accountId,
                    );
                    if (account == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final tile = MessageListTile(
                      key: ValueKey(message.id),
                      message: message,
                      selected: widget.selecting ? widget.selectedIds.contains(message.id) : null,
                      onLongPress: () => widget.onEnterSelection(message.id!),
                      onTap: widget.selecting
                          ? () => widget.onToggleSelection(message.id!)
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MessageDetailScreen(
                                    folder: folder,
                                    message: message,
                                  ),
                                ),
                              ),
                    );
                    if (widget.selecting) {
                      return tile;
                    }
                    return Slidable(
                      key: ValueKey(message.id),
                      startActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.leftPrimary,
                        secondary: swipeConfig.leftSecondary,
                        account: account,
                        folder: folder,
                        message: message,
                        onRemoved: (id) =>
                            setState(() => _pendingRemoval.add(id)),
                      ),
                      endActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.rightPrimary,
                        secondary: swipeConfig.rightSecondary,
                        account: account,
                        folder: folder,
                        message: message,
                        onRemoved: (id) =>
                            setState(() => _pendingRemoval.add(id)),
                      ),
                      child: tile,
                    );
                  },
```

Also, in the same `build()` method, add a line pruning `_selectedIds` alongside the existing `_pendingRemoval.retainAll(...)` line:

```dart
        _pendingRemoval.retainAll(messages.map((m) => m.id).whereType<int>());
        // `widget.selectedIds` is the SAME Set instance _FolderViewScreenState
        // owns (passed down, not copied) — mutating it here drops a
        // since-vanished message from the selection immediately, per the
        // design spec. This doesn't itself call the parent's setState, so
        // the app bar's "N selected" count can lag by one frame until the
        // next selection change triggers a rebuild — acceptable for this
        // rare edge case (a sync/refresh removing a selected message).
        widget.selectedIds.retainAll(messages.map((m) => m.id).whereType<int>());
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/folder_view_screen_test.dart`
Expected: PASS (all tests, old and new).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/folder_view_screen.dart test/widget/folder_view_screen_test.dart
git commit -m "feat(mail): long-press multi-select and bulk Trash in FolderViewScreen

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Bulk move-to-folder

**Files:**
- Create: `lib/widgets/folder_picker_sheet.dart`
- Test: `test/widget/folder_picker_sheet_test.dart`
- Modify: `lib/screens/folder_view_screen.dart`
- Modify: `test/widget/folder_view_screen_test.dart`

**Interfaces:**
- Produces: `Future<MailFolder?> showFolderPicker(BuildContext context, List<MailFolder> folders)` — resolves with the tapped folder, or `null` if dismissed without a choice. Mirrors `showComposeAccountPicker`'s shape.
- Consumes: `MailRepository.moveMessages(MailAccount, MailFolder, MailFolder, List<MailMessage>)` returning `BulkResult` (Task 2); `_FolderViewScreenState`'s selection state (Task 3).

- [ ] **Step 1: Write the failing tests**

Create `test/widget/folder_picker_sheet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/widgets/folder_picker_sheet.dart';

void main() {
  final archive = MailFolder(id: 1, accountId: 1, name: 'Archive', path: 'Archive', type: MailFolderType.archive);
  final work = MailFolder(id: 2, accountId: 1, name: 'Work', path: 'Work', type: MailFolderType.other);

  testWidgets('lists every folder and resolves with the tapped one', (tester) async {
    MailFolder? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showFolderPicker(context, [archive, work]);
          },
          child: const Text('Open'),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(result, work);
  });

  testWidgets('resolves with null when dismissed without a choice', (tester) async {
    MailFolder? result = archive; // sentinel — overwritten only if the sheet resolves
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showFolderPicker(context, [archive]);
          },
          child: const Text('Open'),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
```

Append these tests to `test/widget/folder_view_screen_test.dart` inside the `'multi-select and bulk Trash'` group (rename the group to `'multi-select and bulk actions'` since it now covers move too):

```dart
    testWidgets(
        'tapping Move to folder opens the folder picker and bulk-moves selected messages to the chosen folder',
        (tester) async {
      final repository = MockMailRepository();
      when(() => repository.moveMessages(any(), any(), any(), any())).thenAnswer(
        (_) async => BulkResult(succeeded: [message.copyWith(folderId: trash.id!)], failed: const {}),
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Trash'), findsOneWidget);
      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      verify(() => repository.moveMessages(account, inbox, trash, [message])).called(1);
      expect(find.textContaining('moved to Trash'), findsOneWidget);
    });

    testWidgets('the folder picker excludes the folder currently being viewed', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pumpAndSettle();

      // "Inbox" (the folder being viewed) also appears as a background tab —
      // scope the check to the picker's own bottom sheet.
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Inbox')), findsNothing);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Sent')), findsOneWidget);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Trash')), findsOneWidget);
    });

    testWidgets('dismissing the folder picker without choosing a folder leaves the selection untouched',
        (tester) async {
      final repository = MockMailRepository();

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      verifyNever(() => repository.moveMessages(any(), any(), any(), any()));
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/folder_picker_sheet_test.dart test/widget/folder_view_screen_test.dart`
Expected: FAIL — `showFolderPicker` doesn't exist, and the selection app bar has no `Icons.folder_outlined` action yet.

- [ ] **Step 3: Implement**

Create `lib/widgets/folder_picker_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

/// A bottom sheet listing [folders] as move-to-folder destinations; resolves
/// with the tapped folder, or null if dismissed without a choice. Mirrors
/// `showComposeAccountPicker`'s shape.
Future<MailFolder?> showFolderPicker(BuildContext context, List<MailFolder> folders) {
  return showModalBottomSheet<MailFolder>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Move to', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final folder in folders)
            ListTile(
              title: Text(folder.name),
              onTap: () => Navigator.of(context).pop(folder),
            ),
        ],
      ),
    ),
  );
}
```

In `lib/screens/folder_view_screen.dart`:

1. Add the import: `import '../widgets/folder_picker_sheet.dart';`

2. Add this method to `_FolderViewScreenState`, alongside `_bulkDelete`:

```dart
  Future<void> _bulkMove(MailFolder folder, List<MailFolder> allFolders) async {
    final destination = await showFolderPicker(
      context,
      allFolders.where((f) => f.id != folder.id).toList(),
    );
    if (destination == null) return;
    final messages = ref.read(messagesProvider(folder)).valueOrNull ?? const <MailMessage>[];
    final selected = messages.where((m) => _selectedIds.contains(m.id)).toList();
    _exitSelection();
    if (selected.isEmpty) return;
    final account = _findAccount();
    if (account == null) return;
    final repository = await ref.read(mailRepositoryProvider.future);
    final result = await repository.moveMessages(account, folder, destination, selected);
    if (!mounted) return;
    ref.invalidate(messagesProvider(folder));
    ref.read(unreadCountRefreshTickProvider.notifier).state++;
    _showBulkResultSnackBar(result, verb: 'moved to ${destination.name}');
  }
```

3. Change `_buildSelectionAppBar`'s signature and body to add the Move action, and update its call site:

```dart
  PreferredSizeWidget _buildSelectionAppBar(MailFolder current, List<MailFolder> allFolders) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          icon: const Icon(Icons.folder_outlined),
          tooltip: 'Move to folder',
          onPressed: () => _bulkMove(current, allFolders),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _bulkDelete(current),
        ),
      ],
    );
  }
```

And in `build()`, update the call site:

```dart
      appBar: _selecting && current != null
          ? _buildSelectionAppBar(current, foldersAsync.valueOrNull ?? const [])
          : _buildDefaultAppBar(),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/folder_picker_sheet_test.dart test/widget/folder_view_screen_test.dart`
Expected: PASS (all tests, old and new).

Then run the full suite once to confirm nothing else regressed: `flutter test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/folder_picker_sheet.dart lib/screens/folder_view_screen.dart test/widget/folder_picker_sheet_test.dart test/widget/folder_view_screen_test.dart
git commit -m "feat(mail): bulk move-to-folder for multi-selected messages

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: README — document multi-select bulk actions

**Files:**
- Modify: `README.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Update the feature list**

In `README.md`, under the `### Mail, done properly` section, add a new bullet immediately after the existing `**Swipeable triage actions**` bullet:

```markdown
- **Swipeable triage actions** — swipe a message to archive, delete, flag, or mark read/unread. Every slot is customizable in Settings, and every action writes back to the server, not just the local cache.
- **Multi-select bulk actions** — long-press a message to start selecting, tap more to add to the selection, then move the whole batch to Trash or any other folder in one go.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: mention multi-select bulk actions in the feature list

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```
