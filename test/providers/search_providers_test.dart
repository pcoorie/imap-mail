// test/providers/search_providers_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/search_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/models/unified_message.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class MockMailRepository extends Mock implements MailRepository {}

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final workTrash = MailFolder(id: 11, accountId: 1, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final workOutbox = MailFolder(
    id: 12, accountId: 1, name: 'Outbox', path: 'Outbox', type: MailFolderType.other, isLocalOnly: true,
  );
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);

  MailMessage msg({
    required int id,
    required int folderId,
    required String subject,
    String from = 'a@example.com',
    String? fromName,
    String snippet = 'snippet',
    required DateTime date,
  }) =>
      MailMessage(
        id: id, folderId: folderId, uid: id, subject: subject, from: from,
        fromName: fromName, to: 'me@example.com', date: date, snippet: snippet,
      );

  late MockMailRepository repository;
  late ProviderContainer container;

  setUp(() {
    repository = MockMailRepository();
    container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
      mailRepositoryProvider.overrideWith((ref) async => repository),
    ]);
    addTearDown(container.dispose);
  });

  test('a blank query returns no results without touching the repository', () async {
    final result = await container.read(searchResultsProvider('   ').future);

    expect(result, isEmpty);
    verifyNever(() => repository.getCachedFolders(any()));
  });

  test(
      'matches subject, sender name, sender address, and snippet, case-insensitively, '
      'across accounts and folders, newest match first', () async {
    when(() => repository.getCachedFolders(1)).thenAnswer((_) async => [workInbox, workTrash]);
    when(() => repository.getCachedFolders(2)).thenAnswer((_) async => [personalInbox]);
    when(() => repository.getCachedMessages(10)).thenAnswer((_) async => [
          msg(id: 1, folderId: 10, subject: 'Invoice attached', date: DateTime.utc(2026, 8, 20)),
        ]);
    when(() => repository.getCachedMessages(11)).thenAnswer((_) async => [
          msg(id: 2, folderId: 11, subject: 'Old', fromName: 'Invoice Bot', date: DateTime.utc(2026, 8, 19)),
        ]);
    when(() => repository.getCachedMessages(20)).thenAnswer((_) async => [
          msg(id: 3, folderId: 20, subject: 'Party', from: 'invoice@example.com', date: DateTime.utc(2026, 8, 21)),
          msg(id: 4, folderId: 20, subject: 'Unrelated', snippet: 'see attached INVOICE', date: DateTime.utc(2026, 8, 18)),
          msg(id: 5, folderId: 20, subject: 'No match here', date: DateTime.utc(2026, 8, 17)),
        ]);

    final result = await container.read(searchResultsProvider('invoice').future);

    // id 5 matches nothing and is excluded; the rest sort newest-first.
    expect(result.map((u) => u.message.id), [3, 1, 2, 4]);
  });

  test('excludes local-only folders (e.g. Outbox) without even reading their messages', () async {
    when(() => repository.getCachedFolders(1)).thenAnswer((_) async => [workOutbox]);
    when(() => repository.getCachedFolders(2)).thenAnswer((_) async => []);

    final result = await container.read(searchResultsProvider('invoice').future);

    expect(result, isEmpty);
    verifyNever(() => repository.getCachedMessages(12));
  });

  test(
      'bumping unreadCountRefreshTickProvider re-runs an already-resolved search and picks up '
      "new cache data — the same signal MessageSwipeController.performSwipeAction bumps after "
      'every archive/delete/flag/toggleRead, and that messagesProvider syncs bump too', () async {
    when(() => repository.getCachedFolders(1)).thenAnswer((_) async => [workInbox]);
    when(() => repository.getCachedFolders(2)).thenAnswer((_) async => [personalInbox]);
    when(() => repository.getCachedMessages(20)).thenAnswer((_) async => []);
    when(() => repository.getCachedMessages(10)).thenAnswer((_) async => [
          msg(id: 1, folderId: 10, subject: 'Invoice attached', date: DateTime.utc(2026, 8, 20)),
        ]);

    // Keep the provider alive across the tick bump with a real listener —
    // a one-shot container.read(...future) would trivially "work" via a
    // fresh read regardless of whether the fix is real, since a fresh read
    // always re-evaluates the builder. A kept-alive listener is the only
    // way to prove the *same* live provider instance re-runs in response
    // to the tick, rather than just being recreated by a new read.
    final emissions = <AsyncValue<List<UnifiedMessage>>>[];
    final sub = container.listen<AsyncValue<List<UnifiedMessage>>>(
      searchResultsProvider('invoice'),
      (previous, next) => emissions.add(next),
      fireImmediately: true,
    );
    addTearDown(sub.close);

    // Let the first resolution land.
    final first = await container.read(searchResultsProvider('invoice').future);
    expect(first.map((u) => u.message.id), [1]);

    // Simulate the local cache changing underneath the still-alive provider
    // (e.g. a new message synced in, or a swipe action mutated the cache).
    when(() => repository.getCachedMessages(10)).thenAnswer((_) async => [
          msg(id: 1, folderId: 10, subject: 'Invoice attached', date: DateTime.utc(2026, 8, 20)),
          msg(id: 2, folderId: 10, subject: 'Invoice reminder', date: DateTime.utc(2026, 8, 22)),
        ]);

    // The exact bump MessageSwipeController.performSwipeAction performs.
    container.read(unreadCountRefreshTickProvider.notifier).state++;

    // Read through the *same* family key again — with autoDispose + a live
    // listener, this observes the provider's own recomputed future rather
    // than tearing it down and rebuilding from scratch.
    final second = await container.read(searchResultsProvider('invoice').future);

    expect(second.map((u) => u.message.id), [2, 1]);
    // The kept-alive listener actually observed a second data emission
    // reflecting the new cache contents, proving the provider itself
    // re-ran rather than merely being re-read.
    final dataEmissions = emissions.whereType<AsyncData<List<UnifiedMessage>>>().toList();
    expect(dataEmissions.length, greaterThanOrEqualTo(2));
    expect(dataEmissions.last.value.map((u) => u.message.id), [2, 1]);
  });
}
