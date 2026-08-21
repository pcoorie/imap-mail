import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/badge_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/services/app_icon_badge.dart';
import 'package:imap_mail/models/mail_folder.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeAppIconBadge implements AppIconBadge {
  final List<int> calls = [];
  @override
  Future<void> setCount(int count) async => calls.add(count);
}

void main() {
  const account = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  final inbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 3);

  test('listening to totalUnreadCountProvider pushes its value to AppIconBadge', () async {
    final fakeBadge = _FakeAppIconBadge();
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      foldersProvider.overrideWith((ref, accountId) async => [inbox]),
      appIconBadgeProvider.overrideWithValue(fakeBadge),
    ]);
    addTearDown(container.dispose);

    // Mirrors what app.dart's root-level ref.listen does.
    container.listen<AsyncValue<int>>(totalUnreadCountProvider, (previous, next) {
      final count = next.valueOrNull;
      if (count != null) container.read(appIconBadgeProvider).setCount(count);
    }, fireImmediately: true);

    await container.read(totalUnreadCountProvider.future);
    // Let the listener's fire-immediately callback's inner Future settle.
    await Future<void>.delayed(Duration.zero);

    expect(fakeBadge.calls, [3]);
  });

  test('reaching zero unread sends setCount(0), clearing a stale badge', () async {
    final fakeBadge = _FakeAppIconBadge();
    final zeroInbox = inbox.copyWith(unreadCount: 0);
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      foldersProvider.overrideWith((ref, accountId) async => [zeroInbox]),
      appIconBadgeProvider.overrideWithValue(fakeBadge),
    ]);
    addTearDown(container.dispose);

    container.listen<AsyncValue<int>>(totalUnreadCountProvider, (previous, next) {
      final count = next.valueOrNull;
      if (count != null) container.read(appIconBadgeProvider).setCount(count);
    }, fireImmediately: true);

    await container.read(totalUnreadCountProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(fakeBadge.calls, [0]);
  });
}
