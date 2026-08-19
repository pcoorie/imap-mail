import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:imap_mail/data/local/app_database.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/database_providers.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/data/transport/mail_transport.dart';
import 'package:imap_mail/providers/repository_providers.dart';

class MockMailTransport extends Mock implements MailTransport {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // accountsProvider is exercised end-to-end here (it is not overridden),
  // so it goes through the real credentialStoreProvider -> SecureCredentialStore
  // -> flutter_secure_storage platform channel. Mock that channel the same way
  // test/data/secure/credential_store_test.dart does, since nothing in the
  // brief's overrides list stubs it out.
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureStorageBacking = <String, String>{};

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(const MailAccount(
      displayName: '',
      email: '',
      imapHost: '',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: '',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: '',
    ));
  });

  setUp(() {
    secureStorageBacking.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      switch (call.method) {
        case 'write':
          secureStorageBacking[call.arguments['key'] as String] =
              call.arguments['value'] as String;
          return null;
        case 'read':
          return secureStorageBacking[call.arguments['key'] as String];
        case 'delete':
          secureStorageBacking.remove(call.arguments['key'] as String);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('accountsProvider starts empty, add() persists and refreshes the list', () async {
    final transport = MockMailTransport();
    when(() => transport.testConnection(any(), any())).thenAnswer((_) async {});

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        return databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(version: 1, onCreate: AppDatabase.onCreate),
        );
      }),
      mailTransportProvider.overrideWithValue(transport),
    ]);
    addTearDown(container.dispose);

    final initial = await container.read(accountsProvider.future);
    expect(initial, isEmpty);

    const account = MailAccount(
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    );
    await container.read(accountsProvider.notifier).add(account, 'app-password');

    final after = await container.read(accountsProvider.future);
    expect(after, hasLength(1));
  });
}
