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
