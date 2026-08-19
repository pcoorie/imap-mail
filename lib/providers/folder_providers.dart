import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_folder.dart';
import 'account_providers.dart';
import 'repository_providers.dart';

final foldersProvider = FutureProvider.family<List<MailFolder>, int>((ref, accountId) async {
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final account = accounts.firstWhere((a) => a.id == accountId);
  try {
    return await repository.syncFolders(account);
  } catch (_) {
    final cached = await repository.getCachedFolders(accountId);
    if (cached.isEmpty) rethrow;
    return cached;
  }
});
