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
