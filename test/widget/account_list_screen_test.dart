import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/unified_inbox_providers.dart';
import 'package:imap_mail/screens/account_list_screen.dart';
import 'package:imap_mail/screens/unified_inbox_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  @override
  SwipeActionConfig build() => SwipeActionConfig.defaults;
}

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

  testWidgets('shows an "All Inboxes" tile above the unchanged per-account rows, with the total unread count', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        totalUnreadCountProvider.overrideWith((ref) async => 8),
      ],
      child: const MaterialApp(home: AccountListScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('All Inboxes'), findsOneWidget);
    expect(find.text('2 accounts'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
  });

  testWidgets('tapping "All Inboxes" opens UnifiedInboxScreen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        totalUnreadCountProvider.overrideWith((ref) async => 0),
        unifiedInboxProvider.overrideWith((ref) async => []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier()),
      ],
      child: const MaterialApp(home: AccountListScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('All Inboxes'));
    await tester.pumpAndSettle();

    expect(find.byType(UnifiedInboxScreen), findsOneWidget);
  });
}
