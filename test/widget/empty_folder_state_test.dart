import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/widgets/empty_folder_state.dart';

void main() {
  testWidgets('renders the given message and a placeholder icon', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EmptyFolderState(message: 'No messages in Trash')),
    ));

    expect(find.text('No messages in Trash'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
  });
}
