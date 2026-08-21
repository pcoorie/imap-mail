import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/folder_providers.dart';
import 'package:imap_mail/providers/message_providers.dart';
import 'package:imap_mail/screens/folder_view_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

void main() {
  const accountId = 1;
  final inbox = MailFolder(id: 1, accountId: accountId, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final sent = MailFolder(id: 2, accountId: accountId, name: 'Sent', path: 'Sent', type: MailFolderType.sent);
  final trash = MailFolder(id: 3, accountId: accountId, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final archive = MailFolder(id: 4, accountId: accountId, name: 'Archive', path: 'Archive', type: MailFolderType.other);

  testWidgets('shows Inbox/Sent/Trash by default, Archive hidden until expanded', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        // The screen also builds a message list beneath the selected folder
        // tab, which watches messagesProvider. Its real implementation
        // chains through accountsProvider into the real sqflite/path_provider
        // plugins; those platform-channel calls never settle inside a widget
        // test's fake async zone (only tester.runAsync real-IO blocks do),
        // which would leave the message list's CircularProgressIndicator
        // spinning forever and hang pumpAndSettle. Overriding the family
        // directly (same technique already used for foldersProvider above)
        // avoids exercising that unrelated real-IO chain without touching
        // any production widget or its behavior.
        messagesProvider.overrideWith((ref, folder) async => const []),
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

    await tester.pumpWidget(ProviderScope(
      overrides: [
        // Mirrors the real foldersProvider, which awaits accountsProvider
        // before syncing folders (see folder_providers.dart) — so by the
        // time the widget reaches its error state, accountsProvider is
        // already resolved/cached, exactly as it would be in production.
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
}
