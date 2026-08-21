import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/widgets/compose_account_picker.dart';

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

  testWidgets('lists every account and resolves with the one tapped', (tester) async {
    MailAccount? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            picked = await showComposeAccountPicker(context, [work, personal]);
          },
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();

    expect(picked, personal);
  });
}
