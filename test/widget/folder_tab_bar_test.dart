import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/widgets/folder_tab_bar.dart';

void main() {
  final inbox = MailFolder(
    id: 1,
    accountId: 1,
    name: 'Inbox',
    path: 'INBOX',
    type: MailFolderType.inbox,
    unreadCount: 4,
  );
  final sent = MailFolder(
    id: 2,
    accountId: 1,
    name: 'Sent',
    path: 'Sent',
    type: MailFolderType.sent,
  );

  testWidgets('shows an unread-count badge on a folder with unread messages', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FolderTabBar(folders: [inbox, sent], selected: inbox, onSelect: (_) {}),
      ),
    ));

    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('shows no badge on a folder with zero unread messages', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FolderTabBar(folders: [inbox, sent], selected: inbox, onSelect: (_) {}),
      ),
    ));

    expect(find.text('0'), findsNothing);
  });

  testWidgets('still shows the folder name alongside the badge', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FolderTabBar(folders: [inbox, sent], selected: inbox, onSelect: (_) {}),
      ),
    ));

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
  });
}
