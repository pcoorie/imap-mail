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
    // Re-discovering a folder from the transport produces a fresh MailFolder
    // that doesn't know the locally-tracked sync watermark (it would default
    // to 0). Never let a re-sync of folder metadata regress it. Same reason
    // for unread_count: the transport layer never populates it (this app
    // computes it locally from the messages table — see
    // MailRepository._refreshUnreadCount), so a freshly-discovered MailFolder
    // always carries the default 0 here; blindly writing it back on every
    // folder sync would wipe out whatever MailRepository had already
    // recomputed.
    final map = folder.toMap()
      ..remove('id')
      ..remove('last_synced_uid')
      ..remove('unread_count');
    await _db.update(
      'folders',
      map,
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<void> updateLastSyncedUid(int id, int uid) async {
    await _db.update(
      'folders',
      {'last_synced_uid': uid},
      where: 'id = ?',
      whereArgs: [id],
    );
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
