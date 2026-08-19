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
