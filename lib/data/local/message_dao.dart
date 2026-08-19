import 'package:sqflite/sqflite.dart';
import '../../models/enums.dart';
import '../../models/mail_message.dart';

class MessageDao {
  MessageDao(this._db);

  final Database _db;

  Future<void> upsertHeaders(List<MailMessage> messages) async {
    // Resolve which messages already have a cached row before building the
    // batch, since Database.batch() cannot branch mid-batch.
    final existingIds = <int?>[];
    for (final message in messages) {
      final rows = await _db.query(
        'messages',
        columns: ['id'],
        where: 'folder_id = ? AND uid = ?',
        whereArgs: [message.folderId, message.uid],
      );
      existingIds.add(rows.isEmpty ? null : rows.first['id'] as int);
    }

    final batch = _db.batch();
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final existingId = existingIds[i];
      if (existingId == null) {
        final map = message.toMap()..remove('id');
        batch.insert('messages', map);
      } else {
        final map = <String, Object?>{
          'subject': message.subject,
          'from_address': message.from,
          'to_address': message.to,
          'date': message.date.toUtc().millisecondsSinceEpoch,
          'snippet': message.snippet,
          'is_read': message.isRead ? 1 : 0,
        };
        if (message.isDownloaded) {
          map['body_text'] = message.bodyText;
          map['body_html'] = message.bodyHtml;
          map['is_downloaded'] = 1;
        }
        batch.update(
          'messages',
          map,
          where: 'id = ?',
          whereArgs: [existingId],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  Future<int> insertLocal(MailMessage message) async {
    final rows = await _db.rawQuery(
      'SELECT MIN(uid) as min_uid FROM messages WHERE folder_id = ?',
      [message.folderId],
    );
    final minUid = rows.first['min_uid'] as int?;
    final uid = (minUid == null || minUid >= 0) ? -1 : minUid - 1;

    final map = message.toMap()
      ..remove('id')
      ..['uid'] = uid;
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

  Future<void> deleteMessage(int id) async {
    await _db.delete('messages', where: 'id = ?', whereArgs: [id]);
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
