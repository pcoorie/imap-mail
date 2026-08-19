import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/transport/mail_sender.dart';
import '../models/mail_account.dart';
import 'repository_providers.dart';

final sendMessageProvider = Provider<Future<void> Function(MailAccount, ComposedMessage)>((ref) {
  return (account, composed) async {
    final repository = await ref.read(mailRepositoryProvider.future);
    await repository.sendMessage(account, composed);
  };
});
