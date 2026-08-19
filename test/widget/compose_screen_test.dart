import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/compose_providers.dart';
import 'package:imap_mail/screens/compose_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

// The form (To/Cc/Bcc/Subject/Message with maxLines: 10 + attach button +
// Send button) is taller than the default 800x600 test viewport plus the
// ListView's default cache extent. Without this, the Send button isn't even
// built (find() returns zero matches, not just an off-screen widget), and the
// body TextField's own internal Scrollable makes plain scrolling ambiguous
// (more than one Scrollable in the tree). Growing the viewport sidesteps both
// problems; production layout is untouched.
void _growViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  const account = MailAccount(
    id: 1,
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

  testWidgets('Send is disabled until a recipient and body are entered', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');
    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNull);

    expect(find.byKey(const Key('bccField')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNotNull);
  });

  testWidgets('Bcc is optional and does not block Send once required fields are filled', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.enterText(find.byKey(const Key('bccField')), 'secret@example.com');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNotNull);
  });

  testWidgets('shows an inline error and keeps content when send fails', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sendMessageProvider.overrideWithValue((MailAccount account, ComposedMessage message) async {
          throw Exception('smtp unreachable');
        }),
        // The real accountsProvider chain reaches through database/path_provider
        // platform channels, which never settle inside a widget test's fake
        // async zone (see folder_view_screen_test.dart / message_detail_screen_test.dart
        // for the same established fix). _send() reads accountsProvider.future to
        // resolve the MailAccount, so we override it with a fake notifier to avoid
        // that unrelated real-IO chain hanging pumpAndSettle below.
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      ],
      child: const MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');
    await tester.tap(sendButtonFinder);
    await tester.pumpAndSettle();

    expect(find.textContaining('smtp unreachable'), findsOneWidget);
    expect(find.text('Hello Bob'), findsOneWidget); // body field still has the content
  });
}
