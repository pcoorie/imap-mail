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

  /// Named `updateAccount` (not `update`) because `AsyncNotifier` already
  /// declares an `update(cb)` method for functional state updates; reusing
  /// that name here would be an invalid override (different signature).
  Future<void> updateAccount(MailAccount account, {String? newPassword}) async {
    final repository = await ref.read(accountRepositoryProvider.future);
    await repository.updateAccount(account, newPassword: newPassword);
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
