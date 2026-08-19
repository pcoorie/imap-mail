import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/local/account_dao.dart';
import '../data/local/attachment_dao.dart';
import '../data/local/folder_dao.dart';
import '../data/local/message_dao.dart';
import '../data/repository/account_repository.dart';
import '../data/repository/mail_repository.dart';
import '../data/secure/credential_store.dart';
import '../data/transport/enough_mail_sender.dart';
import '../data/transport/enough_mail_transport.dart';
import '../data/transport/mail_sender.dart';
import '../data/transport/mail_transport.dart';
import 'database_providers.dart';

final credentialStoreProvider = Provider<SecureCredentialStore>((ref) => SecureCredentialStore());

final mailTransportProvider = Provider<MailTransport>((ref) => EnoughMailTransport());

final mailSenderProvider = Provider<MailSender>((ref) => EnoughMailSender());

final accountRepositoryProvider = FutureProvider<AccountRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return AccountRepository(
    AccountDao(db),
    ref.watch(credentialStoreProvider),
    ref.watch(mailTransportProvider),
  );
});

final mailRepositoryProvider = FutureProvider<MailRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return MailRepository(
    FolderDao(db),
    MessageDao(db),
    AttachmentDao(db),
    ref.watch(mailTransportProvider),
    ref.watch(credentialStoreProvider),
    ref.watch(mailSenderProvider),
  );
});
