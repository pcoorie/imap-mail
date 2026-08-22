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

  test('onUpgrade from version 2 adds from_name without losing existing data', () async {
    final dir = await Directory.systemTemp.createTemp('imap_mail_migration_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'test.db');

    // Simulate a pre-migration (version 2) database using the schema
    // AppDatabase.onCreate produced before from_name existed.
    final oldDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
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
              is_flagged INTEGER NOT NULL DEFAULT 0,
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
        version: 3,
        onCreate: AppDatabase.onCreate,
        onUpgrade: AppDatabase.onUpgrade,
      ),
    );
    addTearDown(upgradedDb.close);

    final rows = await upgradedDb.query('messages', where: 'id = ?', whereArgs: [messageId]);
    expect(rows, hasLength(1));
    expect(rows.first['from_name'], isNull);
    expect(rows.first['subject'], 'Pre-migration message');
  });

  test('a fresh (onCreate) database already has the from_name column', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 3, onCreate: AppDatabase.onCreate),
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
      'from_name': 'Alice',
      'to_address': 'me@example.com',
      'date': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'snippet': 'snippet',
    });

    final rows = await db.query('messages', where: 'id = ?', whereArgs: [messageId]);
    expect(rows.first['from_name'], 'Alice');
  });
}
