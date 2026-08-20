# Swipe Gestures (Delete / Archive / Flag / Mark Read-Unread) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add customizable swipe-to-reveal triage actions (Archive, Delete, Flag/Unflag, Mark read/unread) to the message list, syncing to the IMAP server with optimistic local updates and revert-on-failure.

**Architecture:** Three layers change together. (1) Transport (`MailTransport`/`EnoughMailTransport`) gains UID-level `setSeen`/`setFlagged`/`moveMessage` calls. (2) `MailRepository` gains a single `moveMessage()` primitive (optimistic DAO write, transport call, revert-on-failure, reconciles the locally-guessed UID with the server's real post-move UID) that `archiveMessage()`/`deleteMessage()` both build on, plus `markRead()`/`markFlagged()` following the same optimistic pattern. (3) UI: a `flutter_slidable`-wrapped `MessageListTile` in `FolderViewScreen`, driven by a `SwipeActionConfig` (Riverpod, `shared_preferences`-backed — same dependency the dark-theme plan already added) that Settings lets the user edit.

**Tech Stack:** Flutter, `flutter_riverpod`, `enough_mail` (existing dependency — `MailClient.store`/`moveMessages`), new `flutter_slidable` dependency, `shared_preferences` (added by the dark-theme plan — this plan assumes that plan has already landed), `sqflite` migration, `flutter_test` + `mocktail` (existing test stack).

## Global Constraints

- **This plan assumes the dark-theme plan (`docs/superpowers/plans/2026-08-20-dark-theme.md`) has already been implemented** — it adds the `shared_preferences` dependency this plan's `SwipeActionConfigNotifier` reuses. If it hasn't landed yet, do Task 1 of that plan (`flutter pub add shared_preferences`) first.
- Default slot assignment: Left primary = Archive, Left secondary = Flag. Right primary = Delete, Right secondary = Mark read/unread.
- Persisted preference keys: `"swipe_left_primary"`, `"swipe_left_secondary"`, `"swipe_right_primary"`, `"swipe_right_secondary"` — string values are the `SwipeAction` enum's `.name`.
- No persistent offline queue for these actions — optimistic local write, then a transport call; on failure, revert the local write and rethrow so the UI can show a Retry snackbar. This mirrors the existing `messagesProvider`/`deleteMessage` pattern of `ref.invalidate(messagesProvider(folder))` after a mutation (see `message_detail_screen.dart`'s `_confirmDelete`).
- No new IMAP "permanent delete" (STORE `\Deleted` + EXPUNGE) — `deleteMessage`'s no-Trash-folder and already-in-Trash branches stay local-only, exactly as today.
- Follow existing patterns: DAO methods on `*Dao` classes, repository methods take `MailAccount` + `MailFolder` + `MailMessage` where server calls are needed, transport methods are UID-level and open/close their own `enough.MailClient` connection per call (matches every existing `EnoughMailTransport` method).

---

### Task 1: Data model & DB migration — `isFlagged`, `MailFolderType.archive`

**Files:**
- Modify: `lib/models/enums.dart`
- Modify: `lib/models/mail_message.dart`
- Modify: `lib/data/local/app_database.dart`
- Modify: `lib/data/local/message_dao.dart`
- Modify: `lib/data/transport/mail_message_mapper.dart`
- Test: `test/models/models_test.dart`
- Test: `test/data/local/app_database_test.dart` (new file)
- Test: `test/data/local/folder_message_dao_test.dart`
- Test: `test/data/transport/mail_message_mapper_test.dart`

**Interfaces:**
- Produces: `MailFolderType.archive`; `MailMessage.isFlagged` (bool, default `false`, part of `copyWith`/`toMap`/`fromMap`/`props`); `MessageDao.updateFlagStatus(int id, bool isFlagged)`; `MessageDao.moveToFolder(int messageId, int newFolderId, {int? newUid})` (widened — `newUid` optional, defaults to today's synthetic-negative-UID placeholder logic when omitted); `AppDatabase.onUpgrade(Database, int, int)`; `AppDatabase.open()` now opens at schema version 2.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/models_test.dart`'s `group('MailMessage', ...)` (after the existing `'round-trips through toMap/fromMap including date and flags'` test, inside the same group):

```dart
    test('round-trips isFlagged through toMap/fromMap', () {
      final message = MailMessage(
        id: 11,
        folderId: 5,
        uid: 43,
        subject: 'Flagged',
        from: 'a@example.com',
        to: 'b@example.com',
        date: DateTime.utc(2026, 8, 19, 12, 0),
        snippet: 'Hi there',
        isFlagged: true,
      );
      final restored = MailMessage.fromMap(message.toMap());
      expect(restored.isFlagged, isTrue);
      expect(restored, message);
    });

    test('isFlagged defaults to false', () {
      final message = MailMessage(
        folderId: 5,
        uid: 44,
        subject: 'Unflagged',
        from: 'a@example.com',
        to: 'b@example.com',
        date: DateTime.utc(2026, 8, 19, 12, 0),
        snippet: 'Hi there',
      );
      expect(message.isFlagged, isFalse);
    });
```

Create `test/data/local/app_database_test.dart`:

```dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/local/app_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('onUpgrade from version 1 adds is_flagged without losing existing data', () async {
    final dir = await Directory.systemTemp.createTemp('imap_mail_migration_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // Simulate a pre-migration (version 1) database using the schema
    // AppDatabase.onCreate produced before is_flagged existed.
    final oldDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE folders (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              account_id INTEGER NOT NULL,
              name TEXT NOT NULL,
              path TEXT NOT NULL,
              type TEXT NOT NULL,
              unread_count INTEGER NOT NULL DEFAULT 0,
              is_local_only INTEGER NOT NULL DEFAULT 0,
              last_synced_uid INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              folder_id INTEGER NOT NULL,
              uid INTEGER NOT NULL,
              subject TEXT NOT NULL,
              from_address TEXT NOT NULL,
              to_address TEXT NOT NULL,
              date INTEGER NOT NULL,
              snippet TEXT NOT NULL,
              body_text TEXT,
              body_html TEXT,
              is_read INTEGER NOT NULL DEFAULT 0,
              is_downloaded INTEGER NOT NULL DEFAULT 0,
              send_status TEXT NOT NULL DEFAULT 'none'
            )
          ''');
        },
      ),
    );
    final folderId = await oldDb.insert('folders', {
      'account_id': 1,
      'name': 'INBOX',
      'path': 'INBOX',
      'type': 'inbox',
    });
    final messageId = await oldDb.insert('messages', {
      'folder_id': folderId,
      'uid': 1,
      'subject': 'Pre-migration message',
      'from_address': 'a@example.com',
      'to_address': 'me@example.com',
      'date': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'snippet': 'snippet',
    });
    await oldDb.close();

    final upgradedDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: AppDatabase.onCreate,
        onUpgrade: AppDatabase.onUpgrade,
      ),
    );
    addTearDown(upgradedDb.close);

    final rows = await upgradedDb.query('messages', where: 'id = ?', whereArgs: [messageId]);
    expect(rows, hasLength(1));
    expect(rows.first['is_flagged'], 0);
    expect(rows.first['subject'], 'Pre-migration message');
  });

  test('a fresh (onCreate) database already has the is_flagged column', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 2, onCreate: AppDatabase.onCreate),
    );
    addTearDown(db.close);

    final folderId = await db.insert('folders', {
      'account_id': 1,
      'name': 'INBOX',
      'path': 'INBOX',
      'type': 'inbox',
      'unread_count': 0,
      'is_local_only': 0,
      'last_synced_uid': 0,
    });
    final messageId = await db.insert('messages', {
      'folder_id': folderId,
      'uid': 1,
      'subject': 'Subject',
      'from_address': 'a@example.com',
      'to_address': 'me@example.com',
      'date': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'snippet': 'snippet',
      'is_flagged': 1,
    });

    final rows = await db.query('messages', where: 'id = ?', whereArgs: [messageId]);
    expect(rows.first['is_flagged'], 1);
  });
}
```

Add to `test/data/local/folder_message_dao_test.dart`, inside the `MessageDao`-related `group` (find it — it follows the `FolderDao` group already shown):

```dart
    test('updateFlagStatus sets is_flagged', () async {
      final folderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      await messageDao.upsertHeaders([
        MailMessage(
          folderId: folderId,
          uid: 1,
          subject: 'Subject',
          from: 'a@example.com',
          to: 'me@example.com',
          date: DateTime.utc(2026, 8, 19),
          snippet: 'snippet',
        ),
      ]);
      final message = (await messageDao.getForFolder(folderId)).first;
      expect(message.isFlagged, isFalse);

      await messageDao.updateFlagStatus(message.id!, true);

      expect((await messageDao.getById(message.id!))!.isFlagged, isTrue);
    });

    test('moveToFolder uses the given newUid instead of synthesizing one when provided', () async {
      final sourceFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
      );
      final destFolderId = await folderDao.upsert(
        MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
      );
      await messageDao.upsertHeaders([
        MailMessage(
          folderId: sourceFolderId,
          uid: 7,
          subject: 'Subject',
          from: 'a@example.com',
          to: 'me@example.com',
          date: DateTime.utc(2026, 8, 19),
          snippet: 'snippet',
        ),
      ]);
      final message = (await messageDao.getForFolder(sourceFolderId)).first;

      await messageDao.moveToFolder(message.id!, destFolderId, newUid: 99);

      final moved = await messageDao.getById(message.id!);
      expect(moved!.folderId, destFolderId);
      expect(moved.uid, 99);
    });
```

(These use the file's existing top-level `folderDao`/`messageDao`/`accountId` fixtures set up in its `setUp`.)

Add to `test/data/transport/mail_message_mapper_test.dart` (open it first to match its existing `MimeMessage` construction helper — add a case asserting `isFlagged` is read from `mime.isFlagged`, following whatever pattern the file already uses for asserting `isRead` from `mime.isSeen`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/imap_mail && flutter test test/models/models_test.dart test/data/local/app_database_test.dart test/data/local/folder_message_dao_test.dart test/data/transport/mail_message_mapper_test.dart`
Expected: FAIL — `isFlagged` doesn't exist on `MailMessage`, `AppDatabase.onUpgrade` doesn't exist, `MessageDao.updateFlagStatus` doesn't exist, `MailFolderType.archive` doesn't exist.

- [ ] **Step 3: Add `MailFolderType.archive`**

Modify `lib/models/enums.dart`:

```dart
enum MailSecurity { none, ssl, startTls }

enum MailFolderType { inbox, sent, trash, archive, other }

enum MailSendStatus { none, sent, failed }
```

- [ ] **Step 4: Add `isFlagged` to `MailMessage`**

Replace `lib/models/mail_message.dart`:

```dart
import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailMessage extends Equatable {
  const MailMessage({
    this.id,
    required this.folderId,
    required this.uid,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.snippet,
    this.bodyText,
    this.bodyHtml,
    this.isRead = false,
    this.isFlagged = false,
    this.isDownloaded = false,
    this.sendStatus = MailSendStatus.none,
  });

  final int? id;
  final int folderId;
  final int uid;
  final String subject;
  final String from;
  final String to;
  final DateTime date;
  final String snippet;
  final String? bodyText;
  final String? bodyHtml;
  final bool isRead;
  final bool isFlagged;
  final bool isDownloaded;
  final MailSendStatus sendStatus;

  MailMessage copyWith({
    int? id,
    int? folderId,
    int? uid,
    String? subject,
    String? from,
    String? to,
    DateTime? date,
    String? snippet,
    String? bodyText,
    String? bodyHtml,
    bool? isRead,
    bool? isFlagged,
    bool? isDownloaded,
    MailSendStatus? sendStatus,
  }) {
    return MailMessage(
      id: id ?? this.id,
      folderId: folderId ?? this.folderId,
      uid: uid ?? this.uid,
      subject: subject ?? this.subject,
      from: from ?? this.from,
      to: to ?? this.to,
      date: date ?? this.date,
      snippet: snippet ?? this.snippet,
      bodyText: bodyText ?? this.bodyText,
      bodyHtml: bodyHtml ?? this.bodyHtml,
      isRead: isRead ?? this.isRead,
      isFlagged: isFlagged ?? this.isFlagged,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      sendStatus: sendStatus ?? this.sendStatus,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'folder_id': folderId,
      'uid': uid,
      'subject': subject,
      'from_address': from,
      'to_address': to,
      'date': date.toUtc().millisecondsSinceEpoch,
      'snippet': snippet,
      'body_text': bodyText,
      'body_html': bodyHtml,
      'is_read': isRead ? 1 : 0,
      'is_flagged': isFlagged ? 1 : 0,
      'is_downloaded': isDownloaded ? 1 : 0,
      'send_status': sendStatus.name,
    };
  }

  factory MailMessage.fromMap(Map<String, Object?> map) {
    return MailMessage(
      id: map['id'] as int?,
      folderId: map['folder_id'] as int,
      uid: map['uid'] as int,
      subject: map['subject'] as String,
      from: map['from_address'] as String,
      to: map['to_address'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int, isUtc: true),
      snippet: map['snippet'] as String,
      bodyText: map['body_text'] as String?,
      bodyHtml: map['body_html'] as String?,
      isRead: (map['is_read'] as int) == 1,
      isFlagged: ((map['is_flagged'] as int?) ?? 0) == 1,
      isDownloaded: (map['is_downloaded'] as int) == 1,
      sendStatus: MailSendStatus.values.byName(map['send_status'] as String),
    );
  }

  @override
  List<Object?> get props => [
        id,
        folderId,
        uid,
        subject,
        from,
        to,
        date,
        snippet,
        bodyText,
        bodyHtml,
        isRead,
        isFlagged,
        isDownloaded,
        sendStatus,
      ];
}
```

(`isFlagged: ((map['is_flagged'] as int?) ?? 0) == 1` tolerates rows written before the column existed, though in practice `onUpgrade`'s `DEFAULT 0` already backfills it.)

- [ ] **Step 5: Add the schema migration**

Replace `lib/data/local/app_database.dart`:

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        display_name TEXT NOT NULL,
        email TEXT NOT NULL,
        imap_host TEXT NOT NULL,
        imap_port INTEGER NOT NULL,
        imap_security TEXT NOT NULL,
        smtp_host TEXT NOT NULL,
        smtp_port TEXT NOT NULL,
        smtp_security TEXT NOT NULL,
        username TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        type TEXT NOT NULL,
        unread_count INTEGER NOT NULL DEFAULT 0,
        is_local_only INTEGER NOT NULL DEFAULT 0,
        last_synced_uid INTEGER NOT NULL DEFAULT 0,
        UNIQUE(account_id, path)
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
        uid INTEGER NOT NULL,
        subject TEXT NOT NULL,
        from_address TEXT NOT NULL,
        to_address TEXT NOT NULL,
        date INTEGER NOT NULL,
        snippet TEXT NOT NULL,
        body_text TEXT,
        body_html TEXT,
        is_read INTEGER NOT NULL DEFAULT 0,
        is_flagged INTEGER NOT NULL DEFAULT 0,
        is_downloaded INTEGER NOT NULL DEFAULT 0,
        send_status TEXT NOT NULL DEFAULT 'none',
        UNIQUE(folder_id, uid)
      )
    ''');

    await db.execute('''
      CREATE TABLE attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        filename TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        local_path TEXT,
        UNIQUE(message_id, filename)
      )
    ''');
  }

  static Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN is_flagged INTEGER NOT NULL DEFAULT 0');
    }
  }

  static Future<Database> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'imap_mail.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
  }
}
```

Note: the `accounts` table's `smtp_port` column type (`TEXT` above) is a typo introduced by copy-paste — **do not actually change it**. Keep it exactly as `INTEGER NOT NULL` as it is in the current file; only the `messages` table's `CREATE TABLE` (adding the `is_flagged` line) and the new `onUpgrade` method / `version: 2` / `onUpgrade: onUpgrade` in `open()` are actual changes here. (Called out explicitly because a careless full-file copy is exactly how a column type regression like this would slip in.)

- [ ] **Step 6: Add `MessageDao.updateFlagStatus` and widen `moveToFolder`**

Modify `lib/data/local/message_dao.dart` — replace the `updateReadStatus`/`moveToFolder` methods (lines 108–130 in the current file) with:

```dart
  Future<void> updateReadStatus(int id, bool isRead) async {
    await _db.update(
      'messages',
      {'is_read': isRead ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateFlagStatus(int id, bool isFlagged) async {
    await _db.update(
      'messages',
      {'is_flagged': isFlagged ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Moves a message to [newFolderId]. If [newUid] is given (the server's
  /// real post-move UID, once known), it's used as-is. Otherwise a synthetic
  /// negative placeholder UID is synthesized, the same way this method
  /// always worked before real server moves existed — a local-only move
  /// (or the optimistic pre-server-confirmation step of a real move) has no
  /// real UID to use yet.
  Future<void> moveToFolder(int messageId, int newFolderId, {int? newUid}) async {
    final uid = newUid ?? await _syntheticUidFor(newFolderId);
    await _db.update(
      'messages',
      {'folder_id': newFolderId, 'uid': uid},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<int> _syntheticUidFor(int folderId) async {
    final rows = await _db.rawQuery(
      'SELECT MIN(uid) as min_uid FROM messages WHERE folder_id = ?',
      [folderId],
    );
    final minUid = rows.first['min_uid'] as int?;
    return (minUid == null || minUid >= 0) ? -1 : minUid - 1;
  }
```

Also update `upsertHeaders`' explicit update map (the `else` branch, currently lines 31–39) to keep `is_flagged` in sync on every header refresh, mirroring how `is_read` is already handled:

```dart
      } else {
        final map = <String, Object?>{
          'subject': message.subject,
          'from_address': message.from,
          'to_address': message.to,
          'date': message.date.toUtc().millisecondsSinceEpoch,
          'snippet': message.snippet,
          'is_read': message.isRead ? 1 : 0,
          'is_flagged': message.isFlagged ? 1 : 0,
        };
```

- [ ] **Step 7: Map `isFlagged` from the server in `mail_message_mapper.dart`**

Modify `lib/data/transport/mail_message_mapper.dart` — in `mapMimeMessageToRecord`, add `isFlagged: mime.isFlagged,` right after the existing `isRead: mime.isSeen,` line.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/models/models_test.dart test/data/local/app_database_test.dart test/data/local/folder_message_dao_test.dart test/data/transport/mail_message_mapper_test.dart`
Expected: PASS.

- [ ] **Step 9: Run the full suite**

Run: `cd ~/imap_mail && flutter test`
Expected: PASS. (Existing tests open in-memory DBs at `version: 1` with `onCreate: AppDatabase.onCreate` directly — that's fine, `onCreate` now includes `is_flagged` unconditionally, and `onUpgrade` is simply never invoked for a freshly-created database.)

- [ ] **Step 10: Commit**

```bash
cd ~/imap_mail
git add lib/models/enums.dart lib/models/mail_message.dart lib/data/local/app_database.dart lib/data/local/message_dao.dart lib/data/transport/mail_message_mapper.dart test/models/models_test.dart test/data/local/app_database_test.dart test/data/local/folder_message_dao_test.dart test/data/transport/mail_message_mapper_test.dart
git commit -m "feat(swipe): add isFlagged and Archive folder type, with schema migration"
```

---

### Task 2: Transport layer — `setSeen`, `setFlagged`, `moveMessage`

**Files:**
- Modify: `lib/data/transport/mail_transport.dart`
- Modify: `lib/data/transport/enough_mail_transport.dart`

**Interfaces:**
- Consumes: `MailFolderType.archive` (Task 1).
- Produces (added to `MailTransport` and implemented in `EnoughMailTransport`):
  - `Future<void> setSeen(MailAccount account, String password, MailFolder folder, MailMessage message, bool value)`
  - `Future<void> setFlagged(MailAccount account, String password, MailFolder folder, MailMessage message, bool value)`
  - `Future<int?> moveMessage(MailAccount account, String password, MailFolder source, MailMessage message, MailFolder destination)` — returns the message's new UID in `destination` when the server reports one, else `null`.
  - `EnoughMailTransport._folderTypeFor` now also recognizes `box.isArchive`.

There is no dedicated test file for `enough_mail_transport.dart` today (it requires a live IMAP connection; none of its existing methods are unit-tested directly — they're exercised indirectly through `MailRepository` tests against a mocked `MailTransport`, same as this task's new methods will be in Task 3). This task has no red/green cycle of its own; implement directly, matching the file's existing conventions exactly.

- [ ] **Step 1: Add the three methods to the `MailTransport` interface**

Modify `lib/data/transport/mail_transport.dart` — add before the closing `}`:

```dart
  Future<void> setSeen(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  );

  Future<void> setFlagged(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  );

  /// Moves [message] from [source] to [destination] on the server. Returns
  /// the message's new UID in [destination] if the server reports one (IMAP
  /// MOVE/COPY typically assigns a new UID in the destination mailbox), or
  /// `null` if it couldn't be determined.
  Future<int?> moveMessage(
    MailAccount account,
    String password,
    MailFolder source,
    MailMessage message,
    MailFolder destination,
  );
```

- [ ] **Step 2: Implement them in `EnoughMailTransport`, and detect Archive**

Modify `lib/data/transport/enough_mail_transport.dart`:

Replace `_folderTypeFor` (current lines 75–80):

```dart
  MailFolderType _folderTypeFor(enough.Mailbox box) {
    if (box.isInbox) return MailFolderType.inbox;
    if (box.isSent) return MailFolderType.sent;
    if (box.isTrash) return MailFolderType.trash;
    if (box.isArchive) return MailFolderType.archive;
    return MailFolderType.other;
  }
```

Add before the closing `}` of the class (after `fetchAttachmentList`):

```dart
  @override
  Future<void> setSeen(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      await client.store(
        sequence,
        [enough.MessageFlags.seen],
        action: value ? enough.StoreAction.add : enough.StoreAction.remove,
      );
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<void> setFlagged(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      await client.store(
        sequence,
        [enough.MessageFlags.flagged],
        action: value ? enough.StoreAction.add : enough.StoreAction.remove,
      );
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<int?> moveMessage(
    MailAccount account,
    String password,
    MailFolder source,
    MailMessage message,
    MailFolder destination,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      // Resolve the destination Mailbox object without selecting it (that
      // would change the client's active mailbox away from the source,
      // which moveMessages needs selected as the move-from mailbox).
      final mailboxes = await client.listMailboxes();
      final targetMailbox = mailboxes.firstWhereOrNull((box) => box.path == destination.path);
      if (targetMailbox == null) {
        throw StateError('Destination folder ${destination.path} not found on server');
      }
      await client.selectMailboxByPath(source.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final result = await client.moveMessages(sequence, targetMailbox);
      return result.targetSequence?.toList().firstOrNull;
    } finally {
      await client.disconnect();
    }
  }
```

(`firstWhereOrNull`/`firstOrNull` come from `package:collection/collection.dart`, already imported at the top of this file.)

- [ ] **Step 3: Confirm the project still compiles**

Run: `cd ~/imap_mail && flutter analyze`
Expected: no new errors. (`MailTransport` is also implemented by `test/data/repository/mail_repository_test.dart`'s `MockMailTransport` via mocktail, which auto-satisfies any interface shape, and by `test/widget/message_detail_screen_test.dart`'s hand-written `_FakeMailTransport`, which will show as broken here — that's expected and fixed in Task 3/4.)

- [ ] **Step 4: Commit**

```bash
cd ~/imap_mail
git add lib/data/transport/mail_transport.dart lib/data/transport/enough_mail_transport.dart
git commit -m "feat(swipe): add setSeen/setFlagged/moveMessage to the transport layer"
```

---

### Task 3: Repository layer — `moveMessage`, `archiveMessage`, `markRead`, `markFlagged`, updated `deleteMessage`

**Files:**
- Modify: `lib/data/repository/mail_repository.dart`
- Modify: `test/data/repository/mail_repository_test.dart`

**Interfaces:**
- Consumes: `MailTransport.setSeen`/`setFlagged`/`moveMessage` (Task 2); `MessageDao.updateFlagStatus`/widened `moveToFolder` (Task 1).
- Produces:
  - `Future<MailMessage> moveMessage(MailAccount account, MailFolder from, MailFolder to, MailMessage message)` — the shared optimistic-move-then-revert-on-failure primitive; returns the message with its updated `folderId`/`uid`.
  - `Future<MailMessage> archiveMessage(MailAccount account, MailFolder currentFolder, MailMessage message)` — throws `StateError` if the account has no Archive folder.
  - `Future<MailMessage> deleteMessage(MailAccount account, MailFolder currentFolder, MailMessage message)` — **signature change**: now takes `account` as the first argument (was `deleteMessage(MailFolder, MailMessage)`), and returns the resulting `MailMessage` (was `Future<void>`) so callers can tell whether it actually moved (`result.folderId != currentFolder.id`) or was permanently removed (Trash-less/already-in-Trash branches, unchanged local-only behavior).
  - `Future<void> markRead(MailAccount account, MailFolder folder, MailMessage message, bool isRead)` — **replaces** `markAsRead(int messageId)`.
  - `Future<void> markFlagged(MailAccount account, MailFolder folder, MailMessage message, bool isFlagged)`.

- [ ] **Step 1: Write the failing/updated tests**

In `test/data/repository/mail_repository_test.dart`, replace the existing `'markAsRead marks the message read locally'` test and the three `deleteMessage` tests (the four tests currently spanning roughly lines 492–591) with:

```dart
  test('markRead marks the message read locally and on the server', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;
    expect(message.isRead, isFalse);
    when(() => transport.setSeen(any(), any(), any(), any(), any())).thenAnswer((_) async {});

    await repository.markRead(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(message.id!))!.isRead, isTrue);
    verify(() => transport.setSeen(any(), any(), any(), message, true)).called(1);
  });

  test('markRead reverts the local change and rethrows when the server call fails', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setSeen(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.markRead(account.copyWith(id: accountId), folder, message, true),
      throwsException,
    );

    expect((await messageDao.getById(message.id!))!.isRead, isFalse);
  });

  test('markFlagged flags the message locally and on the server', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setFlagged(any(), any(), any(), any(), any())).thenAnswer((_) async {});

    await repository.markFlagged(account.copyWith(id: accountId), folder, message, true);

    expect((await messageDao.getById(message.id!))!.isFlagged, isTrue);
    verify(() => transport.setFlagged(any(), any(), any(), message, true)).called(1);
  });

  test('markFlagged reverts the local change and rethrows when the server call fails', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.setFlagged(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.markFlagged(account.copyWith(id: accountId), folder, message, true),
      throwsException,
    );

    expect((await messageDao.getById(message.id!))!.isFlagged, isFalse);
  });

  test('archiveMessage moves the message to Archive locally and on the server, and adopts the server\'s new uid', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final archiveFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => 42);

    final result = await repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(result.folderId, archiveFolderId);
    expect(result.uid, 42);
    final archived = await messageDao.getForFolder(archiveFolderId);
    expect(archived, hasLength(1));
    expect(archived.first.uid, 42);
    expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
  });

  test('archiveMessage throws and leaves the message in place when the account has no Archive folder', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;

    await expectLater(
      repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsA(isA<StateError>()),
    );

    expect(await messageDao.getForFolder(inboxFolderId), hasLength(1));
  });

  test('archiveMessage reverts the local move and rethrows when the server call fails', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final archiveFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.archive),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 5,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.archiveMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsException,
    );

    expect(await messageDao.getForFolder(inboxFolderId), hasLength(1));
    expect(await messageDao.getForFolder(archiveFolderId), isEmpty);
  });

  test('deleteMessage moves the message to Trash locally and on the server when a Trash folder exists and it isn\'t already there', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenAnswer((_) async => 77);

    final result = await repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(result.folderId, trashFolderId);
    final trashMessages = await messageDao.getForFolder(trashFolderId);
    expect(trashMessages, hasLength(1));
    expect(trashMessages.first.id, message.id);
    final inboxMessages = await messageDao.getForFolder(inboxFolderId);
    expect(inboxMessages, isEmpty);
  });

  test('deleteMessage permanently removes the message locally (no server call) when no Trash folder exists', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;

    await repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message);

    expect(await messageDao.getById(message.id!), isNull);
    expect(await messageDao.getForFolder(inboxFolderId), isEmpty);
    verifyNever(() => transport.moveMessage(any(), any(), any(), any(), any()));
  });

  test('deleteMessage permanently removes the message locally (no server call) when it is already in the Trash folder', () async {
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final trashFolder = (await folderDao.getById(trashFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: trashFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(trashFolderId)).first;

    await repository.deleteMessage(account.copyWith(id: accountId), trashFolder, message);

    expect(await messageDao.getById(message.id!), isNull);
    expect(await messageDao.getForFolder(trashFolderId), isEmpty);
    verifyNever(() => transport.moveMessage(any(), any(), any(), any(), any()));
  });

  test('deleteMessage reverts the local move and rethrows when the server call fails', () async {
    final inboxFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final inboxFolder = (await folderDao.getById(inboxFolderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: inboxFolderId,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
      ),
    ]);
    final message = (await messageDao.getForFolder(inboxFolderId)).first;
    when(() => transport.moveMessage(any(), any(), any(), any(), any())).thenThrow(Exception('offline'));

    await expectLater(
      repository.deleteMessage(account.copyWith(id: accountId), inboxFolder, message),
      throwsException,
    );

    expect(await messageDao.getForFolder(inboxFolderId), hasLength(1));
    expect(await messageDao.getForFolder(trashFolderId), isEmpty);
  });
```

Also update `setUpAll`'s `registerFallbackValue` calls: `bool` doesn't need a fallback (mocktail handles core types out of the box, same as the existing `String`/int usages in this file and `providers_test.dart`), so no change needed there.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/imap_mail && flutter test test/data/repository/mail_repository_test.dart`
Expected: FAIL — `markRead`/`markFlagged`/`archiveMessage`/`moveMessage` don't exist yet, `deleteMessage` has the old signature.

- [ ] **Step 3: Rewrite the affected `MailRepository` methods**

Modify `lib/data/repository/mail_repository.dart` — replace the `markAsRead` method (current lines 130–134) with:

```dart
  /// Moves [message] from [from] to [to], locally and on the server.
  /// Optimistic: the local row moves first (instant UI feedback), then the
  /// server-side move happens; once the server confirms with a new UID, the
  /// local row is corrected to use it (so a subsequent move — e.g. an Undo
  /// — addresses the right message). On failure, the local move is reverted
  /// and the error rethrown so callers can retry.
  Future<MailMessage> moveMessage(
    MailAccount account,
    MailFolder from,
    MailFolder to,
    MailMessage message,
  ) async {
    await _messageDao.moveToFolder(message.id!, to.id!);
    try {
      final password = await _passwordFor(account);
      final newUid = await _transport.moveMessage(account, password, from, message, to);
      if (newUid != null) {
        await _messageDao.moveToFolder(message.id!, to.id!, newUid: newUid);
      }
      return message.copyWith(folderId: to.id!, uid: newUid ?? message.uid);
    } catch (_) {
      await _messageDao.moveToFolder(message.id!, from.id!);
      rethrow;
    }
  }

  /// Moves [message] to the account's Archive folder. Throws [StateError]
  /// if the account has no Archive folder — nothing is moved in that case.
  Future<MailMessage> archiveMessage(
    MailAccount account,
    MailFolder currentFolder,
    MailMessage message,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final archiveFolder = folders.where((f) => f.type == MailFolderType.archive).firstOrNull;
    if (archiveFolder == null) {
      throw StateError('No Archive folder found for account ${currentFolder.accountId}');
    }
    return moveMessage(account, currentFolder, archiveFolder, message);
  }

  /// Marks a message's read status both locally and on the IMAP server.
  /// Optimistic: the local row updates first, then the `\Seen` flag is
  /// stored on the server. On failure the local row is reverted to its
  /// prior value and the error rethrown.
  Future<void> markRead(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    bool isRead,
  ) async {
    final previous = message.isRead;
    await _messageDao.updateReadStatus(message.id!, isRead);
    try {
      final password = await _passwordFor(account);
      await _transport.setSeen(account, password, folder, message, isRead);
    } catch (_) {
      await _messageDao.updateReadStatus(message.id!, previous);
      rethrow;
    }
  }

  /// Same optimistic-then-revert-on-failure pattern as [markRead], for the
  /// `\Flagged` flag.
  Future<void> markFlagged(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    bool isFlagged,
  ) async {
    final previous = message.isFlagged;
    await _messageDao.updateFlagStatus(message.id!, isFlagged);
    try {
      final password = await _passwordFor(account);
      await _transport.setFlagged(account, password, folder, message, isFlagged);
    } catch (_) {
      await _messageDao.updateFlagStatus(message.id!, previous);
      rethrow;
    }
  }
```

Replace the `deleteMessage` method (current lines 205–213) with:

```dart
  /// Deletes a message by moving it to Trash (locally and on the server), or
  /// permanently removing it locally when there's no Trash folder to move it
  /// to, or when it's already in Trash. Those permanent-removal branches
  /// stay local-only — deliberately: this app doesn't implement IMAP
  /// permanent delete (STORE \Deleted + EXPUNGE), only the move-based path
  /// that's the day-to-day case. Returns the resulting message so callers
  /// can tell which branch ran (`result.folderId != currentFolder.id` means
  /// it moved to Trash).
  Future<MailMessage> deleteMessage(
    MailAccount account,
    MailFolder currentFolder,
    MailMessage message,
  ) async {
    final folders = await _folderDao.getForAccount(currentFolder.accountId);
    final trashFolder = folders.where((f) => f.type == MailFolderType.trash).firstOrNull;
    if (trashFolder != null && trashFolder.id != currentFolder.id) {
      return moveMessage(account, currentFolder, trashFolder, message);
    }
    await _messageDao.deleteMessage(message.id!);
    return message;
  }
```

Leave every other method in the file (`ensureOutboxFolder`, `syncFolders`, `syncHeaders`, `getCachedMessages`, `fetchBodyIfNeeded`, `sendMessage`, `retryFailedMessage`, `getAttachments`, `downloadAttachment`, `recordAttachmentLocalPath`) untouched — `retryFailedMessage` calls `_messageDao.deleteMessage(...)` directly (not `this.deleteMessage`), so it's unaffected by the signature change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/data/repository/mail_repository_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `cd ~/imap_mail && flutter test`
Expected: `test/widget/message_detail_screen_test.dart` and `test/widget/settings_screen_test.dart` (if the dark-theme plan landed) will now fail to *compile* — `message_detail_screen_test.dart`'s `_FakeMailTransport` no longer satisfies `MailTransport` (missing the 3 new methods), and `message_detail_screen.dart` itself still calls the old `markAsRead`/old-signature `deleteMessage`. That's expected — fixed in Task 4.

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/data/repository/mail_repository.dart test/data/repository/mail_repository_test.dart
git commit -m "feat(swipe): repository actions for archive/delete/flag/mark-read with server sync"
```

---

### Task 4: Update `MessageDetailScreen` for the new repository signatures

**Files:**
- Modify: `lib/screens/message_detail_screen.dart`
- Modify: `test/widget/message_detail_screen_test.dart`

**Interfaces:**
- Consumes: `MailRepository.markRead`/`deleteMessage` (Task 3); `MailTransport` (Task 2, for the test file's hand-written fake).

- [ ] **Step 1: Update the fake transport and add overrides across every test**

Replace `test/widget/message_detail_screen_test.dart` in full:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_attachment.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeCredentialStore implements SecureCredentialStore {
  @override
  Future<void> savePassword({required int accountId, required String password}) async {}
  @override
  Future<String?> getPassword(int accountId) async => 'app-password';
  @override
  Future<void> deletePassword(int accountId) async {}
}

/// Hand-written fake (rather than mocktail) so every method's behavior is
/// explicit and configurable per test without registering fallback values
/// for every domain type.
class _FakeMailTransport implements MailTransport {
  bool throwOnFetchBody = false;
  int fetchHeadersSinceCallCount = 0;

  @override
  Future<void> testConnection(MailAccount account, String password) async {}

  @override
  Future<List<MailFolder>> discoverFolders(MailAccount account, String password, int accountId) async => [];

  @override
  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  ) async {
    fetchHeadersSinceCallCount++;
    return [];
  }

  @override
  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async {
    if (throwOnFetchBody) {
      throw Exception('connection refused');
    }
    throw UnimplementedError('not exercised by this test');
  }

  @override
  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async =>
      [];

  @override
  Future<List<MailAttachment>> fetchAttachmentList(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async =>
      [];

  @override
  Future<void> setSeen(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {}

  @override
  Future<void> setFlagged(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    bool value,
  ) async {}

  @override
  Future<int?> moveMessage(
    MailAccount account,
    String password,
    MailFolder source,
    MailMessage message,
    MailFolder destination,
  ) async =>
      null;
}

class _FakeMailSender implements MailSender {
  bool sendCalled = false;
  ComposedMessage? lastMessage;

  @override
  Future<void> send(MailAccount account, String password, ComposedMessage message) async {
    sendCalled = true;
    lastMessage = message;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // Use the no-isolate ffi factory: this test pumps a real widget that
    // awaits real async DAO calls through mailRepositoryProvider inside
    // testWidgets' fake-async environment. The default databaseFactoryFfi
    // dispatches SQLite calls to a background worker isolate; cross-isolate
    // message delivery can deadlock under that environment (unlike the
    // codebase's plain `test()` DAO tests, which run on the real event loop
    // and are unaffected). Running SQLite calls directly on the calling
    // isolate avoids the deadlock.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  // The real database/accounts provider chain reaches through path_provider
  // and sqflite platform channels, which never settle inside a widget test's
  // fake async zone (see folder_view_screen_test.dart for the same
  // established fix). We instead override databaseProvider with a
  // pre-populated in-memory sqflite database and accountsProvider with a
  // fake notifier, exercising the real MailRepository/DAO logic without
  // touching any platform channel. mailTransportProvider/credentialStoreProvider
  // are also always overridden now: MessageDetailScreen's _load() fires a
  // fire-and-forget markRead on every open, which (since markRead syncs to
  // the server) would otherwise try a real network connection to
  // imap.example.com and hang the test.
  Future<
      ({
        MailAccount account,
        MailFolder folder,
        MailMessage message,
        Database db,
      })> seedDatabase({
    List<MailAttachment> attachments = const [],
    bool downloaded = true,
    MailSendStatus sendStatus = MailSendStatus.none,
  }) async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: AppDatabase.onCreate,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    const accountTemplate = MailAccount(
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
    final accountId = await AccountDao(db).insert(accountTemplate);
    final account = accountTemplate.copyWith(id: accountId);

    final folderDao = FolderDao(db);
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;

    final messageDao = MessageDao(db);
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 1,
        subject: 'Hello',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'Hi',
        bodyText: downloaded ? 'Hi there, this is the plain body.' : null,
        isDownloaded: downloaded,
        sendStatus: sendStatus,
      ),
    ]);
    final message = (await messageDao.getForFolder(folderId)).first;

    if (attachments.isNotEmpty) {
      await AttachmentDao(db).insertAll(
        attachments.map((a) => a.copyWith(messageId: message.id)).toList(),
      );
    }

    return (account: account, folder: folder, message: message, db: db);
  }

  testWidgets('renders plain text body when no HTML is present', (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(_FakeMailTransport()),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('Hi there, this is the plain body.'), findsOneWidget);
  });

  testWidgets('loads and renders attachment metadata persisted for the message', (tester) async {
    final seed = await seedDatabase(attachments: const [
      MailAttachment(
        messageId: 0,
        filename: 'invoice.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);
    addTearDown(() => seed.db.close());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(_FakeMailTransport()),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('invoice.pdf'), findsOneWidget);
  });

  testWidgets('confirming delete moves the message to Trash and pops back to the folder view', (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());
    final folderDao = FolderDao(seed.db);
    final trashFolderId = await folderDao.upsert(
      MailFolder(accountId: seed.account.id!, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(_FakeMailTransport()),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (settings) => MaterialPageRoute(
            builder: (_) => MessageDetailScreen(folder: seed.folder, message: seed.message),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(find.text('Delete this message?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MessageDetailScreen), findsNothing);

    final messageDao = MessageDao(seed.db);
    final trashMessages = await messageDao.getForFolder(trashFolderId);
    expect(trashMessages, hasLength(1));
    expect(trashMessages.first.id, seed.message.id);
    final inboxMessages = await messageDao.getForFolder(seed.folder.id!);
    expect(inboxMessages, isEmpty);
  });

  testWidgets('marks the message read after a successful load', (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(_FakeMailTransport()),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final refreshed = await MessageDao(seed.db).getById(seed.message.id!);
    expect(refreshed!.isRead, isTrue);
  });

  testWidgets('shows an error with a Retry button instead of a permanent spinner when loading the body fails',
      (tester) async {
    final seed = await seedDatabase(downloaded: false);
    addTearDown(() => seed.db.close());
    final transport = _FakeMailTransport()..throwOnFetchBody = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(transport),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
      ],
      child: MaterialApp(home: MessageDetailScreen(folder: seed.folder, message: seed.message)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('connection refused'), findsOneWidget);
    final retryButtonFinder = find.widgetWithText(ElevatedButton, 'Retry');
    expect(retryButtonFinder, findsOneWidget);

    // Retry re-runs _load(); still fails the same way (transport keeps
    // throwing), proving Retry actually re-triggers a load rather than
    // being a dead button.
    await tester.tap(retryButtonFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('connection refused'), findsOneWidget);
  });

  testWidgets('deleting a message invalidates messagesProvider so the folder view resyncs instead of showing stale data',
      (tester) async {
    final seed = await seedDatabase();
    addTearDown(() => seed.db.close());
    final folderDao = FolderDao(seed.db);
    await folderDao.upsert(
      MailFolder(accountId: seed.account.id!, name: 'Trash', path: 'Trash', type: MailFolderType.trash),
    );
    final transport = _FakeMailTransport();

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => seed.db),
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
      mailTransportProvider.overrideWithValue(transport),
      credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
    ]);
    addTearDown(container.dispose);

    // Warm the messagesProvider cache the way FolderViewScreen would.
    await container.read(messagesProvider(seed.folder).future);
    expect(transport.fetchHeadersSinceCallCount, 1);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (settings) => MaterialPageRoute(
            builder: (_) => MessageDetailScreen(folder: seed.folder, message: seed.message),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Re-reading messagesProvider(folder) must re-sync (hit the transport
    // again) rather than silently serving the stale cached list that still
    // contains the just-deleted message.
    await container.read(messagesProvider(seed.folder).future);
    expect(transport.fetchHeadersSinceCallCount, 2);
  });

  testWidgets('shows a Retry-send action for a failed message and calls retryFailedMessage', (tester) async {
    final seed = await seedDatabase(sendStatus: MailSendStatus.failed);
    addTearDown(() => seed.db.close());
    final sender = _FakeMailSender();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => seed.db),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([seed.account])),
        mailTransportProvider.overrideWithValue(_FakeMailTransport()),
        credentialStoreProvider.overrideWithValue(_FakeCredentialStore()),
        mailSenderProvider.overrideWithValue(sender),
      ],
      child: MaterialApp(
        home: Navigator(
          onGenerateRoute: (settings) => MaterialPageRoute(
            builder: (_) => MessageDetailScreen(folder: seed.folder, message: seed.message),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final retryIconFinder = find.byIcon(Icons.refresh);
    expect(retryIconFinder, findsOneWidget);

    await tester.tap(retryIconFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(sender.sendCalled, isTrue);
    expect(sender.lastMessage!.subject, seed.message.subject);
    // Retry navigates back on success, same as the delete flow.
    expect(find.byType(MessageDetailScreen), findsNothing);
    final remaining = await MessageDao(seed.db).getById(seed.message.id!);
    expect(remaining, isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/imap_mail && flutter test test/widget/message_detail_screen_test.dart`
Expected: FAIL to compile — `message_detail_screen.dart` still calls `repository.markAsRead(resolved.id!)` and `repository.deleteMessage(widget.folder, ...)` (old signature).

- [ ] **Step 3: Update the call sites in `message_detail_screen.dart`**

Modify `lib/screens/message_detail_screen.dart` — in `_load()`, replace:

```dart
      // Fire-and-forget: marking a message read shouldn't block or fail the
      // view from rendering its already-fetched content.
      if (resolved.id != null) {
        unawaited(repository.markAsRead(resolved.id!));
      }
```

with:

```dart
      // Fire-and-forget: marking a message read shouldn't block or fail the
      // view from rendering its already-fetched content. Swallow any error
      // (e.g. offline) rather than surfacing it here — this isn't a swipe
      // action, there's no retry affordance on this screen for it.
      if (resolved.id != null) {
        unawaited(repository.markRead(account, widget.folder, resolved, true).catchError((_) {}));
      }
```

In `_confirmDelete()`, replace:

```dart
      try {
        final repository = await ref.read(mailRepositoryProvider.future);
        await repository.deleteMessage(widget.folder, _resolved ?? widget.message);
```

with:

```dart
      try {
        final repository = await ref.read(mailRepositoryProvider.future);
        final accounts = await ref.read(accountsProvider.future);
        final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
        await repository.deleteMessage(account, widget.folder, _resolved ?? widget.message);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/widget/message_detail_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `cd ~/imap_mail && flutter test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/screens/message_detail_screen.dart test/widget/message_detail_screen_test.dart
git commit -m "fix(swipe): update MessageDetailScreen for the new repository signatures"
```

---

### Task 5: `SwipeAction` model and `SwipeActionConfigNotifier`

**Files:**
- Create: `lib/models/swipe_action.dart`
- Create: `lib/providers/swipe_action_providers.dart`
- Test: `test/providers/swipe_action_providers_test.dart`

**Interfaces:**
- Produces:
  - `enum SwipeAction { archive, delete, flag, toggleRead, none }` with a `String get label` extension (`'Archive'`, `'Delete'`, `'Flag/Unflag'`, `'Mark read/unread'`, `'None'`).
  - `enum SwipeSlot { leftPrimary, leftSecondary, rightPrimary, rightSecondary }`
  - `class SwipeActionConfig extends Equatable` with `leftPrimary`/`leftSecondary`/`rightPrimary`/`rightSecondary` (all `SwipeAction`), `static const defaults`, `copyWith`, and `SwipeActionConfig withSlot(SwipeSlot slot, SwipeAction action)`.
  - `class SwipeActionConfigNotifier extends Notifier<SwipeActionConfig>` with `Future<void> get ready` and `Future<void> setSlot(SwipeSlot slot, SwipeAction action)`.
  - `final swipeActionConfigProvider = NotifierProvider<SwipeActionConfigNotifier, SwipeActionConfig>(SwipeActionConfigNotifier.new);`

- [ ] **Step 1: Write the failing tests**

Create `test/providers/swipe_action_providers_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';

void main() {
  test('defaults to Archive/Flag on the left and Delete/Mark-read-unread on the right', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(swipeActionConfigProvider.notifier);
    await notifier.ready;

    final config = container.read(swipeActionConfigProvider);
    expect(config.leftPrimary, SwipeAction.archive);
    expect(config.leftSecondary, SwipeAction.flag);
    expect(config.rightPrimary, SwipeAction.delete);
    expect(config.rightSecondary, SwipeAction.toggleRead);
  });

  test('loads a previously persisted configuration on startup', () async {
    SharedPreferences.setMockInitialValues({
      'swipe_left_primary': 'delete',
      'swipe_left_secondary': 'none',
      'swipe_right_primary': 'archive',
      'swipe_right_secondary': 'flag',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(swipeActionConfigProvider.notifier);
    await notifier.ready;

    final config = container.read(swipeActionConfigProvider);
    expect(config.leftPrimary, SwipeAction.delete);
    expect(config.leftSecondary, SwipeAction.none);
    expect(config.rightPrimary, SwipeAction.archive);
    expect(config.rightSecondary, SwipeAction.flag);
  });

  test('setSlot updates just that slot, persists it, and leaves the rest unchanged', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(swipeActionConfigProvider.notifier);
    await notifier.ready;

    await notifier.setSlot(SwipeSlot.rightSecondary, SwipeAction.none);

    final config = container.read(swipeActionConfigProvider);
    expect(config.rightSecondary, SwipeAction.none);
    expect(config.leftPrimary, SwipeAction.archive);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('swipe_right_secondary'), 'none');
  });

  test('a fresh notifier picks up a configuration persisted by a previous one', () async {
    SharedPreferences.setMockInitialValues({});
    final container1 = ProviderContainer();
    addTearDown(container1.dispose);
    final notifier1 = container1.read(swipeActionConfigProvider.notifier);
    await notifier1.ready;
    await notifier1.setSlot(SwipeSlot.leftPrimary, SwipeAction.toggleRead);

    final container2 = ProviderContainer();
    addTearDown(container2.dispose);
    final notifier2 = container2.read(swipeActionConfigProvider.notifier);
    await notifier2.ready;

    expect(container2.read(swipeActionConfigProvider).leftPrimary, SwipeAction.toggleRead);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/imap_mail && flutter test test/providers/swipe_action_providers_test.dart`
Expected: FAIL — neither file exists yet.

- [ ] **Step 3: Implement `SwipeAction`/`SwipeActionConfig`**

Create `lib/models/swipe_action.dart`:

```dart
import 'package:equatable/equatable.dart';

enum SwipeAction { archive, delete, flag, toggleRead, none }

extension SwipeActionLabel on SwipeAction {
  String get label => switch (this) {
        SwipeAction.archive => 'Archive',
        SwipeAction.delete => 'Delete',
        SwipeAction.flag => 'Flag/Unflag',
        SwipeAction.toggleRead => 'Mark read/unread',
        SwipeAction.none => 'None',
      };
}

enum SwipeSlot { leftPrimary, leftSecondary, rightPrimary, rightSecondary }

class SwipeActionConfig extends Equatable {
  const SwipeActionConfig({
    required this.leftPrimary,
    required this.leftSecondary,
    required this.rightPrimary,
    required this.rightSecondary,
  });

  final SwipeAction leftPrimary;
  final SwipeAction leftSecondary;
  final SwipeAction rightPrimary;
  final SwipeAction rightSecondary;

  static const defaults = SwipeActionConfig(
    leftPrimary: SwipeAction.archive,
    leftSecondary: SwipeAction.flag,
    rightPrimary: SwipeAction.delete,
    rightSecondary: SwipeAction.toggleRead,
  );

  SwipeActionConfig copyWith({
    SwipeAction? leftPrimary,
    SwipeAction? leftSecondary,
    SwipeAction? rightPrimary,
    SwipeAction? rightSecondary,
  }) {
    return SwipeActionConfig(
      leftPrimary: leftPrimary ?? this.leftPrimary,
      leftSecondary: leftSecondary ?? this.leftSecondary,
      rightPrimary: rightPrimary ?? this.rightPrimary,
      rightSecondary: rightSecondary ?? this.rightSecondary,
    );
  }

  SwipeActionConfig withSlot(SwipeSlot slot, SwipeAction action) {
    switch (slot) {
      case SwipeSlot.leftPrimary:
        return copyWith(leftPrimary: action);
      case SwipeSlot.leftSecondary:
        return copyWith(leftSecondary: action);
      case SwipeSlot.rightPrimary:
        return copyWith(rightPrimary: action);
      case SwipeSlot.rightSecondary:
        return copyWith(rightSecondary: action);
    }
  }

  SwipeAction forSlot(SwipeSlot slot) {
    switch (slot) {
      case SwipeSlot.leftPrimary:
        return leftPrimary;
      case SwipeSlot.leftSecondary:
        return leftSecondary;
      case SwipeSlot.rightPrimary:
        return rightPrimary;
      case SwipeSlot.rightSecondary:
        return rightSecondary;
    }
  }

  @override
  List<Object?> get props => [leftPrimary, leftSecondary, rightPrimary, rightSecondary];
}
```

- [ ] **Step 4: Implement `SwipeActionConfigNotifier`**

Create `lib/providers/swipe_action_providers.dart`:

```dart
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/swipe_action.dart';

const _keys = {
  SwipeSlot.leftPrimary: 'swipe_left_primary',
  SwipeSlot.leftSecondary: 'swipe_left_secondary',
  SwipeSlot.rightPrimary: 'swipe_right_primary',
  SwipeSlot.rightSecondary: 'swipe_right_secondary',
};

class SwipeActionConfigNotifier extends Notifier<SwipeActionConfig> {
  late Future<void> _readyFuture;

  /// Resolves once a persisted configuration (if any) has been loaded and
  /// applied to state — see ThemeModeNotifier for why this pattern exists
  /// (Notifier.build() must return synchronously).
  Future<void> get ready => _readyFuture;

  @override
  SwipeActionConfig build() {
    _readyFuture = _load();
    return SwipeActionConfig.defaults;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = SwipeActionConfig(
      leftPrimary: _fromName(prefs.getString(_keys[SwipeSlot.leftPrimary]!)) ??
          SwipeActionConfig.defaults.leftPrimary,
      leftSecondary: _fromName(prefs.getString(_keys[SwipeSlot.leftSecondary]!)) ??
          SwipeActionConfig.defaults.leftSecondary,
      rightPrimary: _fromName(prefs.getString(_keys[SwipeSlot.rightPrimary]!)) ??
          SwipeActionConfig.defaults.rightPrimary,
      rightSecondary: _fromName(prefs.getString(_keys[SwipeSlot.rightSecondary]!)) ??
          SwipeActionConfig.defaults.rightSecondary,
    );
  }

  Future<void> setSlot(SwipeSlot slot, SwipeAction action) async {
    state = state.withSlot(slot, action);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys[slot]!, action.name);
  }

  SwipeAction? _fromName(String? name) {
    if (name == null) return null;
    return SwipeAction.values.firstWhereOrNull((a) => a.name == name);
  }
}

final swipeActionConfigProvider = NotifierProvider<SwipeActionConfigNotifier, SwipeActionConfig>(
  SwipeActionConfigNotifier.new,
);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/providers/swipe_action_providers_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/models/swipe_action.dart lib/providers/swipe_action_providers.dart test/providers/swipe_action_providers_test.dart
git commit -m "feat(swipe): add SwipeActionConfig persisted via shared_preferences"
```

---

### Task 6: Swipe customization in Settings

**Files:**
- Modify: `lib/screens/settings_screen.dart`
- Modify: `test/widget/settings_screen_test.dart`

**Interfaces:**
- Consumes: `swipeActionConfigProvider` / `SwipeActionConfigNotifier.setSlot()` (Task 5).

- [ ] **Step 1: Write the failing test**

Add to `test/widget/settings_screen_test.dart` (this file already has the theme-picker tests from the dark-theme plan — add these imports and this test alongside them):

```dart
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
```

```dart
  testWidgets('swipe action dropdowns reflect the current config and call setSlot on change', (tester) async {
    final fakeSwipeNotifier = _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
        swipeActionConfigProvider.overrideWith(() => fakeSwipeNotifier),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<SwipeAction>), findsNWidgets(4));

    final leftPrimaryDropdown = tester.widget<DropdownButton<SwipeAction>>(
      find.byKey(const ValueKey('swipe_left_primary_dropdown')),
    );
    expect(leftPrimaryDropdown.value, SwipeAction.archive);

    await tester.tap(find.byKey(const ValueKey('swipe_left_primary_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(fakeSwipeNotifier.state.leftPrimary, SwipeAction.delete);
  });
```

Add the fake notifier class at the bottom of the file:

```dart
class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  _FakeSwipeActionConfigNotifier(this._initial);
  final SwipeActionConfig _initial;

  @override
  SwipeActionConfig build() => _initial;

  @override
  Future<void> setSlot(SwipeSlot slot, SwipeAction action) async {
    state = state.withSlot(slot, action);
  }
}
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `cd ~/imap_mail && flutter test test/widget/settings_screen_test.dart`
Expected: the new test FAILS — `find.byType(DropdownButton<SwipeAction>)` finds nothing yet.

- [ ] **Step 3: Add the dropdowns to `SettingsScreen`**

Modify `lib/screens/settings_screen.dart` — add the import:

```dart
import '../models/swipe_action.dart';
import '../providers/swipe_action_providers.dart';
```

Insert a new section between the theme picker `Padding`/`Divider` and the accounts list `Expanded` (i.e. right after the existing theme section's `const Divider(height: 1),`):

```dart
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Swipe actions', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _SwipeSlotRow(
                  label: 'Left, primary (full swipe)',
                  slotKey: 'swipe_left_primary_dropdown',
                  value: swipeConfig.leftPrimary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftPrimary, action),
                ),
                _SwipeSlotRow(
                  label: 'Left, secondary',
                  slotKey: 'swipe_left_secondary_dropdown',
                  value: swipeConfig.leftSecondary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftSecondary, action),
                ),
                _SwipeSlotRow(
                  label: 'Right, primary (full swipe)',
                  slotKey: 'swipe_right_primary_dropdown',
                  value: swipeConfig.rightPrimary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.rightPrimary, action),
                ),
                _SwipeSlotRow(
                  label: 'Right, secondary',
                  slotKey: 'swipe_right_secondary_dropdown',
                  value: swipeConfig.rightSecondary,
                  onChanged: (action) =>
                      ref.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.rightSecondary, action),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
```

Add `final swipeConfig = ref.watch(swipeActionConfigProvider);` next to the existing `final themeMode = ref.watch(themeModeProvider);` line in `build()`.

Add this widget class at the bottom of the file:

```dart
class _SwipeSlotRow extends StatelessWidget {
  const _SwipeSlotRow({
    required this.label,
    required this.slotKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String slotKey;
  final SwipeAction value;
  final ValueChanged<SwipeAction> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        DropdownButton<SwipeAction>(
          key: ValueKey(slotKey),
          value: value,
          items: [
            for (final action in SwipeAction.values)
              DropdownMenuItem(value: action, child: Text(action.label)),
          ],
          onChanged: (action) {
            if (action != null) onChanged(action);
          },
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/widget/settings_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `cd ~/imap_mail && flutter test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/imap_mail
git add lib/screens/settings_screen.dart test/widget/settings_screen_test.dart
git commit -m "feat(swipe): add swipe action customization to Settings"
```

---

### Task 7: Swipe UI in the message list

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/screens/folder_view_screen.dart`
- Modify: `test/widget/folder_view_screen_test.dart`

**Interfaces:**
- Consumes: `swipeActionConfigProvider` (Task 5); `mailRepositoryProvider`, `accountsProvider`, `messagesProvider` (existing); `MailRepository.archiveMessage`/`deleteMessage`/`markFlagged`/`markRead`/`moveMessage` (Task 3).

- [ ] **Step 1: Add `flutter_slidable`**

Run: `cd ~/imap_mail && flutter pub add flutter_slidable`

- [ ] **Step 2: Write the failing test**

Replace `test/widget/folder_view_screen_test.dart` in full:

```dart
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
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/screens/folder_view_screen.dart';

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
  const accountId = 1;
  const account = MailAccount(
    id: accountId,
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
  final inbox = MailFolder(id: 1, accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final sent = MailFolder(id: 2, accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final trash = MailFolder(id: 3, accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final archive = MailFolder(id: 4, accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.other);
  final message = MailMessage(
    id: 100,
    folderId: 1,
    uid: 1,
    subject: 'Hello',
    from: 'a@example.com',
    to: 'me@example.com',
    date: DateTime.utc(2026, 8, 19),
    snippet: 'Hi there',
  );

  setUpAll(() {
    registerFallbackValue(account);
    registerFallbackValue(inbox);
    registerFallbackValue(message);
  });

  testWidgets('shows Inbox/Sent/Trash by default, Archive hidden until expanded', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => const []),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);

    await tester.tap(find.text('More folders'));
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
  });

  testWidgets(
      'expanding many other folders does not overflow the Column or starve '
      'the message list of space', (tester) async {
    final otherFolders = List.generate(
      15,
      (i) => MailFolder(
          id: 10 + i, accountId: accountId, name: 'Custom Folder $i',
          path: 'Custom$i', type: MailFolderType.other),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, ...otherFolders]),
        messagesProvider.overrideWith((ref, folder) async => const []),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More folders'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final listViewBox = tester.renderObject<RenderBox>(find.byType(ListView).last);
    expect(listViewBox.size.height, greaterThan(0));
  });

  testWidgets('shows an error banner with Retry when folders fail to load', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => throw Exception('connection refused')),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('connection refused'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('Edit account opens the form pre-filled for the failed account', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async {
          await ref.watch(accountsProvider.future);
          throw Exception('connection refused');
        }),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Edit account'));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Edit account')), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Add account')), findsNothing);
  });

  testWidgets('a full left-to-right swipe fires the configured left-primary action (Archive)', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.archiveMessage(any(), any(), any()))
        .thenAnswer((_) async => message.copyWith(folderId: 4));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Hello'), const Offset(500, 0));
    await tester.pumpAndSettle();

    verify(() => repository.archiveMessage(account, inbox, message)).called(1);
  });

  testWidgets('tapping the secondary right-side action (Mark read/unread) calls markRead', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.markRead(any(), any(), any(), any())).thenAnswer((_) async {});

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // Partial swipe right-to-left to reveal the end action pane's buttons
    // without crossing the full-swipe dismiss threshold.
    await tester.drag(find.text('Hello'), const Offset(-150, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark read/unread'));
    await tester.pumpAndSettle();

    verify(() => repository.markRead(account, inbox, message, true)).called(1);
  });
}
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `cd ~/imap_mail && flutter test test/widget/folder_view_screen_test.dart`
Expected: the 4 existing tests still pass; the 2 new swipe tests FAIL — no `Slidable`/actions exist in `_MessageList` yet.

- [ ] **Step 4: Add the Slidable-wrapped list and action handling**

Modify `lib/screens/folder_view_screen.dart` — add imports:

```dart
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/swipe_action.dart';
import '../providers/repository_providers.dart';
import '../providers/swipe_action_providers.dart';
```

Replace the `_MessageList` class (current lines 111–143) with:

```dart
class _MessageList extends ConsumerWidget {
  const _MessageList({required this.folder});

  final MailFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(messagesProvider(folder));
    final swipeConfig = ref.watch(swipeActionConfigProvider);

    return messagesAsync.when(
      data: (messages) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(messagesProvider(folder)),
        child: ListView.builder(
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            return Slidable(
              key: ValueKey(message.id),
              startActionPane: _buildActionPane(
                context,
                ref,
                primary: swipeConfig.leftPrimary,
                secondary: swipeConfig.leftSecondary,
                message: message,
              ),
              endActionPane: _buildActionPane(
                context,
                ref,
                primary: swipeConfig.rightPrimary,
                secondary: swipeConfig.rightSecondary,
                message: message,
              ),
              child: MessageListTile(
                message: message,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => MessageDetailScreen(folder: folder, message: message)),
                ),
              ),
            );
          },
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SyncErrorBanner(
        message: error.toString(),
        onRetry: () => ref.invalidate(messagesProvider(folder)),
      ),
    );
  }

  /// Builds one side's ActionPane from its configured primary/secondary
  /// actions. Returns null (no pane — no reveal on that side) if both slots
  /// are SwipeAction.none. A full swipe dismisses using the primary action;
  /// if primary is none but secondary isn't, secondary becomes the dismiss
  /// action too, so a full swipe always does *something* useful when at
  /// least one slot on that side is configured.
  ActionPane? _buildActionPane(
    BuildContext context,
    WidgetRef ref, {
    required SwipeAction primary,
    required SwipeAction secondary,
    required MailMessage message,
  }) {
    final configured = [primary, secondary].where((a) => a != SwipeAction.none).toList();
    if (configured.isEmpty) return null;
    final dismissAction = primary != SwipeAction.none ? primary : secondary;

    return ActionPane(
      motion: const DrawerMotion(),
      dismissible: DismissiblePane(
        onDismissed: () => _performSwipeAction(context, ref, dismissAction, message),
      ),
      children: [
        for (final action in configured)
          SlidableAction(
            onPressed: (_) => _performSwipeAction(context, ref, action, message),
            icon: _iconFor(action),
            label: action.label,
            backgroundColor: _colorFor(action),
          ),
      ],
    );
  }

  IconData _iconFor(SwipeAction action) => switch (action) {
        SwipeAction.archive => Icons.archive_outlined,
        SwipeAction.delete => Icons.delete_outline,
        SwipeAction.flag => Icons.flag_outlined,
        SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
        SwipeAction.none => Icons.block,
      };

  Color _colorFor(SwipeAction action) => switch (action) {
        SwipeAction.archive => Colors.blueGrey,
        SwipeAction.delete => Colors.red,
        SwipeAction.flag => Colors.orange,
        SwipeAction.toggleRead => Colors.teal,
        SwipeAction.none => Colors.grey,
      };

  Future<void> _performSwipeAction(
    BuildContext context,
    WidgetRef ref,
    SwipeAction action,
    MailMessage message,
  ) async {
    if (action == SwipeAction.none) return;
    final repository = await ref.read(mailRepositoryProvider.future);
    final accounts = await ref.read(accountsProvider.future);
    final account = accounts.firstWhere((a) => a.id == folder.accountId);
    try {
      switch (action) {
        case SwipeAction.archive:
          final moved = await repository.archiveMessage(account, folder, message);
          ref.invalidate(messagesProvider(folder));
          _showUndoSnackBar(context, ref, account, folder, moved, 'Archived');
          return;
        case SwipeAction.delete:
          final result = await repository.deleteMessage(account, folder, message);
          ref.invalidate(messagesProvider(folder));
          // Only offer Undo when the message actually moved (a permanent
          // removal — no Trash folder, or already in Trash — can't be
          // undone).
          if (result.folderId != folder.id) {
            _showUndoSnackBar(context, ref, account, folder, result, 'Deleted');
          }
          return;
        case SwipeAction.flag:
          await repository.markFlagged(account, folder, message, !message.isFlagged);
          break;
        case SwipeAction.toggleRead:
          await repository.markRead(account, folder, message, !message.isRead);
          break;
        case SwipeAction.none:
          break;
      }
      ref.invalidate(messagesProvider(folder));
    } catch (e) {
      ref.invalidate(messagesProvider(folder));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Couldn't ${action.label.toLowerCase()} — $e"),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _performSwipeAction(context, ref, action, message),
          ),
        ));
      }
    }
  }

  void _showUndoSnackBar(
    BuildContext context,
    WidgetRef ref,
    MailAccount account,
    MailFolder originalFolder,
    MailMessage movedMessage,
    String verb,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(verb),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          final repository = await ref.read(mailRepositoryProvider.future);
          final folders = await repository.getCachedFolders(originalFolder.accountId);
          final currentFolder = folders.firstWhere((f) => f.id == movedMessage.folderId);
          await repository.moveMessage(account, currentFolder, originalFolder, movedMessage);
          ref.invalidate(messagesProvider(originalFolder));
        },
      ),
    ));
  }
}
```

Note: `Slidable` requires each `DismissiblePane`'s `onDismissed` callback to actually remove the item from the underlying list for the dismiss animation to complete cleanly — here that happens via `ref.invalidate(messagesProvider(folder))` inside `_performSwipeAction`, which re-syncs and re-renders the list without the moved/deleted message (same invalidate-after-mutation pattern `message_detail_screen.dart`'s `_confirmDelete` already uses).

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/imap_mail && flutter test test/widget/folder_view_screen_test.dart`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Run the full suite**

Run: `cd ~/imap_mail && flutter test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd ~/imap_mail
git add pubspec.yaml pubspec.lock lib/screens/folder_view_screen.dart test/widget/folder_view_screen_test.dart
git commit -m "feat(swipe): wire customizable swipe actions into the message list"
```

---

## Self-Review Notes

- **Spec coverage:** data model + Archive folder type (Task 1) → transport (Task 2) → repository optimistic-update/revert including the shared `moveMessage` primitive (Task 3) → fixing the pre-existing caller (Task 4) → `SwipeActionConfig` persistence (Task 5) → Settings customization UI (Task 6) → the actual swipe UI, full-swipe auto-trigger, partial-swipe tap, and Undo (Task 7). All spec sections have a task. The spec's "Undo moves back to the originating folder, not hardcoded to Inbox" requirement (added during the spec's own self-review) is implemented via `_showUndoSnackBar` capturing `originalFolder` and `MailRepository.moveMessage`'s generic `(from, to)` shape rather than any Inbox-specific logic.
- **Placeholder scan:** none — every step has runnable code. One thing flagged inline rather than silently fixed: Task 1's `AppDatabase` full-file replacement calls out a copy-paste trap (`smtp_port` column type) explicitly so it isn't introduced by accident.
- **Type consistency:** `moveMessage`/`archiveMessage`/`deleteMessage` all return `Future<MailMessage>` consistently from Task 3 onward, and Task 7's `_performSwipeAction`/`_showUndoSnackBar` use that returned value (not the pre-swipe `message` object) for the Undo call — this matters because the server assigns a new UID on move, and using a stale UID for Undo would address the wrong message. `SwipeAction`/`SwipeSlot`/`SwipeActionConfig` names and shapes introduced in Task 5 are used identically in Tasks 6 and 7.
- **A correctness point resolved during planning, worth restating:** `MessageDao.moveToFolder`'s pre-existing synthetic-negative-UID placeholder is necessary for the optimistic (pre-server-confirmation) step of every move, but is not what Undo should ever use to address a message. Task 3's `moveMessage` corrects the local UID once the server responds (`if (newUid != null) { ...moveToFolder(..., newUid: newUid) }`) and returns the corrected `MailMessage`, and Task 7 threads that returned value through to the Undo snackbar instead of the original pre-swipe message object.
