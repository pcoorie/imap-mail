import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/widgets/account_color.dart';
import 'package:imap_mail/widgets/sender_avatar.dart';

void main() {
  group('senderInitials', () {
    test('takes first letter of first + last word from a multi-word name', () {
      expect(senderInitials(name: 'Chris Quinones', email: 'chris@example.com'), 'CQ');
    });

    test('skips middle words for a 3+ word name', () {
      expect(senderInitials(name: 'Mary Jane Watson', email: 'mj@example.com'), 'MW');
    });

    test('takes the first two letters of a single-word name', () {
      expect(senderInitials(name: 'GitHub', email: 'noreply@github.com'), 'GI');
    });

    test('uses the single available letter when a one-word name is one character', () {
      expect(senderInitials(name: 'X', email: 'x@example.com'), 'X');
    });

    test('falls back to the email local part when name is null', () {
      expect(senderInitials(name: null, email: 'noreply@example.com'), 'NO');
    });

    test('falls back to the email local part when name is blank', () {
      expect(senderInitials(name: '   ', email: 'noreply@example.com'), 'NO');
    });

    test('treats dots in the email local part as word breaks', () {
      expect(senderInitials(name: null, email: 'chris.quinones@example.com'), 'CQ');
    });

    test('treats underscores, hyphens and plus signs in the local part as word breaks too', () {
      expect(senderInitials(name: null, email: 'belinda_lewis@example.com'), 'BL');
      expect(senderInitials(name: null, email: 'belinda-lewis@example.com'), 'BL');
      expect(senderInitials(name: null, email: 'belinda+lewis@example.com'), 'BL');
    });

    test('uppercases the result', () {
      expect(senderInitials(name: 'chris quinones', email: 'chris@example.com'), 'CQ');
    });
  });

  group('SenderAvatar widget', () {
    testWidgets('renders as a round CircleAvatar with the computed initials and color', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SenderAvatar(name: 'Chris Quinones', email: 'chris@example.com'),
        ),
      ));

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundColor, senderColorFor('chris@example.com'));
      expect(find.text('CQ'), findsOneWidget);
    });

    testWidgets('the same email always gets the same color across separate avatars', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SenderAvatar(email: 'alice@example.com'),
              SenderAvatar(email: 'alice@example.com'),
            ],
          ),
        ),
      ));

      final avatars = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar)).toList();
      expect(avatars, hasLength(2));
      expect(avatars[0].backgroundColor, avatars[1].backgroundColor);
    });
  });
}
