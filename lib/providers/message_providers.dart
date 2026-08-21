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
    ref.read(syncErrorProvider(folder.accountId).notifier).state = null;
    // syncHeaders recomputes and persists this folder's true unread count
    // (see MailRepository); bump the tick so totalUnreadCountProvider
    // re-reads it instead of serving a now-stale cached sum.
    ref.read(unreadCountRefreshTickProvider.notifier).state++;
    return messages;
  } catch (e) {
    final cached = await repository.getCachedMessages(folder.id!);
    if (cached.isEmpty) rethrow;
    ref.read(syncErrorProvider(folder.accountId).notifier).state = e.toString();
    return cached;
  }
});
