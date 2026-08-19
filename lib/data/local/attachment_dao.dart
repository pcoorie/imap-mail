import 'package:sqflite/sqflite.dart';
import '../../models/mail_attachment.dart';

class AttachmentDao {
  AttachmentDao(this._db);

  final Database _db;

  Future<void> insertAll(List<MailAttachment> attachments) async {
    final batch = _db.batch();
    for (final attachment in attachments) {
      // Re-fetching a message's attachment list (e.g. re-opening it) can
      // observe the same (message_id, filename) again; replace rather than
      // duplicate, mirroring MessageDao.upsertHeaders's dedupe intent.
      batch.insert(
        'attachments',
        attachment.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
