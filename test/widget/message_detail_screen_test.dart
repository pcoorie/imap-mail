import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';

void main() {
  final folder = MailFolder(id: 1, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);

  testWidgets('renders plain text body when no HTML is present', (tester) async {
    final message = MailMessage(
      id: 10,
      folderId: 1,
      uid: 1,
      subject: 'Hello',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'Hi',
      bodyText: 'Hi there, this is the plain body.',
      isDownloaded: true,
    );

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: MessageDetailScreen(folder: folder, message: message)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Hi there, this is the plain body.'), findsOneWidget);
  });
}
