import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/models/unified_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/screens/unified_inbox_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  _FakeSwipeActionConfigNotifier(this._initial);
  final SwipeActionConfig _initial;
  @override
  SwipeActionConfig build() => _initial;
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
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final workMessage = MailMessage(
    id: 100, folderId: 10, uid: 1, subject: 'From work', from: 'a@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 20), snippet: 'Hi',
  );
  final personalMessage = MailMessage(
    id: 200, folderId: 20, uid: 1, subject: 'From personal', from: 'b@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 21), snippet: 'Hey',
  );

  setUpAll(() {
    registerFallbackValue(work);
    registerFallbackValue(workInbox);
    registerFallbackValue(workMessage);
  });

  testWidgets('renders merged rows from every account, newest first', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => [
              UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
              UnifiedMessage(message: workMessage, folder: workInbox, account: work),
            ]),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('From work'), findsOneWidget);
    expect(find.text('From personal'), findsOneWidget);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles[0].title as Text).data, 'From personal'); // newest first
    expect((tiles[1].title as Text).data, 'From work');
  });

  testWidgets('a full swipe archives the row against its OWN account, not a fixed one', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = personalMessage.copyWith(folderId: 999);
    var archived = false;
    when(() => repository.archiveMessage(personal, personalInbox, personalMessage)).thenAnswer((_) async {
      archived = true;
      return archivedMessage;
    });
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => archived
            ? [UnifiedMessage(message: workMessage, folder: workInbox, account: work)]
            : [
                UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
                UnifiedMessage(message: workMessage, folder: workInbox, account: work),
              ]),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.timedDrag(find.text('From personal'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    verify(() => repository.archiveMessage(personal, personalInbox, personalMessage)).called(1);
  });

  testWidgets('compose FAB opens the account picker with 2+ accounts and pushes ComposeScreen for the chosen one', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        unifiedInboxProvider.overrideWith((ref) async => []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    expect(find.text('Compose from'), findsOneWidget);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(find.text('Compose'), findsOneWidget); // ComposeScreen's AppBar title
  });

  testWidgets('a sync error for one account shows a dismissible banner naming the failure count', (tester) async {
    final container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
      unifiedInboxProvider.overrideWith((ref) async => [
            UnifiedMessage(message: personalMessage, folder: personalInbox, account: personal),
          ]),
      swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
    ]);
    addTearDown(container.dispose);
    container.read(syncErrorProvider(1).notifier).state = 'connection refused';

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 account'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Dismiss'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 account'), findsNothing);
  });
}
