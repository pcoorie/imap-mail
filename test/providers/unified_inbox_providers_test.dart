import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  const workAccount = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personalAccount = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 3);
  final workSent = MailFolder(id: 11, accountId: 1, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox, unreadCount: 5);

  MailMessage msg({required int id, required int folderId, required DateTime date}) => MailMessage(
        id: id, folderId: folderId, uid: id, subject: 'Subject $id', from: 'a@example.com',
        to: 'me@example.com', date: date, snippet: 'snippet',
      );

  test('unifiedInboxProvider merges only Inbox folders across accounts, sorted newest-first', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) {
          return [msg(id: 1, folderId: 10, date: DateTime.utc(2026, 8, 20))];
        }
        if (folder.id == personalInbox.id) {
          return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
        }
        fail('messagesProvider should never be called for a non-inbox folder');
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2, 1]); // personal (8/21) before work (8/20)
    expect(result[0].account, personalAccount);
    expect(result[1].account, workAccount);
  });

  test('unifiedInboxProvider treats a failed, cache-empty account as contributing zero rows, and records its error', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox] : [personalInbox]),
      messagesProvider.overrideWith((ref, folder) async {
        if (folder.id == workInbox.id) throw Exception('connection refused');
        return [msg(id: 2, folderId: 20, date: DateTime.utc(2026, 8, 21))];
      }),
    ]);
    addTearDown(container.dispose);

    final result = await container.read(unifiedInboxProvider.future);

    expect(result.map((u) => u.message.id), [2]);
    expect(container.read(syncErrorProvider(1)), contains('connection refused'));
  });

  test('totalUnreadCountProvider sums unread counts across accounts\' Inbox folders only', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async =>
          accountId == 1 ? [workInbox, workSent] : [personalInbox]),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 8); // 3 + 5
  });

  test('totalUnreadCountProvider treats a failed account as contributing zero, not throwing', () async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([workAccount, personalAccount])),
      foldersProvider.overrideWith((ref, accountId) async {
        if (accountId == 1) throw Exception('offline');
        return [personalInbox];
      }),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(totalUnreadCountProvider.future), 5);
  });
}
