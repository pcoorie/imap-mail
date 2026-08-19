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
      await _credentialStore.savePassword(
        accountId: account.id!,
        password: newPassword,
      );
    }
    await _accountDao.update(account);
  }

  Future<void> removeAccount(int accountId) async {
    await _accountDao.delete(accountId);
    await _credentialStore.deletePassword(accountId);
  }
}
