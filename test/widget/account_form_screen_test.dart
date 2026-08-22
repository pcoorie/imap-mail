import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/screens/account_form_screen.dart';

class _RecordingAccountsNotifier extends AccountsNotifier {
  _RecordingAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;
  bool addCalled = false;
  bool updateCalled = false;
  MailAccount? lastUpdated;
  String? lastUpdatedPassword;

  @override
  Future<List<MailAccount>> build() async => _accounts;

  @override
  Future<void> add(MailAccount account, String password) async {
    addCalled = true;
  }

  @override
  Future<void> updateAccount(MailAccount account, {String? newPassword}) async {
    updateCalled = true;
    lastUpdated = account;
    lastUpdatedPassword = newPassword;
  }
}

void main() {
  // The form's fields don't all fit within the default 800x600 test surface,
  // which would leave the Save button laid out but "offstage" (outside the
  // visible viewport) and therefore invisible to `find` (skipOffstage is true
  // by default). Widening the surface avoids relying on scrolling within the
  // test and keeps production layout untouched.
  Future<void> useTallSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('Save button is disabled until required fields are filled', (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountFormScreen()),
    ));

    final saveButtonFinder = find.widgetWithText(ElevatedButton, 'Save');
    ElevatedButton saveButton() => tester.widget(saveButtonFinder);
    expect(saveButton().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('displayNameField')), 'Work');
    await tester.enterText(find.byKey(const Key('emailField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('imapHostField')), 'imap.example.com');
    await tester.enterText(find.byKey(const Key('imapPortField')), '993');
    await tester.enterText(find.byKey(const Key('smtpHostField')), 'smtp.example.com');
    await tester.enterText(find.byKey(const Key('smtpPortField')), '465');
    await tester.enterText(find.byKey(const Key('usernameField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'app-password');
    await tester.pump();

    expect(saveButton().onPressed, isNotNull);
  });

  testWidgets('shows a Test connection button', (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountFormScreen()),
    ));
    expect(find.widgetWithText(OutlinedButton, 'Test connection'), findsOneWidget);
  });

  testWidgets('shows IMAP and SMTP security dropdowns defaulting to SSL/TLS', (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountFormScreen()),
    ));

    final imapDropdownFinder = find.byKey(const Key('imapSecurityDropdown'));
    final smtpDropdownFinder = find.byKey(const Key('smtpSecurityDropdown'));
    expect(imapDropdownFinder, findsOneWidget);
    expect(smtpDropdownFinder, findsOneWidget);

    DropdownButtonFormField<MailSecurity> imapDropdown() =>
        tester.widget(imapDropdownFinder);
    expect(imapDropdown().initialValue, MailSecurity.ssl);

    // Open the IMAP dropdown and select STARTTLS.
    await tester.tap(imapDropdownFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('STARTTLS').last);
    await tester.pumpAndSettle();

    expect(imapDropdown().initialValue, MailSecurity.startTls);
    // SMTP dropdown is unaffected by the IMAP change.
    expect((tester.widget(smtpDropdownFinder) as DropdownButtonFormField<MailSecurity>)
        .initialValue, MailSecurity.ssl);
  });

  const existingAccount = MailAccount(
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

  testWidgets('editing an account: Save is enabled with an empty password field', (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _RecordingAccountsNotifier([existingAccount])),
      ],
      child: const MaterialApp(home: AccountFormScreen(existing: existingAccount)),
    ));

    final saveButtonFinder = find.widgetWithText(ElevatedButton, 'Save');
    ElevatedButton saveButton() => tester.widget(saveButtonFinder);

    // All fields are pre-filled from `existing`; the password field is
    // deliberately left blank (existing accounts don't round-trip a stored
    // password into the form). Save must still be enabled.
    expect(find.byKey(const Key('passwordField')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('passwordField'))).controller!.text, isEmpty);
    expect(saveButton().onPressed, isNotNull);
  });

  testWidgets('editing an account calls updateAccount (not add), with null password when left blank', (tester) async {
    await useTallSurface(tester);
    final notifier = _RecordingAccountsNotifier([existingAccount]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => notifier),
      ],
      child: const MaterialApp(home: AccountFormScreen(existing: existingAccount)),
    ));

    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pump();
    await tester.pump();

    expect(notifier.updateCalled, isTrue);
    expect(notifier.addCalled, isFalse);
    expect(notifier.lastUpdated!.id, existingAccount.id);
    expect(notifier.lastUpdatedPassword, isNull);
  });

  testWidgets(
      'saving a new account when the form is the app root does not crash '
      '(onboarding: zero accounts, no previous route to pop to)', (tester) async {
    await useTallSurface(tester);
    final notifier = _RecordingAccountsNotifier([]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => notifier),
      ],
      // Mirrors app.dart: when there are zero accounts, AccountFormScreen is
      // used directly as MaterialApp.home — not pushed via Navigator.push.
      // There is therefore no previous route to pop back to.
      child: const MaterialApp(home: AccountFormScreen()),
    ));

    await tester.enterText(find.byKey(const Key('displayNameField')), 'Work');
    await tester.enterText(find.byKey(const Key('emailField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('imapHostField')), 'imap.example.com');
    await tester.enterText(find.byKey(const Key('imapPortField')), '993');
    await tester.enterText(find.byKey(const Key('smtpHostField')), 'smtp.example.com');
    await tester.enterText(find.byKey(const Key('smtpPortField')), '465');
    await tester.enterText(find.byKey(const Key('usernameField')), 'me@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'app-password');
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pump();
    await tester.pump();

    expect(notifier.addCalled, isTrue);
    expect(tester.takeException(), isNull);
    // The form (or whatever the accountsProvider watcher swaps in) must
    // still be showing a real screen, not a blank/empty Overlay.
    expect(find.byType(Scaffold), findsWidgets);
  });

  testWidgets('editing an account with a new password passes it through to updateAccount', (tester) async {
    await useTallSurface(tester);
    final notifier = _RecordingAccountsNotifier([existingAccount]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => notifier),
      ],
      child: const MaterialApp(home: AccountFormScreen(existing: existingAccount)),
    ));

    await tester.enterText(find.byKey(const Key('passwordField')), 'new-password');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pump();
    await tester.pump();

    expect(notifier.updateCalled, isTrue);
    expect(notifier.lastUpdatedPassword, 'new-password');
  });
}
