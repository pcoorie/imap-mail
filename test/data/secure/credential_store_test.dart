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
