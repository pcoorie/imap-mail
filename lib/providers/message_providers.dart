import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import 'account_providers.dart';
import 'repository_providers.dart';
import 'sync_status_providers.dart';

final messagesProvider = FutureProvider.family<List<MailMessage>, MailFolder>((ref, folder) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == folder.accountId);
  try {
    final messages = await repository.syncHeaders(account, folder);
    ref.read(lastSyncErrorProvider.notifier).state = null;
    return messages;
  } catch (e) {
    final cached = await repository.getCachedMessages(folder.id!);
    if (cached.isEmpty) rethrow;
    ref.read(lastSyncErrorProvider.notifier).state = e.toString();
    return cached;
  }
});
