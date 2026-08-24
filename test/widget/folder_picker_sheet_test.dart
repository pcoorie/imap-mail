import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/widgets/folder_picker_sheet.dart';

void main() {
  final archive = MailFolder(id: 1, accountId: 1, name: 'Archive', path: 'Archive', type: MailFolderType.archive);
  final work = MailFolder(id: 2, accountId: 1, name: 'Work', path: 'Work', type: MailFolderType.other);

  testWidgets('lists every folder and resolves with the tapped one', (tester) async {
    MailFolder? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showFolderPicker(context, [archive, work]);
          },
          child: const Text('Open'),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(result, work);
  });

  testWidgets('resolves with null when dismissed without a choice', (tester) async {
    MailFolder? result = archive; // sentinel — overwritten only if the sheet resolves
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showFolderPicker(context, [archive]);
          },
          child: const Text('Open'),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('does not overflow when given many folders', (tester) async {
    final manyFolders = List.generate(
      30,
      (i) => MailFolder(id: 10 + i, accountId: 1, name: 'Folder $i', path: 'Folder$i', type: MailFolderType.other),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showFolderPicker(context, manyFolders),
          child: const Text('Open'),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
