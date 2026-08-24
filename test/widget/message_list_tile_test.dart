import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/widgets/account_color.dart';
import 'package:imap_mail/widgets/message_list_tile.dart';

void main() {
  MailMessage message({
    required MailSendStatus sendStatus,
    bool isFlagged = false,
    String from = 'a@example.com',
    String? fromName,
  }) =>
      MailMessage(
        folderId: 1,
        uid: 1,
        subject: 'Subject',
        from: from,
        fromName: fromName,
        to: 'me@example.com',
        date: DateTime.utc(2026, 8, 19),
        snippet: 'snippet',
        sendStatus: sendStatus,
        isFlagged: isFlagged,
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

  testWidgets('shows a flag indicator for a flagged message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, isFlagged: true),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.flag), findsOneWidget);
  });

  testWidgets('does not show a flag indicator for an unflagged message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, isFlagged: false),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.flag), findsNothing);
  });

  testWidgets('tints the row for a flagged message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, isFlagged: true),
          onTap: () {},
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, Colors.orange.withValues(alpha: 0.08));
  });

  testWidgets('does not tint the row for an unflagged message', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, isFlagged: false),
          onTap: () {},
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, isNull);
  });

  testWidgets('shows a colored dot badge on the sender avatar when accountColor is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          accountColor: Colors.teal,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.leading, isNotNull);
    // The account badge sits alongside the sender avatar, not instead of it.
    expect(find.byType(CircleAvatar), findsOneWidget);
    final container = tester.widget<Container>(find.byKey(const Key('accountColorDot')));
    expect((container.decoration as BoxDecoration).color, Colors.teal);
  });

  testWidgets('shows the sender avatar in the leading slot even when accountColor is null and the '
      'message did not fail to send', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, from: 'chris.quinones@example.com'),
          onTap: () {},
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.leading, isNotNull);
    expect(find.byType(CircleAvatar), findsOneWidget);
    // No personalName given — falls back to the email's local part.
    expect(find.text('CQ'), findsOneWidget);
  });

  testWidgets('the sender avatar shows initials from personalName when available, not the email',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(
            sendStatus: MailSendStatus.none,
            from: 'noreply@example.com',
            fromName: 'Belinda Lewis',
          ),
          onTap: () {},
        ),
      ),
    ));

    expect(find.text('BL'), findsOneWidget);
  });

  testWidgets('the sender avatar is round and colored deterministically per sender', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, from: 'alice@example.com'),
          onTap: () {},
        ),
      ),
    ));

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.backgroundColor, senderColorFor('alice@example.com'));
  });

  testWidgets('a failed-send message shows the error icon even when accountColor is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.failed),
          onTap: () {},
          accountColor: Colors.teal,
        ),
      ),
    ));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byKey(const Key('accountColorDot')), findsNothing);
  });

  testWidgets('shows the sender\'s display name in the subtitle when known, not the raw email',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(
            sendStatus: MailSendStatus.none,
            from: 'chris@example.com',
            fromName: 'Chris Quinones',
          ),
          onTap: () {},
        ),
      ),
    ));

    expect(find.textContaining('Chris Quinones — snippet'), findsOneWidget);
    expect(find.textContaining('chris@example.com'), findsNothing);
  });

  testWidgets('falls back to the email address in the subtitle when no display name is known',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none, from: 'noreply@example.com'),
          onTap: () {},
        ),
      ),
    ));

    expect(find.textContaining('noreply@example.com — snippet'), findsOneWidget);
  });

  testWidgets('formats the trailing date via formatMessageDate, not a raw numeric month/day',
      (tester) async {
    // Relative to whenever this test actually runs, not a hardcoded date —
    // formatMessageDate's own behavior matrix is already covered exhaustively
    // by message_date_format_test.dart; this only checks the widget wires it
    // in at all.
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none).copyWith(date: yesterday),
          onTap: () {},
        ),
      ),
    ));

    expect(find.text('Yesterday'), findsOneWidget);
  });

  testWidgets('does not show a selection checkbox when selected is null (default browsing)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byKey(const Key('selectionCheckbox')), findsNothing);
  });

  testWidgets('shows an unfilled round checkbox when selected: false', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: false,
        ),
      ),
    ));

    final box = tester.widget<Container>(find.byKey(const Key('selectionCheckbox')));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('shows a filled round checkbox with a checkmark when selected: true', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: true,
        ),
      ),
    ));

    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final box = tester.widget<Container>(find.byKey(const Key('selectionCheckbox')));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, scheme.primary);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tints the row background when selected: true', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: true,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, isNotNull);
  });

  testWidgets('does not tint the row background when selected: false', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          selected: false,
        ),
      ),
    ));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.tileColor, isNull);
  });

  testWidgets('fires onLongPress when the row is long-pressed', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageListTile(
          message: message(sendStatus: MailSendStatus.none),
          onTap: () {},
          onLongPress: () => longPressed = true,
        ),
      ),
    ));

    await tester.longPress(find.byType(ListTile));

    expect(longPressed, isTrue);
  });
}
