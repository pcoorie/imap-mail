import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_folder.dart';
import 'account_providers.dart';
import 'repository_providers.dart';
import 'sync_status_providers.dart';

final foldersProvider = FutureProvider.family<List<MailFolder>, int>((ref, accountId) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == accountId);
  try {
    final folders = await repository.syncFolders(account);
    ref.read(syncErrorProvider(accountId).notifier).state = null;
    return folders;
  } catch (e) {
    final cached = await repository.getCachedFolders(accountId);
    if (cached.isEmpty) rethrow;
    ref.read(syncErrorProvider(accountId).notifier).state = e.toString();
    return cached;
  }
});
