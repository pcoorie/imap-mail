import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:imap_mail/providers/theme_providers.dart';
import 'package:imap_mail/screens/folder_view_screen.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';
import 'package:imap_mail/screens/search_screen.dart';
import 'package:imap_mail/screens/settings_screen.dart';

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
    registerFallbackValue(<MailMessage>[]);
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

  testWidgets('shows a friendly empty-state placeholder instead of a blank screen when the '
      'selected folder has no messages', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('No messages'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
  });

  testWidgets('separates message rows with a thin divider when there is more than one',
      (tester) async {
    final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
        messagesProvider.overrideWith((ref, folder) async => [message, second]),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    // Exactly one divider between the two rows — not one trailing every row.
    // Scoped to the message list itself: the screen already has its own
    // structural divider above the list, unrelated to row separators.
    final messageListDividers = find.descendant(
      of: find.byType(ListView).last,
      matching: find.byType(Divider),
    );
    expect(messageListDividers, findsOneWidget);
  });

  testWidgets('a settings icon opens SettingsScreen — the only path there once single-account routing skips AccountListScreen entirely', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
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

    // Expanding the folder tree must not blow the RenderFlex layout...
    expect(tester.takeException(), isNull);
    // ...and the message list beneath it must still be given real space to
    // render in, not squeezed to zero height by the overflowing sibling.
    final listViewBox = tester.renderObject<RenderBox>(find.byType(ListView).last);
    expect(listViewBox.size.height, greaterThan(0));
  });

  testWidgets(
      "pull-to-refresh's onRefresh does not resolve until the resync actually completes "
      '(regression: ref.invalidate() alone resolved instantly, before messagesProvider\'s rebuild '
      '— a real IMAP fetch — had even started)', (tester) async {
    final resyncCompleter = Completer<List<MailMessage>>();
    var callCount = 0;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async {
          callCount++;
          // First build (initial load) resolves immediately; the second
          // (pull-to-refresh's rebuild) stays pending until the test
          // completes it, so we can observe whether onRefresh's own future
          // waits for it.
          if (callCount == 1) return [message];
          return resyncCompleter.future;
        }),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();
    expect(callCount, 1);

    // Call the RefreshIndicator's onRefresh directly rather than driving the
    // drag gesture — what's under test is whether the future it returns
    // tracks the real resync, not the indicator's own drag/arm animation.
    final refreshIndicator = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    var resolved = false;
    unawaited(refreshIndicator.onRefresh().then((_) => resolved = true));

    await tester.pump();
    // The resync has started (messagesProvider rebuilt a second time) but its
    // future is still pending. Before the fix, onRefresh's returned future
    // was the instant, synchronous result of ref.invalidate() — it would
    // already have resolved by this point regardless.
    expect(callCount, 2);
    expect(resolved, isFalse);

    resyncCompleter.complete([message]);
    await tester.pump();
    await tester.pump();

    expect(resolved, isTrue);
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

  testWidgets('the Archived/Undo snackbar disappears on its own after its duration elapses', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = message.copyWith(folderId: 4);
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

    await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBar, 'Archived'), findsOneWidget);

    // Material's default SnackBar duration is 4 seconds — advance well past
    // it and confirm nothing is left relying only on flutter_slidable's/
    // Material's own dismiss timer (see _showAutoDismissingSnackBar).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBar, 'Archived'), findsNothing);
    expect(find.text('Undo'), findsNothing);
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

  testWidgets(
      'switching folder tabs mid-swipe still invalidates/undoes into the '
      'ORIGINAL folder, not the newly-selected one', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = message.copyWith(folderId: 4);
    final archiveCompleter = Completer<MailMessage>();
    when(() => repository.archiveMessage(any(), any(), any())).thenAnswer((_) => archiveCompleter.future);
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);
    when(() => repository.getCachedFolders(any())).thenAnswer((_) async => [inbox, sent, trash, archive]);
    when(() => repository.moveMessage(any(), any(), any(), any())).thenAnswer((_) async => archivedMessage);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        // Deliberately serves the same message under both Inbox and Sent.
        // This isolates the specific race under test — folder identity
        // captured when the swipe starts vs. re-read later after the tab
        // switch — from the unrelated fact that switching to a folder whose
        // messagesProvider hasn't been read before goes through a loading
        // state, which tears down and rebuilds the entire message list
        // (unmounting every list item's BuildContext, archived-folder bug or
        // not). Pre-warming Sent below and using an identical, identically
        // keyed message avoids that unrelated teardown.
        messagesProvider.overrideWith((ref, folder) async {
          if (folder.id == inbox.id || folder.id == sent.id) return [message];
          return const [];
        }),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // Pre-warm Sent's messagesProvider and switch back to Inbox, so the
    // mid-flight switch below resolves instantly (AsyncData already cached)
    // instead of flashing through AsyncLoading.
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();

    // Reveal the start action pane (leftPrimary: archive) with a partial
    // swipe, then tap its "Archive" button. _MessageList has no key, so the
    // upcoming tab switch updates widget.folder on this same State rather
    // than recreating it — this is what makes the bug (and the fix)
    // observable.
    await tester.drag(find.text('Hello'), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    // A single pump (not pumpAndSettle): _performSwipeAction has started and
    // is now suspended awaiting archiveCompleter.future, which we haven't
    // completed yet.
    await tester.pump();

    // Switch to a different folder tab while that archive call is still in
    // flight.
    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();

    // Now let the in-flight archive call resolve.
    archiveCompleter.complete(archivedMessage);
    await tester.pumpAndSettle();

    // The snackbar's Undo must move the message back into the folder the
    // swipe actually started in (Inbox) — not wherever the user has since
    // navigated to (Sent).
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    verify(() => repository.moveMessage(account, archive, inbox, archivedMessage)).called(1);
  });

  testWidgets(
      'a full swipe on a non-removing action (flag) does not dismiss the row '
      'or leave the tree in a bad state', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.markFlagged(any(), any(), any(), any())).thenAnswer((_) async {});
    const flagOnlyConfig = SwipeActionConfig(
      leftPrimary: SwipeAction.flag,
      leftSecondary: SwipeAction.none,
      rightPrimary: SwipeAction.none,
      rightSecondary: SwipeAction.none,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        mailRepositoryProvider.overrideWith((ref) async => repository),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(flagOnlyConfig)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // Full swipe past the dismiss threshold — flag is the only configured
    // (and therefore dismiss) action on this side, but flagging doesn't
    // remove the message from the folder, so confirmDismiss must veto the
    // resize/dismiss animation: the row should still be present afterwards,
    // and flutter_slidable must not throw its "dismissed widget still in
    // the tree" assertion.
    await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hello'), findsOneWidget);
    verify(() => repository.markFlagged(account, inbox, message, true)).called(1);
  });

  testWidgets(
      'a failed full-swipe archive does not dismiss the row or leave the '
      'tree in a bad state', (tester) async {
    final repository = MockMailRepository();
    when(() => repository.archiveMessage(any(), any(), any())).thenThrow(Exception('IMAP move failed'));

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

    // Full swipe past the dismiss threshold, but the repository call throws.
    // confirmDismiss must veto the animation on failure too — otherwise the
    // resize/dismiss already committed before the failure was known, and the
    // Retry snackbar it shows would point at a row the user can no longer
    // see or interact with.
    await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.textContaining("Couldn't archive"), findsOneWidget);
  });

  testWidgets(
      'offers no Undo when the moved message ended up with a synthetic '
      'negative uid (server reported no new UID)', (tester) async {
    final repository = MockMailRepository();
    // uid < 0 is this codebase's synthetic-placeholder convention: the move
    // succeeded but the server never told us the new UID (no UIDPLUS), so
    // there is no uid an Undo could legitimately move back by. Offering
    // Undo anyway would send `UID MOVE -1 ...`.
    final archivedMessage = message.copyWith(folderId: 4, uid: -1);
    when(() => repository.archiveMessage(any(), any(), any())).thenAnswer((_) async => archivedMessage);
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);

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

    // Partial swipe to reveal the start pane, then tap Archive (avoids the
    // full-swipe dismissal path; this test is only about the snackbar).
    await tester.drag(find.text('Hello'), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBar, 'Archived'), findsNothing);
    expect(find.textContaining("can't be undone"), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('a failed Undo reports the failure instead of silently doing nothing', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = message.copyWith(folderId: 4, uid: 42);
    when(() => repository.archiveMessage(any(), any(), any())).thenAnswer((_) async => archivedMessage);
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);
    when(() => repository.getCachedFolders(any())).thenAnswer((_) async => [inbox, sent, trash, archive]);
    when(() => repository.moveMessage(any(), any(), any(), any())).thenThrow(Exception('offline'));

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

    await tester.drag(find.text('Hello'), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Undo'), findsOneWidget);

    // Unguarded, this await turns into an unhandled async error: the user
    // taps Undo, the move-back fails, and nothing visible happens at all.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining("Couldn't undo"), findsOneWidget);
  });

  testWidgets(
      'disposing the message list mid-action does not throw when the '
      'repository call finally resolves', (tester) async {
    final repository = MockMailRepository();
    final archivedMessage = message.copyWith(folderId: 4, uid: 42);
    final archiveCompleter = Completer<MailMessage>();
    when(() => repository.archiveMessage(any(), any(), any())).thenAnswer((_) => archiveCompleter.future);
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [archivedMessage]);

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

    await tester.drag(find.text('Hello'), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    // Single pumps only: _performSwipeAction is now suspended awaiting
    // archiveCompleter.future.
    await tester.pump();
    await tester.pump();

    // Tear the whole screen (and its ProviderScope) down while the archive
    // is still in flight — the equivalent of popping the folder view or
    // switching accounts mid-action.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

    // Now let it resolve. Every post-await `ref.read`/`ref.invalidate` in
    // _performSwipeAction is reached from a disposed ConsumerState, which
    // throws a StateError unless guarded by `mounted`.
    archiveCompleter.complete(archivedMessage);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'removing the account from accountsProvider while its FolderViewScreen is still mounted and rendering '
      'messages does not crash — renders the loading fallback instead of throwing a StateError from an '
      'unguarded firstWhere', (tester) async {
    final accountsNotifier = _FakeAccountsNotifier([account]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
        accountsProvider.overrideWith(() => accountsNotifier),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    // Sanity check: the message renders normally while the account exists.
    expect(find.text('Hello'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Simulate the account vanishing out from under this still-mounted
    // screen (e.g. removed from another screen) — accountsProvider now
    // resolves to a list that no longer contains this folder's accountId,
    // but messagesProvider/foldersProvider still serve their cached data.
    accountsNotifier.state = const AsyncData([]);
    // Not pumpAndSettle: the fallback is an indeterminate
    // CircularProgressIndicator, whose animation never settles.
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('the app bar search icon opens SearchScreen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.byType(SearchScreen), findsOneWidget);
  });

  group('multi-select and bulk Trash', () {
    testWidgets('long-pressing a row enters selection mode with a contextual app bar', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('tapping another row while selecting adds it and updates the count instead of opening it',
        (tester) async {
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(MessageDetailScreen), findsNothing);
    });

    testWidgets('tapping the X exits selection mode and restores the normal app bar', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('deselecting the last selected row automatically exits selection mode', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hello'));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
    });

    testWidgets('swipe actions are disabled while selecting (a drag does not trigger the swipe delete)',
        (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessage(any(), any(), any()))
          .thenAnswer((_) async => message.copyWith(folderId: trash.id!));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      expect(find.byType(Slidable), findsNothing);

      await tester.timedDrag(find.text('Hello'), const Offset(700, 0), const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      verifyNever(() => repository.deleteMessage(any(), any(), any()));
    });

    testWidgets('tapping Delete bulk-deletes every selected message and exits selection mode', (tester) async {
      final repository = MockMailRepository();
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => const BulkResult(succeeded: [], failed: {}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      verify(() => repository.deleteMessages(account, inbox, [message, second])).called(1);
      expect(find.text('Mail'), findsOneWidget);
    });

    testWidgets('the bulk delete summary snackbar never offers an Undo action', (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: [message], failed: const {}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining('moved to Trash'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('switching folder tabs while selecting exits selection mode and restores the normal app bar',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();

      expect(find.text('Mail'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('a bulk delete where every message failed reports it without an Undo action', (tester) async {
      final repository = MockMailRepository();
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: const [], failed: {100: Exception('offline')}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't move 1 message"), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('a partial bulk-delete failure reports both counts in the summary snackbar', (tester) async {
      final repository = MockMailRepository();
      final second = message.copyWith(id: 101, uid: 2, subject: 'Second');
      when(() => repository.deleteMessages(any(), any(), any()))
          .thenAnswer((_) async => BulkResult(succeeded: [message], failed: {101: Exception('offline')}));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash]),
          messagesProvider.overrideWith((ref, folder) async => folder.id == inbox.id ? [message, second] : const []),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ],
        child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 moved, 1 failed'), findsOneWidget);
    });
  });
}
