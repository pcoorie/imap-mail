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
