import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/widgets/message_list_tile.dart';

void main() {
  MailMessage message({required MailSendStatus sendStatus}) => MailMessage(
        folderId: 1,
        uid: 1,
        subject: 'Subject',
        from: 'a@example.com',
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
        sendStatus: sendStatus,
      );

  testWidgets('shows a failed-send indicator for a message with sendStatus.failed', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.failed),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Failed to send'), findsOneWidget);
  });

  testWidgets('does not show a failed-send indicator for a normal message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.textContaining('Failed to send'), findsNothing);
  });
}
