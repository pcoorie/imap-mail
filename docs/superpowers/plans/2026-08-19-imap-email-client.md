# IMAP Email Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a simple multi-account IMAP/SMTP email client in Flutter — manual account setup, Inbox/Sent/Trash + expandable full folder tree, read with attachment download, compose/reply/forward with attach + send, local sqflite cache for offline viewing, credentials in platform secure storage, foreground-only sync.

**Architecture:** Four layers — UI screens → Riverpod providers → Repository (cache-first, orchestrates local store + mail transport) → `LocalStore` (sqflite DAOs) / `SecureCredentialStore` (flutter_secure_storage) / `MailTransport` + `MailSender` (interfaces wrapping `enough_mail`, concrete impls injectable for testing).

**Tech Stack:** Flutter, Dart, `enough_mail` (IMAP/SMTP), `flutter_riverpod` (state), `sqflite` (local cache), `flutter_secure_storage` (credentials), `equatable` (value equality), `flutter_widget_from_html` (HTML rendering), `file_picker` (attachments), `mocktail` + `sqflite_common_ffi` (testing).

## Global Constraints

- No OAuth, no provider-specific APIs — IMAP/SMTP only, manual server configuration per the approved spec (`docs/superpowers/specs/2026-08-19-imap-email-client-design.md`).
- Passwords are never stored in sqlite or logged — `SecureCredentialStore` only.
- Sync is foreground-only (app open / manual refresh) — no background services, no push notifications.
- Default folder UI shows Inbox/Sent/Trash; full folder tree behind an expandable "More folders" control.
- `ImapService`/`SmtpService` (here: `MailTransport`/`MailSender`) are mocked at their interface boundary in tests — no test suite makes real network connections.
- Package name is `imap_mail`; all lib imports use `package:imap_mail/...`.

---

## File Structure

```
lib/
  models/
    enums.dart                  # MailSecurity, MailFolderType, MailSendStatus
    mail_account.dart
    mail_folder.dart
    mail_message.dart
    mail_attachment.dart
  data/
    local/
      app_database.dart         # schema + open()
      account_dao.dart
      folder_dao.dart
      message_dao.dart
      attachment_dao.dart
    secure/
      credential_store.dart
    transport/
      mail_transport.dart       # abstract interface
      mail_sender.dart          # abstract interface
      mail_message_mapper.dart  # MimeMessage <-> MailMessage pure functions
      enough_mail_transport.dart
      enough_mail_sender.dart
    repository/
      account_repository.dart
      mail_repository.dart
  providers/
    database_providers.dart
    account_providers.dart
    folder_providers.dart
    message_providers.dart
    compose_providers.dart
  screens/
    account_list_screen.dart
    account_form_screen.dart
    folder_view_screen.dart
    message_detail_screen.dart
    compose_screen.dart
    settings_screen.dart
  widgets/
    folder_tab_bar.dart
    folder_tree_expander.dart
    message_list_tile.dart
    attachment_tile.dart
    sync_error_banner.dart
  app.dart
  main.dart
test/
  models/models_test.dart
  data/local/account_dao_test.dart
  data/local/folder_message_dao_test.dart
  data/local/attachment_dao_test.dart
  data/secure/credential_store_test.dart
  data/transport/mail_message_mapper_test.dart
  data/transport/mail_sender_test.dart
  data/repository/account_repository_test.dart
  data/repository/mail_repository_test.dart
  providers/providers_test.dart
  widget/account_form_screen_test.dart
  widget/folder_view_screen_test.dart
  widget/message_detail_screen_test.dart
  widget/compose_screen_test.dart
  widget/settings_screen_test.dart
  widget/app_smoke_test.dart
```

---

### Task 1: Dependencies and domain models

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/models/enums.dart`, `lib/models/mail_account.dart`, `lib/models/mail_folder.dart`, `lib/models/mail_message.dart`, `lib/models/mail_attachment.dart`
- Test: `test/models/models_test.dart`

**Interfaces:**
- Produces: `MailSecurity {none, ssl, startTls}`, `MailFolderType {inbox, sent, trash, other}`, `MailSendStatus {none, sent, failed}`; `MailAccount`, `MailFolder`, `MailMessage`, `MailAttachment` — each `Equatable`, with `toMap()`/`fromMap(Map<String, Object?>)` and `copyWith(...)`. All `id` fields are `int?` (null until persisted).

- [ ] **Step 1: Add runtime and dev dependencies**

Run:
```bash
cd ~/imap_mail
flutter pub add equatable flutter_riverpod sqflite path_provider path flutter_secure_storage enough_mail flutter_widget_from_html file_picker
flutter pub add --dev sqflite_common_ffi mocktail
```

- [ ] **Step 2: Write the failing model tests**

```dart
// test/models/models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/mail_attachment.dart';

void main() {
  group('MailAccount', () {
    test('round-trips through toMap/fromMap', () {
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
      final restored = MailAccount.fromMap(account.toMap());
      expect(restored, account);
    });

    test('copyWith overrides only given fields', () {
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
      final renamed = account.copyWith(displayName: 'Personal');
      expect(renamed.displayName, 'Personal');
      expect(renamed.email, account.email);
    });
  });

  group('MailFolder', () {
    test('round-trips through toMap/fromMap including isLocalOnly', () {
      const folder = MailFolder(
        id: 5,
        accountId: 1,
        name: 'Outbox',
        path: 'Outbox',
        type: MailFolderType.other,
        unreadCount: 0,
        isLocalOnly: true,
      );
      expect(MailFolder.fromMap(folder.toMap()), folder);
    });
  });

  group('MailMessage', () {
    test('round-trips through toMap/fromMap including date and flags', () {
      final message = MailMessage(
        id: 10,
        folderId: 5,
        uid: 42,
        subject: 'Hello',
        from: 'a@example.com',
        to: 'b@example.com',
        date: DateTime.utc(2026, 8, 19, 12, 0),
        snippet: 'Hi there',
        bodyText: 'Hi there, full body',
        bodyHtml: null,
        isRead: true,
        isDownloaded: true,
        sendStatus: MailSendStatus.none,
      );
      expect(MailMessage.fromMap(message.toMap()), message);
    });
  });

  group('MailAttachment', () {
    test('round-trips through toMap/fromMap', () {
      const attachment = MailAttachment(
        id: 3,
        messageId: 10,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 1024,
        localPath: null,
      );
      expect(MailAttachment.fromMap(attachment.toMap()), attachment);
    });
  });
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/models/models_test.dart`
Expected: FAIL — files under `lib/models/` don't exist yet.

- [ ] **Step 4: Implement the enums**

```dart
// lib/models/enums.dart
enum MailSecurity { none, ssl, startTls }

enum MailFolderType { inbox, sent, trash, other }

enum MailSendStatus { none, sent, failed }
```

- [ ] **Step 5: Implement MailAccount**

```dart
// lib/models/mail_account.dart
import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailAccount extends Equatable {
  const MailAccount({
    this.id,
    required this.displayName,
    required this.email,
    required this.imapHost,
    required this.imapPort,
    required this.imapSecurity,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSecurity,
    required this.username,
  });

  final int? id;
  final String displayName;
  final String email;
  final String imapHost;
  final int imapPort;
  final MailSecurity imapSecurity;
  final String smtpHost;
  final int smtpPort;
  final MailSecurity smtpSecurity;
  final String username;

  MailAccount copyWith({
    int? id,
    String? displayName,
    String? email,
    String? imapHost,
    int? imapPort,
    MailSecurity? imapSecurity,
    String? smtpHost,
    int? smtpPort,
    MailSecurity? smtpSecurity,
    String? username,
  }) {
    return MailAccount(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      imapSecurity: imapSecurity ?? this.imapSecurity,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpSecurity: smtpSecurity ?? this.smtpSecurity,
      username: username ?? this.username,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'display_name': displayName,
      'email': email,
      'imap_host': imapHost,
      'imap_port': imapPort,
      'imap_security': imapSecurity.name,
      'smtp_host': smtpHost,
      'smtp_port': smtpPort,
      'smtp_security': smtpSecurity.name,
      'username': username,
    };
  }

  factory MailAccount.fromMap(Map<String, Object?> map) {
    return MailAccount(
      id: map['id'] as int?,
      displayName: map['display_name'] as String,
      email: map['email'] as String,
      imapHost: map['imap_host'] as String,
      imapPort: map['imap_port'] as int,
      imapSecurity: MailSecurity.values.byName(map['imap_security'] as String),
      smtpHost: map['smtp_host'] as String,
      smtpPort: map['smtp_port'] as int,
      smtpSecurity: MailSecurity.values.byName(map['smtp_security'] as String),
      username: map['username'] as String,
    );
  }

  @override
  List<Object?> get props => [
        id,
        displayName,
        email,
        imapHost,
        imapPort,
        imapSecurity,
        smtpHost,
        smtpPort,
        smtpSecurity,
        username,
      ];
}
```

- [ ] **Step 6: Implement MailFolder**

```dart
// lib/models/mail_folder.dart
import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailFolder extends Equatable {
  const MailFolder({
    this.id,
    required this.accountId,
    required this.name,
    required this.path,
    required this.type,
    this.unreadCount = 0,
    this.isLocalOnly = false,
  });

  final int? id;
  final int accountId;
  final String name;
  final String path;
  final MailFolderType type;
  final int unreadCount;
  final bool isLocalOnly;

  MailFolder copyWith({
    int? id,
    int? accountId,
    String? name,
    String? path,
    MailFolderType? type,
    int? unreadCount,
    bool? isLocalOnly,
  }) {
    return MailFolder(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      path: path ?? this.path,
      type: type ?? this.type,
      unreadCount: unreadCount ?? this.unreadCount,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'account_id': accountId,
      'name': name,
      'path': path,
      'type': type.name,
      'unread_count': unreadCount,
      'is_local_only': isLocalOnly ? 1 : 0,
    };
  }

  factory MailFolder.fromMap(Map<String, Object?> map) {
    return MailFolder(
      id: map['id'] as int?,
      accountId: map['account_id'] as int,
      name: map['name'] as String,
      path: map['path'] as String,
      type: MailFolderType.values.byName(map['type'] as String),
      unreadCount: map['unread_count'] as int,
      isLocalOnly: (map['is_local_only'] as int) == 1,
    );
  }

  @override
  List<Object?> get props =>
      [id, accountId, name, path, type, unreadCount, isLocalOnly];
}
```

- [ ] **Step 7: Implement MailMessage**

```dart
// lib/models/mail_message.dart
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
        isDownloaded,
        sendStatus,
      ];
}
```

- [ ] **Step 8: Implement MailAttachment**

```dart
// lib/models/mail_attachment.dart
import 'package:equatable/equatable.dart';

class MailAttachment extends Equatable {
  const MailAttachment({
    this.id,
    required this.messageId,
    required this.filename,
    required this.mimeType,
    required this.size,
    this.localPath,
  });

  final int? id;
  final int messageId;
  final String filename;
  final String mimeType;
  final int size;
  final String? localPath;

  MailAttachment copyWith({
    int? id,
    int? messageId,
    String? filename,
    String? mimeType,
    int? size,
    String? localPath,
  }) {
    return MailAttachment(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      filename: filename ?? this.filename,
      mimeType: mimeType ?? this.mimeType,
      size: size ?? this.size,
      localPath: localPath ?? this.localPath,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'message_id': messageId,
      'filename': filename,
      'mime_type': mimeType,
      'size': size,
      'local_path': localPath,
    };
  }

  factory MailAttachment.fromMap(Map<String, Object?> map) {
    return MailAttachment(
      id: map['id'] as int?,
      messageId: map['message_id'] as int,
      filename: map['filename'] as String,
      mimeType: map['mime_type'] as String,
      size: map['size'] as int,
      localPath: map['local_path'] as String?,
    );
  }

  @override
  List<Object?> get props =>
      [id, messageId, filename, mimeType, size, localPath];
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `flutter test test/models/models_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 10: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/models test/models
git commit -m "feat: add dependencies and domain models"
```

---

### Task 2: Local database schema + AccountDao

**Files:**
- Create: `lib/data/local/app_database.dart`, `lib/data/local/account_dao.dart`
- Test: `test/data/local/account_dao_test.dart`

**Interfaces:**
- Consumes: `MailAccount` (Task 1)
- Produces: `AppDatabase.onCreate(Database db, int version)`, `AppDatabase.open() -> Future<Database>` (real app path via `path_provider`), `AccountDao(Database db)` with `Future<int> insert(MailAccount account)`, `Future<void> update(MailAccount account)`, `Future<void> delete(int id)`, `Future<List<MailAccount>> getAll()`, `Future<MailAccount?> getById(int id)`.

- [ ] **Step 1: Write the failing DAO test**

```dart
// test/data/local/account_dao_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

void main() {
  late Database db;
  late AccountDao dao;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: AppDatabase.onCreate,
      ),
    );
    dao = AccountDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  const account = MailAccount(
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

  test('insert assigns an id and getById returns the same account', () async {
    final id = await dao.insert(account);
    expect(id, greaterThan(0));

    final fetched = await dao.getById(id);
    expect(fetched, account.copyWith(id: id));
  });

  test('getAll returns all inserted accounts', () async {
    await dao.insert(account);
    await dao.insert(account.copyWith(displayName: 'Personal', email: 'p@example.com'));

    final all = await dao.getAll();
    expect(all, hasLength(2));
  });

  test('update persists changed fields', () async {
    final id = await dao.insert(account);
    await dao.update(account.copyWith(id: id, displayName: 'Renamed'));

    final fetched = await dao.getById(id);
    expect(fetched!.displayName, 'Renamed');
  });

  test('delete removes the account', () async {
    final id = await dao.insert(account);
    await dao.delete(id);

    expect(await dao.getById(id), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/local/account_dao_test.dart`
Expected: FAIL — `lib/data/local/app_database.dart` doesn't exist yet.

- [ ] **Step 3: Implement AppDatabase schema**

```dart
// lib/data/local/app_database.dart
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
        smtp_port INTEGER NOT NULL,
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
        local_path TEXT
      )
    ''');
  }

  static Future<Database> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'imap_mail.db');
    return openDatabase(path, version: 1, onCreate: onCreate);
  }
}
```

- [ ] **Step 4: Implement AccountDao**

```dart
// lib/data/local/account_dao.dart
import 'package:sqflite/sqflite.dart';
import '../../models/mail_account.dart';

class AccountDao {
  AccountDao(this._db);

  final Database _db;

  Future<int> insert(MailAccount account) async {
    final map = account.toMap()..remove('id');
    return _db.insert('accounts', map);
  }

  Future<void> update(MailAccount account) async {
    await _db.update(
      'accounts',
      account.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [account.id],
    );
  }

  Future<void> delete(int id) async {
    await _db.delete('accounts', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<MailAccount>> getAll() async {
    final rows = await _db.query('accounts', orderBy: 'display_name ASC');
    return rows.map(MailAccount.fromMap).toList();
  }

  Future<MailAccount?> getById(int id) async {
    final rows = await _db.query('accounts', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MailAccount.fromMap(rows.first);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/data/local/account_dao_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/data/local/app_database.dart lib/data/local/account_dao.dart test/data/local/account_dao_test.dart
git commit -m "feat: add local database schema and AccountDao"
```

---

### Task 3: FolderDao + MessageDao

**Files:**
- Create: `lib/data/local/folder_dao.dart`, `lib/data/local/message_dao.dart`
- Test: `test/data/local/folder_message_dao_test.dart`

**Interfaces:**
- Consumes: `AppDatabase.onCreate` (Task 2), `MailFolder`/`MailMessage` (Task 1)
- Produces: `FolderDao(Database db)` — `Future<int> upsert(MailFolder folder)` (insert-or-update keyed by `(accountId, path)`), `Future<List<MailFolder>> getForAccount(int accountId)`, `Future<MailFolder?> getById(int id)`, `Future<void> updateUnreadCount(int id, int count)`.
  `MessageDao(Database db)` — `Future<void> upsertHeaders(List<MailMessage> messages)` (insert-or-replace keyed by `(folderId, uid)`), `Future<int> insertLocal(MailMessage message)` (for Outbox items), `Future<List<MailMessage>> getForFolder(int folderId)` (newest first), `Future<MailMessage?> getById(int id)`, `Future<void> updateBody(int id, {String? bodyText, String? bodyHtml})`, `Future<void> updateSendStatus(int id, MailSendStatus status)`, `Future<int> getMaxUid(int folderId)` (0 if none).

- [ ] **Step 1: Write the failing DAO tests**

```dart
// test/data/local/folder_message_dao_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';

void main() {
  late Database db;
  late FolderDao folderDao;
  late MessageDao messageDao;
  late int accountId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
    );
    folderDao = FolderDao(db);
    messageDao = MessageDao(db);
    accountId = await AccountDao(db).insert(const MailAccount(
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    ));
  });

  tearDown(() async => db.close());

  group('FolderDao', () {
    test('upsert inserts then updates the same folder by (accountId, path)', () async {
      final folder = MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      );
      final id1 = await folderDao.upsert(folder);
      final id2 = await folderDao.upsert(folder.copyWith(unreadCount: 3));

      expect(id2, id1);
      final fetched = await folderDao.getById(id1);
      expect(fetched!.unreadCount, 3);
    });

    test('getForAccount returns only that account\'s folders', () async {
      await folderDao.upsert(MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      ));
      final folders = await folderDao.getForAccount(accountId);
      expect(folders, hasLength(1));
      expect(folders.first.name, 'INBOX');
    });
  });

  group('MessageDao', () {
    late int folderId;

    setUp(() async {
      folderId = await folderDao.upsert(MailFolder(
        accountId: accountId,
        name: 'INBOX',
        path: 'INBOX',
        type: MailFolderType.inbox,
      ));
    });

    MailMessage sampleMessage(int uid) => MailMessage(
          folderId: folderId,
          uid: uid,
          subject: 'Subject $uid',
          from: 'a@example.com',
          to: 'me@example.com',
          date: DateTime.utc(2026, 8, 19),
          snippet: 'snippet',
        );

    test('upsertHeaders inserts new and replaces existing by (folderId, uid)', () async {
      await messageDao.upsertHeaders([sampleMessage(1), sampleMessage(2)]);
      await messageDao.upsertHeaders([sampleMessage(1).copyWith(isRead: true)]);

      final messages = await messageDao.getForFolder(folderId);
      expect(messages, hasLength(2));
      expect(messages.firstWhere((m) => m.uid == 1).isRead, isTrue);
    });

    test('getMaxUid returns 0 when folder is empty, else the highest uid', () async {
      expect(await messageDao.getMaxUid(folderId), 0);
      await messageDao.upsertHeaders([sampleMessage(1), sampleMessage(5)]);
      expect(await messageDao.getMaxUid(folderId), 5);
    });

    test('updateBody sets bodyText/bodyHtml', () async {
      await messageDao.upsertHeaders([sampleMessage(1)]);
      final id = (await messageDao.getForFolder(folderId)).first.id!;

      await messageDao.updateBody(id, bodyText: 'full body', bodyHtml: null);

      final updated = await messageDao.getById(id);
      expect(updated!.bodyText, 'full body');
      expect(updated.isDownloaded, isFalse); // updateBody doesn't imply downloaded flag by itself
    });

    test('insertLocal creates a message not tied to a synced uid', () async {
      final id = await messageDao.insertLocal(sampleMessage(0).copyWith(
        sendStatus: MailSendStatus.failed,
      ));
      final fetched = await messageDao.getById(id);
      expect(fetched!.sendStatus, MailSendStatus.failed);
    });

    test('updateSendStatus updates the flag', () async {
      final id = await messageDao.insertLocal(sampleMessage(0));
      await messageDao.updateSendStatus(id, MailSendStatus.sent);
      expect((await messageDao.getById(id))!.sendStatus, MailSendStatus.sent);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/data/local/folder_message_dao_test.dart`
Expected: FAIL — `folder_dao.dart`/`message_dao.dart` don't exist.

- [ ] **Step 3: Implement FolderDao**

```dart
// lib/data/local/folder_dao.dart
import 'package:sqflite/sqflite.dart';
import '../../models/mail_folder.dart';

class FolderDao {
  FolderDao(this._db);

  final Database _db;

  Future<int> upsert(MailFolder folder) async {
    final existing = await _db.query(
      'folders',
      where: 'account_id = ? AND path = ?',
      whereArgs: [folder.accountId, folder.path],
    );
    if (existing.isEmpty) {
      final map = folder.toMap()..remove('id');
      return _db.insert('folders', map);
    }
    final id = existing.first['id'] as int;
    await _db.update(
      'folders',
      folder.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<List<MailFolder>> getForAccount(int accountId) async {
    final rows = await _db.query(
      'folders',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'name ASC',
    );
    return rows.map(MailFolder.fromMap).toList();
  }

  Future<MailFolder?> getById(int id) async {
    final rows = await _db.query('folders', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MailFolder.fromMap(rows.first);
  }

  Future<void> updateUnreadCount(int id, int count) async {
    await _db.update(
      'folders',
      {'unread_count': count},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
```

- [ ] **Step 4: Implement MessageDao**

```dart
// lib/data/local/message_dao.dart
import 'package:sqflite/sqflite.dart';
import '../../models/enums.dart';
import '../../models/mail_message.dart';

class MessageDao {
  MessageDao(this._db);

  final Database _db;

  Future<void> upsertHeaders(List<MailMessage> messages) async {
    final batch = _db.batch();
    for (final message in messages) {
      final map = message.toMap()..remove('id');
      batch.insert('messages', map, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<int> insertLocal(MailMessage message) async {
    final map = message.toMap()..remove('id');
    return _db.insert('messages', map);
  }

  Future<List<MailMessage>> getForFolder(int folderId) async {
    final rows = await _db.query(
      'messages',
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: 'date DESC',
    );
    return rows.map(MailMessage.fromMap).toList();
  }

  Future<MailMessage?> getById(int id) async {
    final rows = await _db.query('messages', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return MailMessage.fromMap(rows.first);
  }

  Future<void> updateBody(int id, {String? bodyText, String? bodyHtml}) async {
    await _db.update(
      'messages',
      {
        'body_text': bodyText,
        'body_html': bodyHtml,
        'is_downloaded': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSendStatus(int id, MailSendStatus status) async {
    await _db.update(
      'messages',
      {'send_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> getMaxUid(int folderId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(uid) as max_uid FROM messages WHERE folder_id = ?',
      [folderId],
    );
    final value = rows.first['max_uid'];
    return value == null ? 0 : value as int;
  }
}
```

Note: Step 3 test `updateBody` above expects `isDownloaded` to end up `false` — that's wrong given the implementation always sets `is_downloaded: 1`. Fix the test assertion instead of the implementation: `updateBody` is only ever called after a successful body fetch, so it should mark the message downloaded. Change the test assertion to `expect(updated.isDownloaded, isTrue);` before running Step 5.

- [ ] **Step 5: Fix the test assertion noted above, then run tests to verify they pass**

Run: `flutter test test/data/local/folder_message_dao_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/data/local/folder_dao.dart lib/data/local/message_dao.dart test/data/local/folder_message_dao_test.dart
git commit -m "feat: add FolderDao and MessageDao"
```

---

### Task 4: AttachmentDao

**Files:**
- Create: `lib/data/local/attachment_dao.dart`
- Test: `test/data/local/attachment_dao_test.dart`

**Interfaces:**
- Consumes: `AppDatabase.onCreate`, `MessageDao` (Task 3), `MailAttachment` (Task 1)
- Produces: `AttachmentDao(Database db)` — `Future<void> insertAll(List<MailAttachment> attachments)`, `Future<List<MailAttachment>> getForMessage(int messageId)`, `Future<void> updateLocalPath(int id, String localPath)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/data/local/attachment_dao_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/mail_attachment.dart';

void main() {
  late Database db;
  late AttachmentDao dao;
  late int messageId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
    );
    dao = AttachmentDao(db);

    final accountId = await AccountDao(db).insert(const MailAccount(
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    ));
    final folderId = await FolderDao(db).upsert(MailFolder(
      accountId: accountId,
      name: 'INBOX',
      path: 'INBOX',
      type: MailFolderType.inbox,
    ));
    await MessageDao(db).upsertHeaders([
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
    messageId = (await MessageDao(db).getForFolder(folderId)).first.id!;
  });

  tearDown(() async => db.close());

  test('insertAll then getForMessage returns them', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);

    final attachments = await dao.getForMessage(messageId);
    expect(attachments, hasLength(1));
    expect(attachments.first.filename, 'report.pdf');
    expect(attachments.first.localPath, isNull);
  });

  test('updateLocalPath sets the downloaded file path', () async {
    await dao.insertAll([
      MailAttachment(
        messageId: messageId,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 2048,
      ),
    ]);
    final id = (await dao.getForMessage(messageId)).first.id!;

    await dao.updateLocalPath(id, '/tmp/report.pdf');

    final updated = await dao.getForMessage(messageId);
    expect(updated.first.localPath, '/tmp/report.pdf');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/local/attachment_dao_test.dart`
Expected: FAIL — `attachment_dao.dart` doesn't exist.

- [ ] **Step 3: Implement AttachmentDao**

```dart
// lib/data/local/attachment_dao.dart
import 'package:sqflite/sqflite.dart';
import '../../models/mail_attachment.dart';

class AttachmentDao {
  AttachmentDao(this._db);

  final Database _db;

  Future<void> insertAll(List<MailAttachment> attachments) async {
    final batch = _db.batch();
    for (final attachment in attachments) {
      batch.insert('attachments', attachment.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  Future<List<MailAttachment>> getForMessage(int messageId) async {
    final rows = await _db.query(
      'attachments',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return rows.map(MailAttachment.fromMap).toList();
  }

  Future<void> updateLocalPath(int id, String localPath) async {
    await _db.update(
      'attachments',
      {'local_path': localPath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/local/attachment_dao_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/data/local/attachment_dao.dart test/data/local/attachment_dao_test.dart
git commit -m "feat: add AttachmentDao"
```

---

### Task 5: SecureCredentialStore

**Files:**
- Create: `lib/data/secure/credential_store.dart`
- Test: `test/data/secure/credential_store_test.dart`

**Interfaces:**
- Produces: `SecureCredentialStore` — `Future<void> savePassword({required int accountId, required String password})`, `Future<String?> getPassword(int accountId)`, `Future<void> deletePassword(int accountId)`.

- [ ] **Step 1: Write the failing test (mocking the platform channel)**

```dart
// test/data/secure/credential_store_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/secure/credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final storage = <String, String>{};

  setUp(() {
    storage.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'write':
          storage[call.arguments['key'] as String] = call.arguments['value'] as String;
          return null;
        case 'read':
          return storage[call.arguments['key'] as String];
        case 'delete':
          storage.remove(call.arguments['key'] as String);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('savePassword then getPassword returns it', () async {
    final store = SecureCredentialStore();
    await store.savePassword(accountId: 1, password: 'app-password');

    expect(await store.getPassword(1), 'app-password');
  });

  test('getPassword returns null when nothing saved', () async {
    final store = SecureCredentialStore();
    expect(await store.getPassword(99), isNull);
  });

  test('deletePassword removes it', () async {
    final store = SecureCredentialStore();
    await store.savePassword(accountId: 1, password: 'app-password');
    await store.deletePassword(1);

    expect(await store.getPassword(1), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/secure/credential_store_test.dart`
Expected: FAIL — `credential_store.dart` doesn't exist.

- [ ] **Step 3: Implement SecureCredentialStore**

```dart
// lib/data/secure/credential_store.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureCredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _keyFor(int accountId) => 'account_password_$accountId';

  Future<void> savePassword({required int accountId, required String password}) {
    return _storage.write(key: _keyFor(accountId), value: password);
  }

  Future<String?> getPassword(int accountId) {
    return _storage.read(key: _keyFor(accountId));
  }

  Future<void> deletePassword(int accountId) {
    return _storage.delete(key: _keyFor(accountId));
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/data/secure/credential_store_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/data/secure/credential_store.dart test/data/secure/credential_store_test.dart
git commit -m "feat: add SecureCredentialStore"
```

---

### Task 6: MailTransport interface + mapping logic + enough_mail-backed implementation

**Files:**
- Create: `lib/data/transport/mail_transport.dart`, `lib/data/transport/mail_message_mapper.dart`, `lib/data/transport/enough_mail_transport.dart`
- Test: `test/data/transport/mail_message_mapper_test.dart`

**Interfaces:**
- Consumes: `MailAccount`, `MailFolder`, `MailMessage`, `MailAttachment`, `MailSecurity`, `MailFolderType` (Task 1)
- Produces:
  - `abstract class MailTransport { Future<void> testConnection(MailAccount account, String password); Future<List<MailFolder>> discoverFolders(MailAccount account, String password, int accountId); Future<List<MailMessage>> fetchHeadersSince(MailAccount account, String password, MailFolder folder, int sinceUid); Future<MailMessage> fetchBody(MailAccount account, String password, MailFolder folder, MailMessage message); Future<List<int>> fetchAttachmentBytes(MailAccount account, String password, MailFolder folder, MailMessage message, MailAttachment attachment); }`
  - `MailMessage mapMimeMessageToRecord(MimeMessage mime, {required int folderId})` (pure function, unit tested directly)
  - `EnoughMailTransport implements MailTransport` — real IMAP implementation. **This class's network-calling methods are integration-only and are not covered by the automated test suite** (per spec Testing Strategy — `MailTransport` is mocked at the interface boundary in repository tests). Only `mapMimeMessageToRecord` gets direct unit tests here, since it needs no network. Verify `EnoughMailTransport` manually against a real IMAP account before relying on it (see Task 6 Step 6).
  - Note on `enough_mail` API surface used: `MimeMessage`/`MessageBuilder` construction is stable across recent versions; the exact `MessageSequence`/`fetchMessageSequence` call used for delta sync in `fetchHeadersSince` should be checked against the installed `enough_mail` version's dartdoc (`dart doc` or pub.dev) since IMAP client method signatures have shifted between major versions — this is the one place in the codebase where third-party API drift is a real risk, precisely because it's not exercised by the unit test suite.

- [ ] **Step 1: Add the `collection` dependency (needed by `EnoughMailTransport`'s attachment lookup later in this task)**

Run:
```bash
cd ~/imap_mail
flutter pub add collection
```

- [ ] **Step 2: Write the failing mapper test**

```dart
// test/data/transport/mail_message_mapper_test.dart
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_message_mapper.dart';

void main() {
  test('maps a plain-text MimeMessage to a MailMessage record', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Hello'
      ..text = 'Hi Bob, this is the body.';
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.folderId, 7);
    expect(message.subject, 'Hello');
    expect(message.from, contains('alice@example.com'));
    expect(message.bodyText, contains('Hi Bob'));
    expect(message.bodyHtml, isNull);
  });

  test('maps an HTML MimeMessage, preferring HTML for snippet source', () {
    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', 'alice@example.com')]
      ..to = [MailAddress('Bob', 'bob@example.com')]
      ..subject = 'Report'
      ..addMultipartAlternative(
        plainText: 'Plain body',
        htmlText: '<p>HTML body</p>',
      );
    final mime = builder.buildMimeMessage();

    final message = mapMimeMessageToRecord(mime, folderId: 7);

    expect(message.bodyHtml, contains('HTML body'));
    expect(message.bodyText, contains('Plain body'));
    expect(message.snippet, isNotEmpty);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/data/transport/mail_message_mapper_test.dart`
Expected: FAIL — `mail_message_mapper.dart` doesn't exist.

- [ ] **Step 4: Implement the mapper**

```dart
// lib/data/transport/mail_message_mapper.dart
import 'package:enough_mail/enough_mail.dart';
import '../../models/mail_message.dart';

MailMessage mapMimeMessageToRecord(MimeMessage mime, {required int folderId}) {
  final bodyText = mime.decodeTextPlainPart();
  final bodyHtml = mime.decodeTextHtmlPart();
  final snippetSource = bodyText ?? _stripHtml(bodyHtml ?? '');
  final snippet = snippetSource.trim().length > 140
      ? '${snippetSource.trim().substring(0, 140)}...'
      : snippetSource.trim();

  return MailMessage(
    folderId: folderId,
    uid: mime.uid ?? 0,
    subject: mime.decodeSubject() ?? '(no subject)',
    from: mime.from?.map((a) => a.email).join(', ') ?? '',
    to: mime.to?.map((a) => a.email).join(', ') ?? '',
    date: mime.decodeDate() ?? DateTime.now().toUtc(),
    snippet: snippet,
    bodyText: bodyText,
    bodyHtml: bodyHtml,
    isRead: mime.isSeen,
    isDownloaded: bodyText != null || bodyHtml != null,
  );
}

String _stripHtml(String html) => html.replaceAll(RegExp('<[^>]*>'), '');
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/data/transport/mail_message_mapper_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 6: Define the MailTransport interface**

```dart
// lib/data/transport/mail_transport.dart
import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';

abstract class MailTransport {
  Future<void> testConnection(MailAccount account, String password);

  Future<List<MailFolder>> discoverFolders(
    MailAccount account,
    String password,
    int accountId,
  );

  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  );

  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  );

  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  );
}
```

- [ ] **Step 7: Implement EnoughMailTransport**

```dart
// lib/data/transport/enough_mail_transport.dart
import 'package:enough_mail/enough_mail.dart' as enough;
import '../../models/enums.dart';
import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';
import 'mail_message_mapper.dart';
import 'mail_transport.dart';

// NOTE: both our own domain model and enough_mail export a class named
// `MailAccount`. The enough_mail import is aliased to `enough` throughout
// this file specifically to keep that unambiguous — do not remove the alias.
class EnoughMailTransport implements MailTransport {
  enough.MailAccount _toEnoughAccount(MailAccount account, String password) {
    return enough.MailAccount.fromManualSettings(
      name: account.displayName,
      email: account.email,
      incomingHost: account.imapHost,
      incomingPort: account.imapPort,
      incomingSocketType: _toSocketType(account.imapSecurity),
      outgoingHost: account.smtpHost,
      outgoingPort: account.smtpPort,
      outgoingSocketType: _toSocketType(account.smtpSecurity),
      password: password,
      userName: account.displayName,
      loginName: account.username,
    );
  }

  enough.SocketType _toSocketType(MailSecurity security) {
    switch (security) {
      case MailSecurity.ssl:
        return enough.SocketType.ssl;
      case MailSecurity.startTls:
        return enough.SocketType.starttls;
      case MailSecurity.none:
        return enough.SocketType.plain;
    }
  }

  @override
  Future<void> testConnection(MailAccount account, String password) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<List<MailFolder>> discoverFolders(
    MailAccount account,
    String password,
    int accountId,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      final mailboxes = await client.listMailboxes();
      return mailboxes.map((box) {
        return MailFolder(
          accountId: accountId,
          name: box.name,
          path: box.path,
          type: _folderTypeFor(box),
        );
      }).toList();
    } finally {
      await client.disconnect();
    }
  }

  MailFolderType _folderTypeFor(enough.Mailbox box) {
    if (box.isInbox) return MailFolderType.inbox;
    if (box.isSent) return MailFolderType.sent;
    if (box.isTrash) return MailFolderType.trash;
    return MailFolderType.other;
  }

  @override
  Future<List<MailMessage>> fetchHeadersSince(
    MailAccount account,
    String password,
    MailFolder folder,
    int sinceUid,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      // NOTE: verify this call against the installed enough_mail version's
      // MessageSequence API (see interface doc comment in mail_transport.dart) —
      // intent is "all UIDs greater than sinceUid in this mailbox".
      final sequence = enough.MessageSequence.fromRangeToLast(sinceUid + 1, isUidSequence: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.envelope,
      );
      return mimeMessages
          .map((mime) => mapMimeMessageToRecord(mime, folderId: folder.id!))
          .toList();
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<MailMessage> fetchBody(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.full,
      );
      return mapMimeMessageToRecord(mimeMessages.first, folderId: folder.id!)
          .copyWith(id: message.id);
    } finally {
      await client.disconnect();
    }
  }

  @override
  Future<List<int>> fetchAttachmentBytes(
    MailAccount account,
    String password,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async {
    final client = enough.MailClient(_toEnoughAccount(account, password));
    try {
      await client.connect();
      await client.selectMailboxByPath(folder.path);
      final sequence = enough.MessageSequence.fromId(message.uid, isUid: true);
      final mimeMessages = await client.fetchMessageSequence(
        sequence,
        fetchPreference: enough.FetchPreference.full,
      );
      final mime = mimeMessages.first;
      // Match by decoded filename rather than assuming fetch-id ordering —
      // getAttachments() returns each non-inline attachment MimePart, and
      // decodeFileName() gives back the name we stored on MailAttachment.
      final part = mime.getAttachments().where((p) => p.decodeFileName() == attachment.filename).firstOrNull;
      return part?.decodeContentBinary() ?? const [];
    } finally {
      await client.disconnect();
    }
  }
}
```

This uses `firstOrNull` from `package:collection`, added in Task 10 — if implementing Task 6 before Task 10, either reorder to add the `collection` dependency here instead (run `flutter pub add collection` as part of this task's Step 1), or use `part.isNotEmpty ? part.first : null` with an explicit `.toList()` in the interim. Simplest: add `collection` in this task's dependency step rather than deferring it to Task 10.

- [ ] **Step 8: Run the full transport test file to confirm nothing else broke**

Run: `flutter test test/data/transport/mail_message_mapper_test.dart`
Expected: PASS (2 tests) — `EnoughMailTransport` compiles but has no automated test coverage by design (see Interfaces note above).

- [ ] **Step 9: Commit**

```bash
git add lib/data/transport/mail_transport.dart lib/data/transport/mail_message_mapper.dart lib/data/transport/enough_mail_transport.dart test/data/transport/mail_message_mapper_test.dart
git commit -m "feat: add MailTransport interface, mapper, and enough_mail implementation"
```

---

### Task 7: MailSender interface + enough_mail-backed implementation

**Files:**
- Create: `lib/data/transport/mail_sender.dart`, `lib/data/transport/enough_mail_sender.dart`
- Test: `test/data/transport/mail_sender_test.dart`

**Interfaces:**
- Consumes: `MailAccount` (Task 1), `EnoughMailTransport._toEnoughAccount`-equivalent conversion (duplicated here intentionally — see note in Step 3)
- Produces:
  - `abstract class MailSender { Future<void> send(MailAccount account, String password, ComposedMessage message); }`
  - `class ComposedMessage { final List<String> to; final List<String> cc; final List<String> bcc; final String subject; final String bodyText; final String? bodyHtml; final List<String> attachmentFilePaths; }`
  - `MimeMessage buildMimeMessage(MailAccount account, ComposedMessage message)` (pure function, unit tested directly)
  - `EnoughMailSender implements MailSender` — network-calling `send()` is integration-only, not covered by the automated test suite (same rationale as `EnoughMailTransport`).

- [ ] **Step 1: Write the failing test for buildMimeMessage**

```dart
// test/data/transport/mail_sender_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

void main() {
  const account = MailAccount(
    displayName: 'Alice',
    email: 'alice@example.com',
    imapHost: 'imap.example.com',
    imapPort: 993,
    imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com',
    smtpPort: 465,
    smtpSecurity: MailSecurity.ssl,
    username: 'alice@example.com',
  );

  test('buildMimeMessage sets from/to/cc/subject/body', () {
    final composed = ComposedMessage(
      to: const ['bob@example.com'],
      cc: const ['carol@example.com'],
      bcc: const [],
      subject: 'Hello',
      bodyText: 'Hi Bob',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    final mime = buildMimeMessage(account, composed);

    expect(mime.from?.first.email, 'alice@example.com');
    expect(mime.to?.map((a) => a.email), contains('bob@example.com'));
    expect(mime.cc?.map((a) => a.email), contains('carol@example.com'));
    expect(mime.decodeSubject(), 'Hello');
    expect(mime.decodeTextPlainPart(), contains('Hi Bob'));
  });

  test('buildMimeMessage throws when there are no recipients', () {
    final composed = ComposedMessage(
      to: const [],
      cc: const [],
      bcc: const [],
      subject: 'Hello',
      bodyText: 'Hi',
      bodyHtml: null,
      attachmentFilePaths: const [],
    );

    expect(() => buildMimeMessage(account, composed), throwsArgumentError);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/data/transport/mail_sender_test.dart`
Expected: FAIL — `mail_sender.dart` doesn't exist.

- [ ] **Step 3: Implement ComposedMessage, buildMimeMessage, and the MailSender interface**

```dart
// lib/data/transport/mail_sender.dart
import 'dart:io';
import 'package:enough_mail/enough_mail.dart';
import '../../models/mail_account.dart';

class ComposedMessage {
  ComposedMessage({
    required this.to,
    required this.cc,
    required this.bcc,
    required this.subject,
    required this.bodyText,
    required this.bodyHtml,
    required this.attachmentFilePaths,
  });

  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String bodyText;
  final String? bodyHtml;
  final List<String> attachmentFilePaths;
}

abstract class MailSender {
  Future<void> send(MailAccount account, String password, ComposedMessage message);
}

MimeMessage buildMimeMessage(MailAccount account, ComposedMessage message) {
  if (message.to.isEmpty && message.cc.isEmpty && message.bcc.isEmpty) {
    throw ArgumentError('ComposedMessage must have at least one recipient');
  }

  final builder = MessageBuilder()
    ..from = [MailAddress(account.displayName, account.email)]
    ..to = message.to.map((e) => MailAddress('', e)).toList()
    ..cc = message.cc.map((e) => MailAddress('', e)).toList()
    ..bcc = message.bcc.map((e) => MailAddress('', e)).toList()
    ..subject = message.subject;

  if (message.bodyHtml != null) {
    builder.addMultipartAlternative(
      plainText: message.bodyText,
      htmlText: message.bodyHtml!,
    );
  } else {
    builder.text = message.bodyText;
  }

  final mime = builder.buildMimeMessage();
  if (mime == null) {
    throw StateError('Failed to build MIME message');
  }
  return mime;
}
```

Note: attachments (`attachmentFilePaths`) are attached in `EnoughMailSender.send()` (Step 4) rather than in `buildMimeMessage`, because `MessageBuilder.addFile()` is async (reads file bytes) while `buildMimeMessage` here is kept a synchronous pure function for easy testing. `EnoughMailSender` calls `addFile` before `buildMimeMessage()`.

- [ ] **Step 4: Implement EnoughMailSender**

```dart
// lib/data/transport/enough_mail_sender.dart
import 'dart:io';
import 'package:enough_mail/enough_mail.dart' as enough;
import '../../models/enums.dart';
import '../../models/mail_account.dart';
import 'mail_sender.dart';

class EnoughMailSender implements MailSender {
  @override
  Future<void> send(
    MailAccount account,
    String password,
    ComposedMessage message,
  ) async {
    final enoughAccount = enough.MailAccount.fromManualSettings(
      name: account.displayName,
      email: account.email,
      incomingHost: account.imapHost,
      incomingPort: account.imapPort,
      incomingSocketType: _toSocketType(account.imapSecurity),
      outgoingHost: account.smtpHost,
      outgoingPort: account.smtpPort,
      outgoingSocketType: _toSocketType(account.smtpSecurity),
      password: password,
      userName: account.displayName,
      loginName: account.username,
    );

    final builder = enough.MessageBuilder()
      ..from = [enough.MailAddress(account.displayName, account.email)]
      ..to = message.to.map((e) => enough.MailAddress('', e)).toList()
      ..cc = message.cc.map((e) => enough.MailAddress('', e)).toList()
      ..bcc = message.bcc.map((e) => enough.MailAddress('', e)).toList()
      ..subject = message.subject;

    if (message.bodyHtml != null) {
      builder.addMultipartAlternative(
        plainText: message.bodyText,
        htmlText: message.bodyHtml!,
      );
    } else {
      builder.text = message.bodyText;
    }

    for (final path in message.attachmentFilePaths) {
      await builder.addFile(File(path));
    }

    final mime = builder.buildMimeMessage();
    if (mime == null) {
      throw StateError('Failed to build MIME message');
    }

    final client = enough.MailClient(enoughAccount);
    try {
      await client.connect();
      await client.sendMessage(mime);
    } finally {
      await client.disconnect();
    }
  }

  enough.SocketType _toSocketType(MailSecurity security) {
    switch (security) {
      case MailSecurity.ssl:
        return enough.SocketType.ssl;
      case MailSecurity.startTls:
        return enough.SocketType.starttls;
      case MailSecurity.none:
        return enough.SocketType.plain;
    }
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/data/transport/mail_sender_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/data/transport/mail_sender.dart lib/data/transport/enough_mail_sender.dart test/data/transport/mail_sender_test.dart
git commit -m "feat: add MailSender interface, message builder, and enough_mail implementation"
```

---

### Task 8: AccountRepository

**Files:**
- Create: `lib/data/repository/account_repository.dart`
- Test: `test/data/repository/account_repository_test.dart`

**Interfaces:**
- Consumes: `AccountDao` (Task 2), `SecureCredentialStore` (Task 5), `MailTransport` (Task 6)
- Produces: `AccountRepository(AccountDao accountDao, SecureCredentialStore credentialStore, MailTransport transport)` — `Future<List<MailAccount>> listAccounts()`, `Future<int> addAccount(MailAccount account, String password)` (calls `transport.testConnection` first, throws if it fails, then persists), `Future<void> updateAccount(MailAccount account, {String? newPassword})`, `Future<void> removeAccount(int accountId)` (deletes account row — cascades to folders/messages/attachments via `ON DELETE CASCADE` — and deletes the stored password).

- [ ] **Step 1: Write the failing repository tests**

```dart
// test/data/repository/account_repository_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/repository/account_repository.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';

class MockMailTransport extends Mock implements MailTransport {}

class FakeCredentialStore implements SecureCredentialStore {
  final Map<int, String> _passwords = {};

  @override
  Future<void> savePassword({required int accountId, required String password}) async {
    _passwords[accountId] = password;
  }

  @override
  Future<String?> getPassword(int accountId) async => _passwords[accountId];

  @override
  Future<void> deletePassword(int accountId) async => _passwords.remove(accountId);
}

void main() {
  late Database db;
  late AccountDao accountDao;
  late FakeCredentialStore credentialStore;
  late MockMailTransport transport;
  late AccountRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(const MailAccount(
      displayName: '',
      email: '',
      imapHost: '',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: '',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: '',
    ));
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
    );
    accountDao = AccountDao(db);
    credentialStore = FakeCredentialStore();
    transport = MockMailTransport();
    repository = AccountRepository(accountDao, credentialStore, transport);
  });

  tearDown(() async => db.close());

  const account = MailAccount(
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

  test('addAccount tests the connection before persisting', () async {
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});

    final id = await repository.addAccount(account, 'app-password');

    verify(() => transport.testConnection(any(), 'app-password')).called(1);
    expect(await accountDao.getById(id), isNotNull);
    expect(await credentialStore.getPassword(id), 'app-password');
  });

  test('addAccount does not persist when the connection test throws', () async {
    when(() => transport.testConnection(any(), any()))
        .thenThrow(Exception('auth failed'));

    await expectLater(
      repository.addAccount(account, 'wrong-password'),
      throwsException,
    );
    expect(await accountDao.getAll(), isEmpty);
  });

  test('removeAccount deletes the account row and the stored password', () async {
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});
    final id = await repository.addAccount(account, 'app-password');

    await repository.removeAccount(id);

    expect(await accountDao.getById(id), isNull);
    expect(await credentialStore.getPassword(id), isNull);
  });

  test('listAccounts returns all persisted accounts', () async {
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});
    await repository.addAccount(account, 'app-password');

    expect(await repository.listAccounts(), hasLength(1));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/data/repository/account_repository_test.dart`
Expected: FAIL — `account_repository.dart` doesn't exist.

- [ ] **Step 3: Implement AccountRepository**

```dart
// lib/data/repository/account_repository.dart
import '../../models/mail_account.dart';
import '../local/account_dao.dart';
import '../secure/credential_store.dart';
import '../transport/mail_transport.dart';

class AccountRepository {
  AccountRepository(this._accountDao, this._credentialStore, this._transport);

  final AccountDao _accountDao;
  final SecureCredentialStore _credentialStore;
  final MailTransport _transport;

  Future<List<MailAccount>> listAccounts() => _accountDao.getAll();

  Future<int> addAccount(MailAccount account, String password) async {
    await _transport.testConnection(account, password);
    final id = await _accountDao.insert(account);
    await _credentialStore.savePassword(accountId: id, password: password);
    return id;
  }

  Future<void> updateAccount(MailAccount account, {String? newPassword}) async {
    if (newPassword != null) {
      await _transport.testConnection(account, newPassword);
      await _credentialStore.savePassword(accountId: account.id!, password: newPassword);
    }
    await _accountDao.update(account);
  }

  Future<void> removeAccount(int accountId) async {
    await _accountDao.delete(accountId);
    await _credentialStore.deletePassword(accountId);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/data/repository/account_repository_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/data/repository/account_repository.dart test/data/repository/account_repository_test.dart
git commit -m "feat: add AccountRepository"
```

---

### Task 9: MailRepository — folder sync, header delta sync, body/attachment fetch-on-demand

**Files:**
- Create: `lib/data/repository/mail_repository.dart`
- Test: `test/data/repository/mail_repository_test.dart`

**Interfaces:**
- Consumes: `FolderDao`, `MessageDao`, `AttachmentDao` (Tasks 3-4), `MailTransport` (Task 6), `SecureCredentialStore` (Task 5)
- Produces: `MailRepository(FolderDao folderDao, MessageDao messageDao, AttachmentDao attachmentDao, MailTransport transport, SecureCredentialStore credentialStore)` —
  - `Future<List<MailFolder>> syncFolders(MailAccount account)` (discovers + upserts, preserves the local-only Outbox folder)
  - `Future<int> ensureOutboxFolder(int accountId)` (idempotent: creates a `MailFolderType.other`, `isLocalOnly: true` folder named "Outbox" if missing, returns its id)
  - `Future<List<MailFolder>> getCachedFolders(int accountId)`
  - `Future<List<MailMessage>> syncHeaders(MailAccount account, MailFolder folder)` (delta sync via `getMaxUid`, merges into cache, returns full cached list for the folder)
  - `Future<List<MailMessage>> getCachedMessages(int folderId)`
  - `Future<MailMessage> fetchBodyIfNeeded(MailAccount account, MailFolder folder, MailMessage message)` (returns cached message unchanged if `isDownloaded`; else fetches, caches, returns updated)
  - `Future<List<int>> downloadAttachment(MailAccount account, MailFolder folder, MailMessage message, MailAttachment attachment)` (returns bytes, also writes them to a local file and updates `local_path` via the caller — see Task 15 screen, which owns filesystem writes so this repository stays testable without touching disk)

- [ ] **Step 1: Write the failing repository tests**

```dart
// test/data/repository/mail_repository_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/account_dao.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/data/local/attachment_dao.dart';
import 'package:imap_mail/data/local/folder_dao.dart';
import 'package:imap_mail/data/local/message_dao.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/data/secure/credential_store.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';

class MockMailTransport extends Mock implements MailTransport {}

class FakeCredentialStore implements SecureCredentialStore {
  final Map<int, String> _passwords = {1: 'app-password'};
  @override
  Future<void> savePassword({required int accountId, required String password}) async {}
  @override
  Future<String?> getPassword(int accountId) async => _passwords[accountId];
  @override
  Future<void> deletePassword(int accountId) async {}
}

void main() {
  late Database db;
  late FolderDao folderDao;
  late MessageDao messageDao;
  late AttachmentDao attachmentDao;
  late MockMailTransport transport;
  late MailRepository repository;
  late int accountId;

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

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(account);
    registerFallbackValue(const MailFolder(accountId: 1, name: '', path: '', type: MailFolderType.inbox));
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
    );
    folderDao = FolderDao(db);
    messageDao = MessageDao(db);
    attachmentDao = AttachmentDao(db);
    transport = MockMailTransport();
    repository = MailRepository(folderDao, messageDao, attachmentDao, transport, FakeCredentialStore());
    accountId = await AccountDao(db).insert(account);
  });

  tearDown(() async => db.close());

  test('syncFolders discovers folders and preserves the local Outbox', () async {
    when(() => transport.discoverFolders(any(), any(), any())).thenAnswer((_) async => [
          MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
          MailFolder(accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent),
        ]);
    await repository.ensureOutboxFolder(accountId);

    final folders = await repository.syncFolders(account.copyWith(id: accountId));

    expect(folders.map((f) => f.name), containsAll(['INBOX', 'Sent', 'Outbox']));
    expect(folders.firstWhere((f) => f.name == 'Outbox').isLocalOnly, isTrue);
  });

  test('syncHeaders fetches only messages after the highest cached uid', () async {
    final folderId = await folderDao.upsert(
      MailFolder(accountId: accountId, name: 'INBOX', path: 'INBOX', type: MailFolderType.inbox),
    );
    final folder = (await folderDao.getById(folderId))!;
    await messageDao.upsertHeaders([
      MailMessage(
        folderId: folderId,
        uid: 5,
        subject: 'Old',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 1, 1),
        snippet: 'old',
      ),
    ]);
    when(() => transport.fetchHeadersSince(any(), any(), any(), 5)).thenAnswer((_) async => [
          MailMessage(
            folderId: folderId,
            uid: 6,
            subject: 'New',
            from: 'b@example.com',
            to: 'me@example.com',
            date: DateTime.utc(2026, 8, 19),
            snippet: 'new',
          ),
        ]);

    final messages = await repository.syncHeaders(account, folder);

    verify(() => transport.fetchHeadersSince(any(), any(), any(), 5)).called(1);
    expect(messages, hasLength(2));
  });

  test('fetchBodyIfNeeded returns cached message untouched when already downloaded', () async {
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
        bodyText: 'cached body',
        isDownloaded: true,
      ),
    ]);
    final cached = (await messageDao.getForFolder(folderId)).first;

    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    expect(result.bodyText, 'cached body');
    verifyNever(() => transport.fetchBody(any(), any(), any(), any()));
  });

  test('fetchBodyIfNeeded fetches and caches the body when not yet downloaded', () async {
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
    final cached = (await messageDao.getForFolder(folderId)).first;
    when(() => transport.fetchBody(any(), any(), any(), any())).thenAnswer(
      (_) async => cached.copyWith(bodyText: 'fetched body', isDownloaded: true),
    );

    final result = await repository.fetchBodyIfNeeded(account, folder, cached);

    expect(result.bodyText, 'fetched body');
    final refetched = await messageDao.getById(cached.id!);
    expect(refetched!.bodyText, 'fetched body');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/data/repository/mail_repository_test.dart`
Expected: FAIL — `mail_repository.dart` doesn't exist.

- [ ] **Step 3: Implement MailRepository**

```dart
// lib/data/repository/mail_repository.dart
import '../../models/enums.dart';
import '../../models/mail_account.dart';
import '../../models/mail_attachment.dart';
import '../../models/mail_folder.dart';
import '../../models/mail_message.dart';
import '../local/attachment_dao.dart';
import '../local/folder_dao.dart';
import '../local/message_dao.dart';
import '../secure/credential_store.dart';
import '../transport/mail_transport.dart';

class MailRepository {
  MailRepository(
    this._folderDao,
    this._messageDao,
    this._attachmentDao,
    this._transport,
    this._credentialStore,
  );

  final FolderDao _folderDao;
  final MessageDao _messageDao;
  final AttachmentDao _attachmentDao;
  final MailTransport _transport;
  final SecureCredentialStore _credentialStore;

  Future<String> _passwordFor(MailAccount account) async {
    final password = await _credentialStore.getPassword(account.id!);
    if (password == null) {
      throw StateError('No stored password for account ${account.id}');
    }
    return password;
  }

  Future<int> ensureOutboxFolder(int accountId) async {
    return _folderDao.upsert(MailFolder(
      accountId: accountId,
      name: 'Outbox',
      path: 'Outbox',
      type: MailFolderType.other,
      isLocalOnly: true,
    ));
  }

  Future<List<MailFolder>> syncFolders(MailAccount account) async {
    final password = await _passwordFor(account);
    final discovered = await _transport.discoverFolders(account, password, account.id!);
    for (final folder in discovered) {
      await _folderDao.upsert(folder);
    }
    await ensureOutboxFolder(account.id!);
    return _folderDao.getForAccount(account.id!);
  }

  Future<List<MailFolder>> getCachedFolders(int accountId) {
    return _folderDao.getForAccount(accountId);
  }

  Future<List<MailMessage>> syncHeaders(MailAccount account, MailFolder folder) async {
    if (folder.isLocalOnly) {
      return _messageDao.getForFolder(folder.id!);
    }
    final password = await _passwordFor(account);
    final sinceUid = await _messageDao.getMaxUid(folder.id!);
    final newHeaders = await _transport.fetchHeadersSince(account, password, folder, sinceUid);
    if (newHeaders.isNotEmpty) {
      await _messageDao.upsertHeaders(newHeaders);
    }
    return _messageDao.getForFolder(folder.id!);
  }

  Future<List<MailMessage>> getCachedMessages(int folderId) {
    return _messageDao.getForFolder(folderId);
  }

  Future<MailMessage> fetchBodyIfNeeded(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
  ) async {
    if (message.isDownloaded) {
      return message;
    }
    final password = await _passwordFor(account);
    final fetched = await _transport.fetchBody(account, password, folder, message);
    await _messageDao.updateBody(
      message.id!,
      bodyText: fetched.bodyText,
      bodyHtml: fetched.bodyHtml,
    );
    return fetched;
  }

  Future<List<int>> downloadAttachment(
    MailAccount account,
    MailFolder folder,
    MailMessage message,
    MailAttachment attachment,
  ) async {
    final password = await _passwordFor(account);
    return _transport.fetchAttachmentBytes(account, password, folder, message, attachment);
  }

  Future<void> recordAttachmentLocalPath(int attachmentId, String localPath) {
    return _attachmentDao.updateLocalPath(attachmentId, localPath);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/data/repository/mail_repository_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/data/repository/mail_repository.dart test/data/repository/mail_repository_test.dart
git commit -m "feat: add MailRepository for folder/header/body sync"
```

---

### Task 10: Send flow — success path, IMAP Sent append best-effort, failure → Outbox retry

**Files:**
- Modify: `lib/data/repository/mail_repository.dart:1-` (add `sendMessage`/`retryFailedMessage`)
- Test: Modify `test/data/repository/mail_repository_test.dart`

**Interfaces:**
- Consumes: `MailSender`, `ComposedMessage` (Task 7)
- Produces: `MailRepository` gains a `MailSender` constructor param and: `Future<void> sendMessage(MailAccount account, ComposedMessage composed)` (send via `MailSender`; on success, best-effort mark as sent by inserting a cached "sent" record into the account's Sent folder if present, swallowing any error from that step; on failure, insert a `MailSendStatus.failed` record into the Outbox folder and rethrow so the UI can show an error) and `Future<void> retryFailedMessage(MailAccount account, MailMessage failedMessage)` (rebuilds a `ComposedMessage` from the failed record's fields and calls `sendMessage` again, then removes the old failed Outbox row on success).

- [ ] **Step 1: Update the repository constructor and add failing tests**

Add to `test/data/repository/mail_repository_test.dart` (new imports: `mail_sender.dart`; new mock `MockMailSender extends Mock implements MailSender {}`; update `MailRepository(...)` construction in `setUp` to pass a `MockMailSender sender` as an added final constructor argument):

```dart
// Add near the other mocks at the top of the file:
import 'package:imap_mail/data/transport/mail_sender.dart';

class MockMailSender extends Mock implements MailSender {}
```

```dart
// In setUp(), add:
late MockMailSender sender;
// ...
sender = MockMailSender();
repository = MailRepository(
  folderDao,
  messageDao,
  attachmentDao,
  transport,
  FakeCredentialStore(),
  sender,
);
```

```dart
// New tests, appended to main():
test('sendMessage succeeds and caches a sent copy when a Sent folder exists', () async {
  final sentFolderId = await folderDao.upsert(
    MailFolder(accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent),
  );
  when(() => sender.send(any(), any(), any())).thenAnswer((_) async {});
  final composed = ComposedMessage(
    to: const ['bob@example.com'],
    cc: const [],
    bcc: const [],
    subject: 'Hi',
    bodyText: 'Hello Bob',
    bodyHtml: null,
    attachmentFilePaths: const [],
  );

  await repository.sendMessage(account, composed);

  verify(() => sender.send(account, 'app-password', composed)).called(1);
  final sentMessages = await messageDao.getForFolder(sentFolderId);
  expect(sentMessages, hasLength(1));
  expect(sentMessages.first.sendStatus, MailSendStatus.sent);
});

test('sendMessage on failure stores a failed record in Outbox and rethrows', () async {
  await repository.ensureOutboxFolder(accountId);
  when(() => sender.send(any(), any(), any())).thenThrow(Exception('smtp down'));
  final composed = ComposedMessage(
    to: const ['bob@example.com'],
    cc: const [],
    bcc: const [],
    subject: 'Hi',
    bodyText: 'Hello Bob',
    bodyHtml: null,
    attachmentFilePaths: const [],
  );

  await expectLater(repository.sendMessage(account, composed), throwsException);

  final outbox = (await folderDao.getForAccount(accountId))
      .firstWhere((f) => f.name == 'Outbox');
  final outboxMessages = await messageDao.getForFolder(outbox.id!);
  expect(outboxMessages, hasLength(1));
  expect(outboxMessages.first.sendStatus, MailSendStatus.failed);
  expect(outboxMessages.first.subject, 'Hi');
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `flutter test test/data/repository/mail_repository_test.dart`
Expected: FAIL — `MailRepository` constructor doesn't accept a `sender` argument yet, and `sendMessage`/`ComposedMessage` import is unresolved in this file's usage.

- [ ] **Step 3: Update MailRepository**

```dart
// lib/data/repository/mail_repository.dart
// Add import:
import '../transport/mail_sender.dart';

// Change class declaration and constructor:
class MailRepository {
  MailRepository(
    this._folderDao,
    this._messageDao,
    this._attachmentDao,
    this._transport,
    this._credentialStore,
    this._sender,
  );

  final FolderDao _folderDao;
  final MessageDao _messageDao;
  final AttachmentDao _attachmentDao;
  final MailTransport _transport;
  final SecureCredentialStore _credentialStore;
  final MailSender _sender;

  // ...(existing methods unchanged)...

  Future<void> sendMessage(MailAccount account, ComposedMessage composed) async {
    final password = await _passwordFor(account);
    try {
      await _sender.send(account, password, composed);
    } catch (_) {
      final outboxId = await ensureOutboxFolder(account.id!);
      await _messageDao.insertLocal(MailMessage(
        folderId: outboxId,
        uid: 0,
        subject: composed.subject,
        from: account.email,
        to: composed.to.join(', '),
        date: DateTime.now().toUtc(),
        snippet: composed.bodyText.length > 140
            ? composed.bodyText.substring(0, 140)
            : composed.bodyText,
        bodyText: composed.bodyText,
        bodyHtml: composed.bodyHtml,
        isRead: true,
        isDownloaded: true,
        sendStatus: MailSendStatus.failed,
      ));
      rethrow;
    }

    final folders = await _folderDao.getForAccount(account.id!);
    final sentFolder = folders.where((f) => f.type == MailFolderType.sent).firstOrNull;
    if (sentFolder != null) {
      try {
        await _messageDao.insertLocal(MailMessage(
          folderId: sentFolder.id!,
          uid: 0,
          subject: composed.subject,
          from: account.email,
          to: composed.to.join(', '),
          date: DateTime.now().toUtc(),
          snippet: composed.bodyText.length > 140
              ? composed.bodyText.substring(0, 140)
              : composed.bodyText,
          bodyText: composed.bodyText,
          bodyHtml: composed.bodyHtml,
          isRead: true,
          isDownloaded: true,
          sendStatus: MailSendStatus.sent,
        ));
      } catch (_) {
        // Best-effort local cache write; the send itself already succeeded.
      }
    }
  }

  Future<void> retryFailedMessage(MailAccount account, MailMessage failedMessage) async {
    final composed = ComposedMessage(
      to: failedMessage.to.split(', ').where((e) => e.isNotEmpty).toList(),
      cc: const [],
      bcc: const [],
      subject: failedMessage.subject,
      bodyText: failedMessage.bodyText ?? '',
      bodyHtml: failedMessage.bodyHtml,
      attachmentFilePaths: const [],
    );
    await sendMessage(account, composed);
    await _messageDao.deleteMessage(failedMessage.id!);
  }
}
```

- [ ] **Step 4: Add the missing MessageDao.deleteMessage method**

```dart
// lib/data/local/message_dao.dart — add inside MessageDao:
  Future<void> deleteMessage(int id) async {
    await _db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }
```

- [ ] **Step 5: Use the `firstOrNull` extension from `collection`**

`collection` was already added as a dependency in Task 6 (needed there for `EnoughMailTransport`'s attachment lookup) — no need to add it again, just import it:

```dart
// lib/data/repository/mail_repository.dart — add import:
import 'package:collection/collection.dart';
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/data/repository/mail_repository_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 7: Commit**

```bash
git add lib/data/repository/mail_repository.dart lib/data/local/message_dao.dart test/data/repository/mail_repository_test.dart pubspec.yaml pubspec.lock
git commit -m "feat: add send flow with best-effort Sent caching and Outbox retry on failure"
```

---

### Task 11: Riverpod providers

**Files:**
- Create: `lib/providers/database_providers.dart`, `lib/providers/account_providers.dart`, `lib/providers/folder_providers.dart`, `lib/providers/message_providers.dart`, `lib/providers/compose_providers.dart`
- Test: `test/providers/providers_test.dart`

**Interfaces:**
- Consumes: `AppDatabase`, all DAOs, `SecureCredentialStore`, `EnoughMailTransport`, `EnoughMailSender`, `AccountRepository`, `MailRepository` (Tasks 1-10)
- Produces:
  - `databaseProvider` (`FutureProvider<Database>`, calls `AppDatabase.open()`) — **overridden in tests** with an in-memory ffi database.
  - `accountRepositoryProvider`, `mailRepositoryProvider` (depend on `databaseProvider` and wrap the DAOs/services)
  - `accountsProvider` — `AsyncNotifierProvider<AccountsNotifier, List<MailAccount>>` with `Future<void> add(MailAccount, String password)`, `Future<void> remove(int id)`
  - `foldersProvider` — `FutureProvider.family<List<MailFolder>, int accountId>` (calls `mailRepository.syncFolders`, falling back to `getCachedFolders` on transport error, exposing the error via `AsyncError` if there's no cache to fall back to)
  - `messagesProvider` — `FutureProvider.family<List<MailMessage>, int folderId>`
  - `sendMessageProvider` — a simple provider exposing a callable `Future<void> Function(MailAccount, ComposedMessage)` bound to `mailRepository.sendMessage`

- [ ] **Step 1: Write the failing provider test**

```dart
// test/providers/providers_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/providers/repository_providers.dart';

class MockMailTransport extends Mock implements MailTransport {}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(const MailAccount(
      displayName: '',
      email: '',
      imapHost: '',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: '',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: '',
    ));
  });

  test('accountsProvider starts empty, add() persists and refreshes the list', () async {
    final transport = MockMailTransport();
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        return databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
        );
      }),
      mailTransportProvider.overrideWithValue(transport),
    ]);
    addTearDown(container.dispose);

    final initial = await container.read(accountsProvider.future);
    expect(initial, isEmpty);

    const account = MailAccount(
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
    await container.read(accountsProvider.notifier).add(account, 'app-password');

    final after = await container.read(accountsProvider.future);
    expect(after, hasLength(1));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/providers/providers_test.dart`
Expected: FAIL — provider files don't exist.

- [ ] **Step 3: Implement database and repository providers**

```dart
// lib/providers/database_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../data/local/app_database.dart';

final databaseProvider = FutureProvider<Database>((ref) => AppDatabase.open());
```

```dart
// lib/providers/repository_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/local/account_dao.dart';
import '../data/local/attachment_dao.dart';
import '../data/local/folder_dao.dart';
import '../data/local/message_dao.dart';
import '../data/repository/account_repository.dart';
import '../data/repository/mail_repository.dart';
import '../data/secure/credential_store.dart';
import '../data/transport/enough_mail_sender.dart';
import '../data/transport/enough_mail_transport.dart';
import '../data/transport/mail_sender.dart';
import '../data/transport/mail_transport.dart';
import 'database_providers.dart';

final credentialStoreProvider = Provider<SecureCredentialStore>((ref) => SecureCredentialStore());

final mailTransportProvider = Provider<MailTransport>((ref) => EnoughMailTransport());

final mailSenderProvider = Provider<MailSender>((ref) => EnoughMailSender());

final accountRepositoryProvider = FutureProvider<AccountRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return AccountRepository(
    AccountDao(db),
    ref.watch(credentialStoreProvider),
    ref.watch(mailTransportProvider),
  );
});

final mailRepositoryProvider = FutureProvider<MailRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return MailRepository(
    FolderDao(db),
    MessageDao(db),
    AttachmentDao(db),
    ref.watch(mailTransportProvider),
    ref.watch(credentialStoreProvider),
    ref.watch(mailSenderProvider),
  );
});
```

- [ ] **Step 4: Implement accountsProvider**

```dart
// lib/providers/account_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_account.dart';
import 'repository_providers.dart';

class AccountsNotifier extends AsyncNotifier<List<MailAccount>> {
  @override
  Future<List<MailAccount>> build() async {
    final repository = await ref.watch(accountRepositoryProvider.future);
    return repository.listAccounts();
  }

  Future<void> add(MailAccount account, String password) async {
    final repository = await ref.read(accountRepositoryProvider.future);
    await repository.addAccount(account, password);
    ref.invalidateSelf();
    await future;
  }

  Future<void> remove(int id) async {
    final repository = await ref.read(accountRepositoryProvider.future);
    await repository.removeAccount(id);
    ref.invalidateSelf();
    await future;
  }
}

final accountsProvider = AsyncNotifierProvider<AccountsNotifier, List<MailAccount>>(
  AccountsNotifier.new,
);
```

- [ ] **Step 5: Implement folder and message providers**

```dart
// lib/providers/folder_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import 'account_providers.dart';
import 'repository_providers.dart';

final foldersProvider = FutureProvider.family<List<MailFolder>, int>((ref, accountId) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == accountId);
  try {
    return await repository.syncFolders(account);
  } catch (_) {
    final cached = await repository.getCachedFolders(accountId);
    if (cached.isEmpty) rethrow;
    return cached;
  }
});
```

```dart
// lib/providers/message_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import 'account_providers.dart';
import 'repository_providers.dart';

final messagesProvider = FutureProvider.family<List<MailMessage>, MailFolder>((ref, folder) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == folder.accountId);
  try {
    return await repository.syncHeaders(account, folder);
  } catch (_) {
    final cached = await repository.getCachedMessages(folder.id!);
    if (cached.isEmpty) rethrow;
    return cached;
  }
});
```

- [ ] **Step 6: Implement the compose/send provider**

```dart
// lib/providers/compose_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/transport/mail_sender.dart';
import '../models/mail_account.dart';
import 'repository_providers.dart';

final sendMessageProvider = Provider<Future<void> Function(MailAccount, ComposedMessage)>((ref) {
  return (account, composed) async {
    final repository = await ref.read(mailRepositoryProvider.future);
    await repository.sendMessage(account, composed);
  };
});
```

- [ ] **Step 7: Run test to verify it passes**

Run: `flutter test test/providers/providers_test.dart`
Expected: PASS (1 test)

- [ ] **Step 8: Commit**

```bash
git add lib/providers test/providers
git commit -m "feat: add Riverpod providers for accounts, folders, messages, and sending"
```

---

### Task 12: App shell (main.dart, app.dart)

**Files:**
- Create: `lib/app.dart`
- Modify: `lib/main.dart`
- Test: `test/widget/app_smoke_test.dart`

**Interfaces:**
- Consumes: `accountsProvider` (Task 11)
- Produces: `class ImapMailApp extends ConsumerWidget` — root widget wrapped by `main()` in a `ProviderScope`; shows `AccountListScreen` when accounts exist or is empty, otherwise routes straight to `AccountFormScreen` for the first account (screens built in Tasks 13-17; this task only wires the shell and can render placeholder `Scaffold`s referencing those not-yet-built screens by name — see Step 3 note).

- [ ] **Step 1: Write the failing smoke test**

```dart
// test/widget/app_smoke_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/app.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/database_providers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('app builds and shows a MaterialApp', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async {
          return databaseFactory.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
          );
        }),
      ],
      child: const ImapMailApp(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ImapMailApp), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/app_smoke_test.dart`
Expected: FAIL — `lib/app.dart` doesn't exist.

- [ ] **Step 3: Implement app.dart**

This task only wires navigation to screen *classes*; the screens themselves are built in Tasks 13-17. Declare minimal placeholder classes here so the app compiles, then each later task replaces its placeholder — do not leave the placeholders as TODOs, they are working (if minimal) `Scaffold`s that satisfy this task's own test.

```dart
// lib/app.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/account_providers.dart';
import 'screens/account_list_screen.dart';
import 'screens/account_form_screen.dart';

class ImapMailApp extends ConsumerWidget {
  const ImapMailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'IMAP Mail',
      home: Consumer(
        builder: (context, ref, _) {
          final accountsAsync = ref.watch(accountsProvider);
          return accountsAsync.when(
            data: (accounts) => accounts.isEmpty
                ? const AccountFormScreen()
                : const AccountListScreen(),
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

- [ ] **Step 4: Add placeholder screens satisfying this task only**

```dart
// lib/screens/account_list_screen.dart
import 'package:flutter/material.dart';

class AccountListScreen extends StatelessWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Accounts')));
  }
}
```

```dart
// lib/screens/account_form_screen.dart
import 'package:flutter/material.dart';

class AccountFormScreen extends StatelessWidget {
  const AccountFormScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Add account')));
  }
}
```

(Task 13 replaces both of these with the real implementations and their own tests.)

- [ ] **Step 5: Update main.dart**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

void main() {
  runApp(const ProviderScope(child: ImapMailApp()));
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/widget/app_smoke_test.dart`
Expected: PASS (1 test)

- [ ] **Step 7: Commit**

```bash
git add lib/app.dart lib/main.dart lib/screens/account_list_screen.dart lib/screens/account_form_screen.dart test/widget/app_smoke_test.dart
git commit -m "feat: add app shell wiring accounts to initial screen"
```

---

### Task 13: Account list/switcher + Add/Edit account form (replaces Task 12 placeholders)

**Files:**
- Modify: `lib/screens/account_list_screen.dart`, `lib/screens/account_form_screen.dart`
- Test: `test/widget/account_form_screen_test.dart`

**Interfaces:**
- Consumes: `accountsProvider` (Task 11), `MailAccount`, `MailSecurity` (Task 1)
- Produces: `AccountFormScreen({MailAccount? existing})` — a form with display name, email, IMAP host/port/security, SMTP host/port/security, username, password fields, a "Test connection" button (calls `mailTransportProvider.testConnection` directly, shows success/failure inline), and a Save button (disabled until required fields are valid) that calls `accountsProvider.notifier.add`.
  `AccountListScreen` — lists accounts from `accountsProvider`, tapping one navigates to `FolderViewScreen(accountId: ...)` (Task 14), an "Add account" action navigates to `AccountFormScreen`.

- [ ] **Step 1: Write the failing form validation test**

```dart
// test/widget/account_form_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/screens/account_form_screen.dart';

void main() {
  testWidgets('Save button is disabled until required fields are filled', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountFormScreen()),
    ));

    final saveButtonFinder = find.widgetWithText(ElevatedButton, 'Save');
    ElevatedButton saveButton() => tester.widget(saveButtonFinder);
    expect(saveButton().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('displayNameField')), 'Work');
    await tester.enterText(find.byKey(const Key('emailField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('imapHostField')), 'imap.example.com');
    await tester.enterText(find.byKey(const Key('imapPortField')), '993');
    await tester.enterText(find.byKey(const Key('smtpHostField')), 'smtp.example.com');
    await tester.enterText(find.byKey(const Key('smtpPortField')), '465');
    await tester.enterText(find.byKey(const Key('usernameField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'app-password');
    await tester.pump();

    expect(saveButton().onPressed, isNotNull);
  });

  testWidgets('shows a Test connection button', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountFormScreen()),
    ));
    expect(find.widgetWithText(OutlinedButton, 'Test connection'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/account_form_screen_test.dart`
Expected: FAIL — placeholder `AccountFormScreen` has no such fields/buttons.

- [ ] **Step 3: Implement AccountFormScreen**

```dart
// lib/screens/account_form_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../providers/account_providers.dart';
import '../providers/repository_providers.dart';

class AccountFormScreen extends ConsumerStatefulWidget {
  const AccountFormScreen({super.key, this.existing});

  final MailAccount? existing;

  @override
  ConsumerState<AccountFormScreen> createState() => _AccountFormScreenState();
}

class _AccountFormScreenState extends ConsumerState<AccountFormScreen> {
  late final TextEditingController _displayName;
  late final TextEditingController _email;
  late final TextEditingController _imapHost;
  late final TextEditingController _imapPort;
  late final TextEditingController _smtpHost;
  late final TextEditingController _smtpPort;
  late final TextEditingController _username;
  final _password = TextEditingController();
  MailSecurity _imapSecurity = MailSecurity.ssl;
  MailSecurity _smtpSecurity = MailSecurity.ssl;
  String? _testResult;
  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _displayName = TextEditingController(text: existing?.displayName ?? '');
    _email = TextEditingController(text: existing?.email ?? '');
    _imapHost = TextEditingController(text: existing?.imapHost ?? '');
    _imapPort = TextEditingController(text: existing?.imapPort.toString() ?? '993');
    _smtpHost = TextEditingController(text: existing?.smtpHost ?? '');
    _smtpPort = TextEditingController(text: existing?.smtpPort.toString() ?? '465');
    _username = TextEditingController(text: existing?.username ?? '');
    _imapSecurity = existing?.imapSecurity ?? MailSecurity.ssl;
    _smtpSecurity = existing?.smtpSecurity ?? MailSecurity.ssl;
    for (final controller in [
      _displayName, _email, _imapHost, _imapPort, _smtpHost, _smtpPort, _username, _password,
    ]) {
      controller.addListener(() => setState(() {}));
    }
  }

  bool get _isValid =>
      _displayName.text.trim().isNotEmpty &&
      _email.text.trim().contains('@') &&
      _imapHost.text.trim().isNotEmpty &&
      int.tryParse(_imapPort.text.trim()) != null &&
      _smtpHost.text.trim().isNotEmpty &&
      int.tryParse(_smtpPort.text.trim()) != null &&
      _username.text.trim().isNotEmpty &&
      _password.text.isNotEmpty;

  MailAccount _buildAccount() {
    return MailAccount(
      id: widget.existing?.id,
      displayName: _displayName.text.trim(),
      email: _email.text.trim(),
      imapHost: _imapHost.text.trim(),
      imapPort: int.parse(_imapPort.text.trim()),
      imapSecurity: _imapSecurity,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.parse(_smtpPort.text.trim()),
      smtpSecurity: _smtpSecurity,
      username: _username.text.trim(),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final transport = ref.read(mailTransportProvider);
      await transport.testConnection(_buildAccount(), _password.text);
      setState(() => _testResult = 'Connection succeeded');
    } catch (e) {
      setState(() => _testResult = 'Connection failed: $e');
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(accountsProvider.notifier).add(_buildAccount(), _password.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _testResult = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add account' : 'Edit account')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(key: const Key('displayNameField'), controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name')),
          TextField(key: const Key('emailField'), controller: _email,
              decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 16),
          TextField(key: const Key('imapHostField'), controller: _imapHost,
              decoration: const InputDecoration(labelText: 'IMAP host')),
          TextField(key: const Key('imapPortField'), controller: _imapPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'IMAP port')),
          const SizedBox(height: 16),
          TextField(key: const Key('smtpHostField'), controller: _smtpHost,
              decoration: const InputDecoration(labelText: 'SMTP host')),
          TextField(key: const Key('smtpPortField'), controller: _smtpPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'SMTP port')),
          const SizedBox(height: 16),
          TextField(key: const Key('usernameField'), controller: _username,
              decoration: const InputDecoration(labelText: 'Username')),
          TextField(key: const Key('passwordField'), controller: _password, obscureText: true,
              decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _testing ? null : _testConnection,
            child: Text(_testing ? 'Testing...' : 'Test connection'),
          ),
          if (_testResult != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_testResult!),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isValid && !_saving ? _save : null,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Implement AccountListScreen**

```dart
// lib/screens/account_list_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import 'account_form_screen.dart';
import 'folder_view_screen.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts'), actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountFormScreen()),
          ),
        ),
      ]),
      body: accountsAsync.when(
        data: (accounts) => ListView.builder(
          itemCount: accounts.length,
          itemBuilder: (context, index) {
            final account = accounts[index];
            return ListTile(
              title: Text(account.displayName),
              subtitle: Text(account.email),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => FolderViewScreen(accountId: account.id!)),
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
      ),
    );
  }
}
```

Note: this introduces a forward reference to `FolderViewScreen` (Task 14). Add a minimal placeholder now so Task 13 compiles and its own test passes independently:

```dart
// lib/screens/folder_view_screen.dart
import 'package:flutter/material.dart';

class FolderViewScreen extends StatelessWidget {
  const FolderViewScreen({super.key, required this.accountId});

  final int accountId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Inbox')));
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/widget/account_form_screen_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/screens/account_form_screen.dart lib/screens/account_list_screen.dart lib/screens/folder_view_screen.dart test/widget/account_form_screen_test.dart
git commit -m "feat: add account list and add/edit account form screens"
```

---

### Task 14: Folder view screen (default tabs + expandable full tree, error banner)

**Files:**
- Modify: `lib/screens/folder_view_screen.dart`
- Create: `lib/widgets/folder_tab_bar.dart`, `lib/widgets/folder_tree_expander.dart`, `lib/widgets/message_list_tile.dart`, `lib/widgets/sync_error_banner.dart`
- Test: `test/widget/folder_view_screen_test.dart`

**Interfaces:**
- Consumes: `foldersProvider`, `messagesProvider` (Task 11), `MailFolder`, `MailMessage` (Task 1)
- Produces: `FolderViewScreen({required int accountId})` — shows Inbox/Sent/Trash as `FolderTabBar` entries (falling back gracefully if any are absent from the discovered tree), a "▾ More folders" `FolderTreeExpander` revealing the rest, a `ListView` of `MessageListTile`, pull-to-refresh (`RefreshIndicator`), and a `SyncErrorBanner` with Retry/Edit account actions when the folder/message providers report an error with no cached fallback.

- [ ] **Step 1: Write the failing widget tests**

```dart
// test/widget/folder_view_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/screens/folder_view_screen.dart';

void main() {
  const accountId = 1;
  final inbox = MailFolder(id: 1, accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final sent = MailFolder(id: 2, accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final trash = MailFolder(id: 3, accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final archive = MailFolder(id: 4, accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.other);

  testWidgets('shows Inbox/Sent/Trash by default, Archive hidden until expanded', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/folder_view_screen_test.dart`
Expected: FAIL — placeholder `FolderViewScreen` has none of this UI.

- [ ] **Step 3: Implement the widgets**

```dart
// lib/widgets/folder_tab_bar.dart
import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

class FolderTabBar extends StatelessWidget {
  const FolderTabBar({super.key, required this.folders, required this.selected, required this.onSelect});

  final List<MailFolder> folders;
  final MailFolder? selected;
  final ValueChanged<MailFolder> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: folders.map((folder) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(folder.name),
              selected: selected?.id == folder.id,
              onSelected: (_) => onSelect(folder),
            ),
          );
        }).toList(),
      ),
    );
  }
}
```

```dart
// lib/widgets/folder_tree_expander.dart
import 'package:flutter/material.dart';
import '../models/mail_folder.dart';

class FolderTreeExpander extends StatefulWidget {
  const FolderTreeExpander({super.key, required this.folders, required this.onSelect});

  final List<MailFolder> folders;
  final ValueChanged<MailFolder> onSelect;

  @override
  State<FolderTreeExpander> createState() => _FolderTreeExpanderState();
}

class _FolderTreeExpanderState extends State<FolderTreeExpander> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.arrow_drop_up : Icons.arrow_drop_down),
          label: const Text('More folders'),
        ),
        if (_expanded)
          ...widget.folders.map((folder) => ListTile(
                dense: true,
                title: Text(folder.name),
                onTap: () => widget.onSelect(folder),
              )),
      ],
    );
  }
}
```

```dart
// lib/widgets/message_list_tile.dart
import 'package:flutter/material.dart';
import '../models/mail_message.dart';

class MessageListTile extends StatelessWidget {
  const MessageListTile({super.key, required this.message, required this.onTap});

  final MailMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        message.subject,
        style: TextStyle(fontWeight: message.isRead ? FontWeight.normal : FontWeight.bold),
      ),
      subtitle: Text('${message.from} — ${message.snippet}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text('${message.date.toLocal().month}/${message.date.toLocal().day}'),
      onTap: onTap,
    );
  }
}
```

```dart
// lib/widgets/sync_error_banner.dart
import 'package:flutter/material.dart';

class SyncErrorBanner extends StatelessWidget {
  const SyncErrorBanner({super.key, required this.message, required this.onRetry, this.onEditAccount});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onEditAccount;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text("Can't sync: $message"),
      actions: [
        TextButton(onPressed: onRetry, child: const Text('Retry')),
        if (onEditAccount != null)
          TextButton(onPressed: onEditAccount, child: const Text('Edit account')),
      ],
    );
  }
}
```

- [ ] **Step 4: Implement FolderViewScreen**

```dart
// lib/screens/folder_view_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/enums.dart';
import '../models/mail_folder.dart';
import '../providers/folder_providers.dart';
import '../providers/message_providers.dart';
import '../widgets/folder_tab_bar.dart';
import '../widgets/folder_tree_expander.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/sync_error_banner.dart';
import 'account_form_screen.dart';
import 'message_detail_screen.dart';

class FolderViewScreen extends ConsumerStatefulWidget {
  const FolderViewScreen({super.key, required this.accountId});

  final int accountId;

  @override
  ConsumerState<FolderViewScreen> createState() => _FolderViewScreenState();
}

class _FolderViewScreenState extends ConsumerState<FolderViewScreen> {
  MailFolder? _selected;

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider(widget.accountId));

    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
      body: foldersAsync.when(
        data: (folders) {
          final defaults = <MailFolder>[
            for (final type in [MailFolderType.inbox, MailFolderType.sent, MailFolderType.trash])
              ...folders.where((f) => f.type == type),
          ];
          final rest = folders.where((f) => !defaults.contains(f)).toList();
          final current = _selected ?? (defaults.isNotEmpty ? defaults.first : (folders.isNotEmpty ? folders.first : null));

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: FolderTabBar(
                  folders: defaults,
                  selected: current,
                  onSelect: (folder) => setState(() => _selected = folder),
                ),
              ),
              FolderTreeExpander(
                folders: rest,
                onSelect: (folder) => setState(() => _selected = folder),
              ),
              const Divider(height: 1),
              if (current != null) Expanded(child: _MessageList(folder: current)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SyncErrorBanner(
          message: error.toString(),
          onRetry: () => ref.invalidate(foldersProvider(widget.accountId)),
          onEditAccount: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountFormScreen()),
          ),
        ),
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.folder});

  final MailFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(messagesProvider(folder));

    return messagesAsync.when(
      data: (messages) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(messagesProvider(folder)),
        child: ListView.builder(
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            return MessageListTile(
              message: message,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => MessageDetailScreen(folder: folder, message: message)),
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
}
```

Add a minimal `MessageDetailScreen` placeholder now (Task 15 replaces it) so this compiles:

```dart
// lib/screens/message_detail_screen.dart
import 'package:flutter/material.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';

class MessageDetailScreen extends StatelessWidget {
  const MessageDetailScreen({super.key, required this.folder, required this.message});

  final MailFolder folder;
  final MailMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(message.subject)));
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/widget/folder_view_screen_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/screens/folder_view_screen.dart lib/screens/message_detail_screen.dart lib/widgets/folder_tab_bar.dart lib/widgets/folder_tree_expander.dart lib/widgets/message_list_tile.dart lib/widgets/sync_error_banner.dart test/widget/folder_view_screen_test.dart
git commit -m "feat: add folder view screen with default tabs, expandable tree, and error banner"
```

---

### Task 15: Message detail screen (HTML/plain body, attachments)

**Files:**
- Modify: `lib/screens/message_detail_screen.dart`
- Create: `lib/widgets/attachment_tile.dart`
- Test: `test/widget/message_detail_screen_test.dart`

**Interfaces:**
- Consumes: `mailRepositoryProvider` (Task 11), `MailMessage`, `MailAttachment` (Task 1)
- Produces: `MessageDetailScreen({required MailFolder folder, required MailMessage message})` — fetches body via `mailRepository.fetchBodyIfNeeded` on load, renders `bodyHtml` via `flutter_widget_from_html` when present else `bodyText`, lists attachments as `AttachmentTile` with a download action that fetches bytes via `mailRepository.downloadAttachment`, writes them to `(await getApplicationDocumentsDirectory()).path/filename` and calls `mailRepository.recordAttachmentLocalPath`.

- [ ] **Step 1: Write the failing widget test**

```dart
// test/widget/message_detail_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';

void main() {
  final folder = MailFolder(id: 1, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);

  testWidgets('renders plain text body when no HTML is present', (tester) async {
    final message = MailMessage(
      id: 10,
      folderId: 1,
      uid: 1,
      subject: 'Hello',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'Hi',
      bodyText: 'Hi there, this is the plain body.',
      isDownloaded: true,
    );

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: MessageDetailScreen(folder: folder, message: message)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Hi there, this is the plain body.'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/message_detail_screen_test.dart`
Expected: FAIL — placeholder screen doesn't render body.

- [ ] **Step 3: Implement AttachmentTile**

```dart
// lib/widgets/attachment_tile.dart
import 'package:flutter/material.dart';
import '../models/mail_attachment.dart';

class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.attachment, required this.onDownload, this.downloading = false});

  final MailAttachment attachment;
  final VoidCallback onDownload;
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.attach_file),
      title: Text(attachment.filename),
      subtitle: Text('${(attachment.size / 1024).toStringAsFixed(1)} KB'),
      trailing: attachment.localPath != null
          ? const Icon(Icons.check_circle, color: Colors.green)
          : IconButton(
              icon: downloading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              onPressed: downloading ? null : onDownload,
            ),
    );
  }
}
```

- [ ] **Step 4: Implement MessageDetailScreen**

```dart
// lib/screens/message_detail_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/repository/mail_repository.dart';
import '../models/mail_account.dart';
import '../models/mail_attachment.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/repository_providers.dart';
import '../widgets/attachment_tile.dart';

class MessageDetailScreen extends ConsumerStatefulWidget {
  const MessageDetailScreen({super.key, required this.folder, required this.message});

  final MailFolder folder;
  final MailMessage message;

  @override
  ConsumerState<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends ConsumerState<MessageDetailScreen> {
  MailMessage? _resolved;
  List<MailAttachment> _attachments = [];
  int? _downloadingAttachmentId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repository = await ref.read(mailRepositoryProvider.future);
    final accounts = await ref.read(accountsProvider.future);
    final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
    final resolved = await repository.fetchBodyIfNeeded(account, widget.folder, widget.message);
    if (mounted) setState(() => _resolved = resolved);
  }

  Future<void> _downloadAttachment(MailAttachment attachment) async {
    setState(() => _downloadingAttachmentId = attachment.id);
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
      final bytes = await repository.downloadAttachment(account, widget.folder, widget.message, attachment);
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, attachment.filename));
      await file.writeAsBytes(bytes);
      await repository.recordAttachmentLocalPath(attachment.id!, file.path);
      if (mounted) {
        setState(() {
          _attachments = _attachments
              .map((a) => a.id == attachment.id ? a.copyWith(localPath: file.path) : a)
              .toList();
        });
      }
    } finally {
      if (mounted) setState(() => _downloadingAttachmentId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _resolved ?? widget.message;
    return Scaffold(
      appBar: AppBar(title: Text(message.subject)),
      body: message.isDownloaded
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(message.subject, style: Theme.of(context).textTheme.titleLarge),
                Text('From: ${message.from}'),
                Text('To: ${message.to}'),
                const Divider(),
                if (message.bodyHtml != null)
                  HtmlWidget(message.bodyHtml!)
                else
                  Text(message.bodyText ?? ''),
                const Divider(),
                ..._attachments.map((attachment) => AttachmentTile(
                      attachment: attachment,
                      downloading: _downloadingAttachmentId == attachment.id,
                      onDownload: () => _downloadAttachment(attachment),
                    )),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/widget/message_detail_screen_test.dart`
Expected: PASS (1 test)

- [ ] **Step 6: Commit**

```bash
git add lib/screens/message_detail_screen.dart lib/widgets/attachment_tile.dart test/widget/message_detail_screen_test.dart
git commit -m "feat: add message detail screen with HTML rendering and attachment download"
```

---

### Task 16: Compose screen (new/reply/forward, attach, send)

**Files:**
- Create: `lib/screens/compose_screen.dart`
- Test: `test/widget/compose_screen_test.dart`

**Interfaces:**
- Consumes: `sendMessageProvider`, `accountsProvider` (Task 11), `ComposedMessage` (Task 7)
- Produces: `ComposeScreen({required int accountId, MailMessage? replyTo, MailMessage? forwardOf})` — To/Cc/Bcc/Subject/Body fields (pre-filled for reply/forward), a file-attach button (`file_picker`), a Send button disabled until at least one recipient and non-empty body, shows an inline error (message retained, not cleared) if `sendMessageProvider` throws.

- [ ] **Step 1: Write the failing widget test**

```dart
// test/widget/compose_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/compose_providers.dart';
import 'package:imap_mail/screens/compose_screen.dart';

void main() {
  testWidgets('Send is disabled until a recipient and body are entered', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');
    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNotNull);
  });

  testWidgets('shows an inline error and keeps content when send fails', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sendMessageProvider.overrideWithValue((MailAccount account, ComposedMessage message) async {
          throw Exception('smtp unreachable');
        }),
      ],
      child: const MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('smtp unreachable'), findsOneWidget);
    expect(find.text('Hello Bob'), findsOneWidget); // body field still has the content
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/compose_screen_test.dart`
Expected: FAIL — `compose_screen.dart` doesn't exist.

- [ ] **Step 3: Implement ComposeScreen**

```dart
// lib/screens/compose_screen.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/transport/mail_sender.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/compose_providers.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, required this.accountId, this.replyTo, this.forwardOf});

  final int accountId;
  final MailMessage? replyTo;
  final MailMessage? forwardOf;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  late final TextEditingController _to;
  late final TextEditingController _cc = TextEditingController();
  late final TextEditingController _subject;
  late final TextEditingController _body;
  final List<String> _attachmentPaths = [];
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final source = widget.replyTo ?? widget.forwardOf;
    _to = TextEditingController(text: widget.replyTo?.from ?? '');
    _subject = TextEditingController(
      text: source == null
          ? ''
          : widget.replyTo != null
              ? 'Re: ${source.subject}'
              : 'Fwd: ${source.subject}',
    );
    _body = TextEditingController(
      text: widget.forwardOf != null ? '\n\n---\n${widget.forwardOf!.bodyText ?? ''}' : '',
    );
    for (final controller in [_to, _cc, _subject, _body]) {
      controller.addListener(() => setState(() {}));
    }
  }

  bool get _isValid => _to.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path != null) setState(() => _attachmentPaths.add(path));
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.accountId);
      final composed = ComposedMessage(
        to: _to.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        cc: _cc.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        bcc: const [],
        subject: _subject.text.trim(),
        bodyText: _body.text,
        bodyHtml: null,
        attachmentFilePaths: _attachmentPaths,
      );
      final send = ref.read(sendMessageProvider);
      await send(account, composed);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compose')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(key: const Key('toField'), controller: _to,
              decoration: const InputDecoration(labelText: 'To')),
          TextField(key: const Key('ccField'), controller: _cc,
              decoration: const InputDecoration(labelText: 'Cc')),
          TextField(key: const Key('subjectField'), controller: _subject,
              decoration: const InputDecoration(labelText: 'Subject')),
          TextField(key: const Key('bodyField'), controller: _body, maxLines: 10,
              decoration: const InputDecoration(labelText: 'Message')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickAttachment,
            icon: const Icon(Icons.attach_file),
            label: Text(_attachmentPaths.isEmpty ? 'Attach file' : '${_attachmentPaths.length} attached'),
          ),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isValid && !_sending ? _send : null,
            child: Text(_sending ? 'Sending...' : 'Send'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/compose_screen_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/screens/compose_screen.dart test/widget/compose_screen_test.dart
git commit -m "feat: add compose screen with reply/forward, attachments, and error handling"
```

---

### Task 17: Settings screen (manage accounts) + wire up reply/forward/compose entry points

**Files:**
- Create: `lib/screens/settings_screen.dart`
- Modify: `lib/screens/account_list_screen.dart` (add a settings action), `lib/screens/folder_view_screen.dart` (add a compose FAB), `lib/screens/message_detail_screen.dart` (add reply/forward/delete actions)
- Test: `test/widget/settings_screen_test.dart`

**Interfaces:**
- Consumes: `accountsProvider` (Task 11)
- Produces: `SettingsScreen` — lists accounts with Edit (pushes `AccountFormScreen(existing: account)`) and Remove (confirmation `AlertDialog`, then `accountsProvider.notifier.remove`) actions.

- [ ] **Step 1: Write the failing widget test**

```dart
// test/widget/settings_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/screens/settings_screen.dart';

void main() {
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

  testWidgets('tapping Remove shows a confirmation dialog', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Remove this account?'), findsOneWidget);
  });
}

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widget/settings_screen_test.dart`
Expected: FAIL — `settings_screen.dart` doesn't exist.

- [ ] **Step 3: Implement SettingsScreen**

```dart
// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/account_providers.dart';
import 'account_form_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, int accountId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: const Text('This deletes its cached mail and stored password from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(accountsProvider.notifier).remove(accountId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: accountsAsync.when(
        data: (accounts) => ListView.builder(
          itemCount: accounts.length,
          itemBuilder: (context, index) {
            final account = accounts[index];
            return ListTile(
              title: Text(account.displayName),
              subtitle: Text(account.email),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => AccountFormScreen(existing: account)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmRemove(context, ref, account.id!),
                  ),
                ],
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed to load accounts: $error')),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widget/settings_screen_test.dart`
Expected: PASS (1 test)

- [ ] **Step 5: Wire up navigation entry points**

```dart
// lib/screens/account_list_screen.dart — add a settings action to the AppBar's actions list:
IconButton(
  icon: const Icon(Icons.settings_outlined),
  onPressed: () => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const SettingsScreen()),
  ),
),
```
(add `import 'settings_screen.dart';` at the top)

```dart
// lib/screens/folder_view_screen.dart — add a FAB to the Scaffold in _FolderViewScreenState.build:
floatingActionButton: FloatingActionButton(
  onPressed: () => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ComposeScreen(accountId: widget.accountId)),
  ),
  child: const Icon(Icons.edit),
),
```
(add `import 'compose_screen.dart';` at the top)

```dart
// lib/screens/message_detail_screen.dart — add reply/forward/delete actions to the AppBar:
appBar: AppBar(
  title: Text(message.subject),
  actions: [
    IconButton(
      icon: const Icon(Icons.reply),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ComposeScreen(
          accountId: widget.folder.accountId,
          replyTo: message,
        )),
      ),
    ),
    IconButton(
      icon: const Icon(Icons.forward),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ComposeScreen(
          accountId: widget.folder.accountId,
          forwardOf: message,
        )),
      ),
    ),
  ],
),
```
(add `import 'compose_screen.dart';` at the top)

- [ ] **Step 6: Run the full test suite to confirm nothing regressed**

Run: `flutter test`
Expected: PASS (all tests across every task)

- [ ] **Step 7: Commit**

```bash
git add lib/screens
git commit -m "feat: add settings screen and wire up compose/reply/forward/settings navigation"
```

---

## Manual verification (not automated — do before considering this done)

The spec explicitly scopes `EnoughMailTransport`/`EnoughMailSender` network calls out of the automated test suite. Before relying on the app:

1. Run `flutter analyze` and confirm no errors.
2. Run `flutter test` and confirm the full suite passes.
3. Run the app on a real device/simulator (`flutter run`) against a real IMAP/SMTP account (an app-password-based Gmail or a personal mail server both work) and manually verify: add account with a deliberately wrong password (see the Test Connection failure), add it correctly, see Inbox populate, expand "More folders", open a message with an attachment and download it, compose and send a plain message, compose and send with an attachment, reply and forward pre-fill correctly, turn off networking mid-send to see the Outbox/failed-send path, remove the account and confirm its cached mail disappears.
