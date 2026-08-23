// test/widget/search_screen_test.dart
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
import 'package:imap_mail/providers/search_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';
import 'package:imap_mail/screens/search_screen.dart';

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
  final personalTrash = MailFolder(id: 21, accountId: 2, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final workMessage = MailMessage(
    id: 100, folderId: 10, uid: 1, subject: 'Invoice from work', from: 'a@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 20), snippet: 'Hi',
  );
  final personalMessage = MailMessage(
    id: 200, folderId: 21, uid: 1, subject: 'Old invoice', from: 'b@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 21), snippet: 'Hey',
  );

  setUpAll(() {
    registerFallbackValue(work);
    registerFallbackValue(workInbox);
    registerFallbackValue(workMessage);
  });

  Future<void> pumpSearchScreen(WidgetTester tester, {required List<Override> overrides}) {
    return tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ...overrides,
      ],
      child: const MaterialApp(home: SearchScreen()),
    ));
  }

  testWidgets('shows a prompt instead of results while the query is blank', (tester) async {
    await pumpSearchScreen(tester, overrides: []);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, 'Search mail');
    expect(find.text('Search your mail'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('does not query before the debounce window elapses, and does after', (tester) async {
    var searchCalls = 0;
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async {
        searchCalls++;
        return const [];
      }),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 100));
    expect(searchCalls, 0);

    await tester.pump(const Duration(milliseconds: 250)); // now past the 300ms debounce
    expect(searchCalls, 1);
  });

  testWidgets('shows a "no results" state for a query that matches nothing', (tester) async {
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async => const []),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('No results for "nothing matches this"'), findsOneWidget);
  });

  testWidgets('renders matching results from every account, newest first', (tester) async {
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async => [
            UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal),
            UnifiedMessage(message: workMessage, folder: workInbox, account: work),
          ]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles[0].title as Text).data, 'Old invoice'); // newest first
    expect((tiles[1].title as Text).data, 'Invoice from work');
  });

  testWidgets(
      "tapping a result opens MessageDetailScreen with THAT result's own folder/message, "
      'not a fixed one', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.fetchBodyIfNeeded(personal, personalTrash, personalMessage))
        .thenAnswer((_) async => personalMessage.copyWith(isDownloaded: true));
    when(() => repository.getAttachments(personalMessage.id!)).thenAnswer((_) async => const []);
    when(() => repository.markRead(personal, personalTrash, personalMessage, true,
            revertLocalOnFailure: false))
        .thenAnswer((_) async {});

    await pumpSearchScreen(tester, overrides: [
      mailRepositoryProvider.overrideWith((ref) async => repository),
      searchResultsProvider.overrideWith((ref, query) async => [
            UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal),
          ]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old invoice'));
    await tester.pumpAndSettle();

    final pushed = tester.widget<MessageDetailScreen>(find.byType(MessageDetailScreen));
    expect(pushed.folder, personalTrash);
    expect(pushed.message, personalMessage);
  });

  testWidgets(
      "swipe-delete on a result calls deleteMessage against that result's own account/folder "
      'and removes the row', (tester) async {
    final repository = MockMailRepository();
    final deletedMessage = personalMessage.copyWith(folderId: 999);
    var deleted = false;
    when(() => repository.deleteMessage(personal, personalTrash, personalMessage)).thenAnswer((_) async {
      deleted = true;
      return deletedMessage;
    });
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [deletedMessage]);

    await pumpSearchScreen(tester, overrides: [
      mailRepositoryProvider.overrideWith((ref) async => repository),
      searchResultsProvider.overrideWith((ref, query) async => deleted
          ? const []
          : [UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal)]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.timedDrag(find.text('Old invoice'), const Offset(-700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    verify(() => repository.deleteMessage(personal, personalTrash, personalMessage)).called(1);
    expect(find.text('Old invoice'), findsNothing);
  });
}
