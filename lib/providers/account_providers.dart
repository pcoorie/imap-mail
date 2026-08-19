import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_account.dart';
import 'repository_providers.dart';

class AccountsNotifier extends AsyncNotifier<List<MailAccount>> {
  @override
  Future<List<MailAccount>> build() async {
    final repository = await ref.watch(accountRepositoryProvider.future);
    return repository.listAccounts();
  }

  Future<void> add(MailAccount account, String password) async {
    final repository = await ref.read(accountRepositoryProvider.future);
    await repository.addAccount(account, password);
    ref.invalidateSelf();
    await future;
  }

  Future<void> remove(int id) async {
    final repository = await ref.read(accountRepositoryProvider.future);
    await repository.removeAccount(id);
    ref.invalidateSelf();
    await future;
  }
}

final accountsProvider = AsyncNotifierProvider<AccountsNotifier, List<MailAccount>>(
  AccountsNotifier.new,
);
