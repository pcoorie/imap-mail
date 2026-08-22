import 'dart:async';

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
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/sync_status_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/screens/unified_inbox_screen.dart';
import 'package:imap_mail/widgets/account_color.dart';

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

  testWidgets('shows a friendly empty-state placeholder instead of a blank screen when every '
      "account's inbox is empty", (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work])),
        unifiedInboxProvider.overrideWith((ref) async => []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('No messages'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
  });

  testWidgets('separates message rows with a thin divider when there is more than one',
      (tester) async {
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

    expect(find.byType(Divider), findsOneWidget);
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

    // Each row's account-color dot must match its OWN account, not a fixed
    // one — mirrors the pattern in message_list_tile_test.dart.
    final dots = tester.widgetList<Container>(find.byKey(const Key('accountColorDot'))).toList();
    expect(dots, hasLength(2));
    expect((dots[0].decoration as BoxDecoration).color, accountColorFor(personal.id!));
    expect((dots[1].decoration as BoxDecoration).color, accountColorFor(work.id!));
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

  testWidgets(
      'the banner\'s Retry re-fetches the underlying foldersProvider/messagesProvider — not just '
      'unifiedInboxProvider re-reading the same cached failure', (tester) async {
    var foldersCalls = 0;
    var messagesCalls = 0;
    var workShouldFail = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        foldersProvider.overrideWith((ref, accountId) async {
          foldersCalls++;
          return accountId == work.id ? [workInbox] : [personalInbox];
        }),
        messagesProvider.overrideWith((ref, folder) async {
          messagesCalls++;
          if (folder.id == workInbox.id && workShouldFail) {
            throw Exception('connection refused');
          }
          // A real asynchronous gap (like the real messagesProvider's own
          // `await repository.syncHeaders(...)`) before touching another
          // provider — Riverpod forbids modifying a provider synchronously
          // during another's initialization.
          await Future<void>.delayed(Duration.zero);
          // Mirrors the real messagesProvider's own success-clears-the-error
          // behavior, so the banner's disappearance below is a meaningful
          // signal that a real re-fetch (not just unifiedInboxProvider being
          // invalidated) actually happened.
          ref.read(syncErrorProvider(folder.accountId).notifier).state = null;
          return folder.id == personalInbox.id ? [personalMessage] : const [];
        }),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 account'), findsOneWidget);
    final foldersBefore = foldersCalls;
    final messagesBefore = messagesCalls;

    workShouldFail = false; // the underlying condition is resolved by the time Retry is tapped
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(foldersCalls, greaterThan(foldersBefore));
    expect(messagesCalls, greaterThan(messagesBefore));
    expect(find.textContaining('1 account'), findsNothing);
  });

  testWidgets(
      'pull-to-refresh re-fetches every account\'s folders/messages even when the unified list is currently '
      'empty (every account previously failed with no cache) — deriving folders from accountsProvider, not '
      'from the (empty) unified list', (tester) async {
    var foldersCalls = 0;
    var messagesCalls = 0;
    var shouldFail = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        foldersProvider.overrideWith((ref, accountId) async {
          foldersCalls++;
          return accountId == work.id ? [workInbox] : [personalInbox];
        }),
        messagesProvider.overrideWith((ref, folder) async {
          messagesCalls++;
          if (shouldFail) throw Exception('offline');
          return folder.id == workInbox.id ? [workMessage] : [personalMessage];
        }),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    // Every account failed with no cache to fall back to: unifiedInboxProvider
    // resolves to an empty list (not an error state) — no rows rendered.
    expect(find.byType(ListTile), findsNothing);
    final foldersBefore = foldersCalls;
    final messagesBefore = messagesCalls;

    shouldFail = false;
    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(foldersCalls, greaterThan(foldersBefore));
    expect(messagesCalls, greaterThan(messagesBefore));
    expect(find.text('From work'), findsOneWidget);
    expect(find.text('From personal'), findsOneWidget);
  });

  testWidgets(
      "pull-to-refresh's onRefresh does not resolve until every account's resync actually "
      'completes (regression: _refreshAllInboxSources used to just fire a batch of '
      'ref.invalidate() calls and return immediately, before any of the real IMAP fetches they '
      'trigger had finished)', (tester) async {
    final resyncCompleter = Completer<List<MailMessage>>();
    var messagesCallCount = 0;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work])),
        foldersProvider.overrideWith((ref, accountId) async => [workInbox]),
        messagesProvider.overrideWith((ref, folder) async {
          messagesCallCount++;
          // First build (initial load) resolves immediately; the second
          // (pull-to-refresh's rebuild) stays pending until the test
          // completes it, so we can observe whether onRefresh's own future
          // waits for it.
          if (messagesCallCount == 1) return [workMessage];
          return resyncCompleter.future;
        }),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();
    expect(messagesCallCount, 1);

    // Call the RefreshIndicator's onRefresh directly rather than driving the
    // drag gesture — what's under test is whether the future it returns
    // tracks the real resync, not the indicator's own drag/arm animation.
    final refreshIndicator = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    var resolved = false;
    unawaited(refreshIndicator.onRefresh().then((_) => resolved = true));

    await tester.pump();
    // The resync has started (messagesProvider rebuilt a second time) but its
    // future is still pending. Before the fix, onRefresh's returned future
    // was just the synchronous batch of ref.invalidate() calls — it would
    // already have resolved by this point regardless.
    expect(messagesCallCount, 2);
    expect(resolved, isFalse);

    resyncCompleter.complete([workMessage]);
    await tester.pump();
    await tester.pump();

    expect(resolved, isTrue);
  });
}
