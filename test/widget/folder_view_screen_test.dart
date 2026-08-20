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
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/screens/folder_view_screen.dart';

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
  const accountId = 1;
  const account = MailAccount(
    id: accountId,
    displayName: 'Work',
    email: 'me@example.com',
    imapHost: 'imap.example.com',
    imapPort: 993,
    imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com',
    smtpPort: 465,
    smtpSecurity: MailSecurity.ssl,
    username: 'me@example.com',
  );
  final inbox = MailFolder(id: 1, accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final sent = MailFolder(id: 2, accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final trash = MailFolder(id: 3, accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final archive = MailFolder(id: 4, accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.other);
  final message = MailMessage(
    id: 100,
    folderId: 1,
    uid: 1,
    subject: 'Hello',
    from: 'a@example.com',
    to: 'me@example.com',
    date: DateTime.utc(2026, 8, 19),
    snippet: 'Hi there',
  );

  setUpAll(() {
    registerFallbackValue(account);
    registerFallbackValue(inbox);
    registerFallbackValue(message);
  });

  testWidgets('shows Inbox/Sent/Trash by default, Archive hidden until expanded', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        // _MessageList now watches swipeActionConfigProvider unconditionally
        // (to build its Slidable action panes), which otherwise chains into
        // the real sharedPreferencesProvider and throws — this test isn't
        // about swipe behavior, so just supply the defaults.
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);

    await tester.tap(find.text('More folders'));
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
  });

  testWidgets(
      'expanding many other folders does not overflow the Column or starve '
      'the message list of space', (tester) async {
    final otherFolders = List.generate(
      15,
      (i) => MailFolder(
          id: 10 + i, accountId: accountId, name: 'Custom Folder $i',
          path: 'Custom$i', type: MailFolderType.other),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, ...otherFolders]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        // See the same override in the previous test for why this is needed.
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More folders'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final listViewBox = tester.renderObject<RenderBox>(find.byType(ListView).last);
    expect(listViewBox.size.height, greaterThan(0));
  });

  testWidgets('shows an error banner with Retry when folders fail to load', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => throw Exception('connection refused')),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('connection refused'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('Edit account opens the form pre-filled for the failed account', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async {
          await ref.watch(accountsProvider.future);
          throw Exception('connection refused');
        }),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Edit account'));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Edit account')), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Add account')), findsNothing);
  });

  testWidgets('a full left-to-right swipe fires the configured left-primary action (Archive)', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = message.copyWith(folderId: 4);
    // flutter_slidable's DismissiblePane requires the dismissed item to
    // actually disappear from the underlying list once its resize animation
    // completes (it asserts on this — see dismissal.dart), so this override
    // must reflect the archive rather than unconditionally returning
    // [message] — otherwise the same message reappears with the same key
    // and the framework reports the widget as "still in the tree" after
    // being dismissed.
    var archived = false;
    when(() => repository.archiveMessage(any(), any(), any())).thenAnswer((_) async {
      archived = true;
      return archivedMessage;
    });
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith(
            (ref, folder) async => folder.id == inbox.id && !archived ? [message] : const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // A full drag+release needs to happen across an actual span of time (not
    // instantaneously) for flutter_slidable's DismissiblePane to mount and
    // register its dismiss-gesture listener before the gesture ends —
    // otherwise it falls back to just opening the pane. See
    // dismissible_pane_test.dart in the flutter_slidable package itself,
    // which uses the same timedDrag technique for this exact scenario.
    await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    verify(() => repository.archiveMessage(account, inbox, message)).called(1);
    verify(() => repository.getCachedMessages(4)).called(1);
  });

  testWidgets('tapping the secondary right-side action (Mark read/unread) calls markRead', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.markRead(any(), any(), any(), any())).thenAnswer((_) async {});

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // Partial swipe right-to-left to reveal the end action pane's buttons
    // without crossing the full-swipe dismiss threshold.
    await tester.drag(find.text('Hello'), const Offset(-300, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark read/unread'));
    await tester.pumpAndSettle();

    verify(() => repository.markRead(account, inbox, message, true)).called(1);
  });
}
