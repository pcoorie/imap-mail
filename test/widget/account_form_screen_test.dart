import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/screens/account_form_screen.dart';

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
}
