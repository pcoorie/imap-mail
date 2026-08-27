import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/data/transport/mail_sender.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_attachment.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/compose_providers.dart';
import 'package:imap_mail/providers/filesystem_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/send_sound_providers.dart';
import 'package:imap_mail/screens/compose_screen.dart';
import 'package:imap_mail/services/send_sound_player.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);

  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class MockMailRepository extends Mock implements MailRepository {}

class _FakeSendSoundPlayer implements SendSoundPlayer {
  int playCount = 0;

  @override
  Future<void> play() async {
    playCount++;
  }
}

// The form (To/Cc/Bcc/Subject/Message with maxLines: 10 + attach button +
// Send button) is taller than the default 800x600 test viewport plus the
// ListView's default cache extent. Without this, the Send button isn't even
// built (find() returns zero matches, not just an off-screen widget), and the
// body TextField's own internal Scrollable makes plain scrolling ambiguous
// (more than one Scrollable in the tree). Growing the viewport sidesteps both
// problems; production layout is untouched.
void _growViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  const account = MailAccount(
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

  setUpAll(() {
    registerFallbackValue(account);
    registerFallbackValue(const MailFolder(accountId: 1, name: '', path: '', type: MailFolderType.inbox));
    registerFallbackValue(MailMessage(
      folderId: 1,
      uid: 1,
      subject: '',
      from: '',
      to: '',
      date: DateTime.utc(2026, 1, 1),
      snippet: '',
    ));
    registerFallbackValue(const MailAttachment(messageId: 1, filename: '', mimeType: '', size: 0));
  });

  testWidgets('Send is disabled until a recipient and body are entered', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');
    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNull);

    expect(find.byKey(const Key('bccField')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNotNull);
  });

  testWidgets('Bcc is optional and does not block Send once required fields are filled', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.enterText(find.byKey(const Key('bccField')), 'secret@example.com');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(sendButtonFinder).onPressed, isNotNull);
  });

  testWidgets('shows an inline error and keeps content when send fails', (tester) async {
    _growViewport(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sendMessageProvider.overrideWithValue((MailAccount account, ComposedMessage message) async {
          throw Exception('smtp unreachable');
        }),
        // The real accountsProvider chain reaches through database/path_provider
        // platform channels, which never settle inside a widget test's fake
        // async zone (see folder_view_screen_test.dart / message_detail_screen_test.dart
        // for the same established fix). _send() reads accountsProvider.future to
        // resolve the MailAccount, so we override it with a fake notifier to avoid
        // that unrelated real-IO chain hanging pumpAndSettle below.
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
      ],
      child: const MaterialApp(home: ComposeScreen(accountId: 1)),
    ));

    await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
    await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
    await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
    await tester.pump();

    final sendButtonFinder = find.widgetWithText(ElevatedButton, 'Send');
    await tester.tap(sendButtonFinder);
    await tester.pumpAndSettle();

    expect(find.textContaining('smtp unreachable'), findsOneWidget);
    expect(find.text('Hello Bob'), findsOneWidget); // body field still has the content
  });

  group('send sound', () {
    testWidgets('plays after a successful send', (tester) async {
      _growViewport(tester);
      final soundPlayer = _FakeSendSoundPlayer();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sendMessageProvider.overrideWithValue((MailAccount a, ComposedMessage m) async {}),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          sendSoundPlayerProvider.overrideWithValue(soundPlayer),
        ],
        child: const MaterialApp(home: ComposeScreen(accountId: 1)),
      ));

      await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
      await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
      await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
      await tester.pumpAndSettle();

      expect(soundPlayer.playCount, 1);
    });

    testWidgets('does not play when the send fails', (tester) async {
      _growViewport(tester);
      final soundPlayer = _FakeSendSoundPlayer();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sendMessageProvider.overrideWithValue((MailAccount a, ComposedMessage m) async {
            throw Exception('smtp unreachable');
          }),
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          sendSoundPlayerProvider.overrideWithValue(soundPlayer),
        ],
        child: const MaterialApp(home: ComposeScreen(accountId: 1)),
      ));

      await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
      await tester.enterText(find.byKey(const Key('subjectField')), 'Hi');
      await tester.enterText(find.byKey(const Key('bodyField')), 'Hello Bob');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
      await tester.pumpAndSettle();

      expect(soundPlayer.playCount, 0);
    });
  });

  group('forwarding', () {
    MailMessage messageWith({String? bodyText, String? bodyHtml}) => MailMessage(
          folderId: 1,
          uid: 1,
          subject: 'Original subject',
          from: 'alice@example.com',
          to: 'me@example.com',
          date: DateTime(2026, 1, 1),
          snippet: 'snippet',
          bodyText: bodyText,
          bodyHtml: bodyHtml,
          isDownloaded: true,
        );

    testWidgets('quotes the plain-text body when the message has one', (tester) async {
      _growViewport(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            forwardOf: messageWith(bodyText: 'Plain body content'),
          ),
        ),
      ));

      final bodyField = tester.widget<TextField>(find.byKey(const Key('bodyField')));
      expect(bodyField.controller!.text, contains('Plain body content'));
    });

    testWidgets(
      'falls back to the HTML body, stripped of tags, when the message has no plain-text part '
      '(regression: forwarding an HTML-only message used to produce an empty quoted body)',
      (tester) async {
        _growViewport(tester);
        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            home: ComposeScreen(
              accountId: 1,
              forwardOf: messageWith(bodyHtml: '<p>HTML-only body content</p>'),
            ),
          ),
        ));

        final bodyField = tester.widget<TextField>(find.byKey(const Key('bodyField')));
        expect(bodyField.controller!.text, contains('HTML-only body content'));
      },
    );

    testWidgets(
      'collapses the pretty-printed whitespace an HTML email leaves behind after tag-stripping '
      '(regression: real forwarded content ended up 400+ characters of blank lines down, '
      'making the compose body look empty at a glance)',
      (tester) async {
        _growViewport(tester);
        // Shaped like a real HTML email's source: lots of indentation/blank
        // lines between tags before any real text appears — exactly what
        // stripHtml (tag removal only, no whitespace normalization) leaves
        // behind untouched.
        final html = '<html><body>\r\n'
            '${'    \r\n' * 20}'
            '<p>The real content, buried under indentation.</p>\r\n'
            '${'    \r\n' * 10}'
            '</body></html>';
        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            home: ComposeScreen(accountId: 1, forwardOf: messageWith(bodyHtml: html)),
          ),
        ));

        final bodyField = tester.widget<TextField>(find.byKey(const Key('bodyField')));
        final text = bodyField.controller!.text;
        expect(text, contains('The real content, buried under indentation.'));
        // The whole point: that line must be reachable near the top, not
        // pushed hundreds of characters down by uncollapsed blank lines.
        expect(text.indexOf('The real content'), lessThan(50));
      },
    );

    testWidgets(
      'collapses blank-line runs in a plain-text body too, not just HTML '
      '(some senders template bodyText with the same padding)',
      (tester) async {
        _growViewport(tester);
        final bodyText = '${'  \r\n' * 20}Hi Peter,${'\r\n' * 5}Real content here.';
        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            home: ComposeScreen(accountId: 1, forwardOf: messageWith(bodyText: bodyText)),
          ),
        ));

        final bodyField = tester.widget<TextField>(find.byKey(const Key('bodyField')));
        final text = bodyField.controller!.text;
        expect(text, contains('Hi Peter,'));
        expect(text.indexOf('Hi Peter,'), lessThan(20));
      },
    );
  });

  group('forwarding with attachments', () {
    const folder = MailFolder(id: 1, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);

    // Created in setUp (real async, outside testWidgets' fake-async zone),
    // not inline in a test body — see message_detail_screen_test.dart's own
    // tempDocsDir for the same established fix: a real
    // Directory.systemTemp.createTemp() awaited directly inside a
    // testWidgets callback never resolves (the same class of
    // isolate-crossing hang documented there for `File.writeAsBytes`).
    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('compose_screen_attachment_test');
    });
    tearDown(() => tempDir.delete(recursive: true));

    MailMessage forwardMessage() => MailMessage(
          id: 42,
          folderId: 1,
          uid: 1,
          subject: 'Original subject',
          from: 'alice@example.com',
          to: 'me@example.com',
          date: DateTime(2026, 1, 1),
          snippet: 'snippet',
          bodyText: 'Plain body',
          isDownloaded: true,
        );

    testWidgets('shows no attachment checkbox when the forwarded message has none', (tester) async {
      _growViewport(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ComposeScreen(accountId: 1, folder: folder, forwardOf: forwardMessage()),
        ),
      ));

      expect(find.textContaining('original attachment'), findsNothing);
    });

    testWidgets('shows a checked-by-default checkbox to include the original attachment(s)', (tester) async {
      _growViewport(tester);
      const attachments = [
        MailAttachment(id: 1, messageId: 42, filename: 'invoice.pdf', mimeType: 'application/pdf', size: 2048),
      ];
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            folder: folder,
            forwardOf: forwardMessage(),
            forwardAttachments: attachments,
          ),
        ),
      ));

      expect(find.text('Include 1 original attachment'), findsOneWidget);
      final checkbox = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
      expect(checkbox.value, isTrue);
    });

    testWidgets('pluralizes the checkbox label for more than one attachment', (tester) async {
      _growViewport(tester);
      const attachments = [
        MailAttachment(id: 1, messageId: 42, filename: 'invoice.pdf', mimeType: 'application/pdf', size: 2048),
        MailAttachment(id: 2, messageId: 42, filename: 'lease.pdf', mimeType: 'application/pdf', size: 4096),
      ];
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            folder: folder,
            forwardOf: forwardMessage(),
            forwardAttachments: attachments,
          ),
        ),
      ));

      expect(find.text('Include 2 original attachments'), findsOneWidget);
    });

    testWidgets('sending downloads and includes the original attachment when the checkbox is checked',
        (tester) async {
      _growViewport(tester);
      const attachment =
          MailAttachment(id: 1, messageId: 42, filename: 'invoice.pdf', mimeType: 'application/pdf', size: 3);
      final repository = MockMailRepository();
      when(() => repository.downloadAttachment(any(), any(), any(), any())).thenAnswer((_) async => [1, 2, 3]);
      when(() => repository.recordAttachmentLocalPath(any(), any())).thenAnswer((_) async {});
      ComposedMessage? sent;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          documentsDirectoryProvider.overrideWith((ref) async => tempDir),
          sendMessageProvider.overrideWithValue((MailAccount a, ComposedMessage m) async {
            sent = m;
          }),
        ],
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            folder: folder,
            forwardOf: forwardMessage(),
            forwardAttachments: const [attachment],
          ),
        ),
      ));

      await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
      await tester.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!.attachmentFilePaths, hasLength(1));
      expect(sent!.attachmentFilePaths.single, endsWith('invoice.pdf'));
      verify(() => repository.downloadAttachment(any(), any(), any(), any())).called(1);
    });

    testWidgets(
        'sending excludes the original attachment when the checkbox is unchecked, without downloading it',
        (tester) async {
      _growViewport(tester);
      const attachment =
          MailAttachment(id: 1, messageId: 42, filename: 'invoice.pdf', mimeType: 'application/pdf', size: 3);
      final repository = MockMailRepository();
      when(() => repository.downloadAttachment(any(), any(), any(), any())).thenAnswer((_) async => [1, 2, 3]);
      ComposedMessage? sent;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          sendMessageProvider.overrideWithValue((MailAccount a, ComposedMessage m) async {
            sent = m;
          }),
        ],
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            folder: folder,
            forwardOf: forwardMessage(),
            forwardAttachments: const [attachment],
          ),
        ),
      ));

      await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
      await tester.tap(find.text('Include 1 original attachment'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
      await tester.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!.attachmentFilePaths, isEmpty);
      verifyNever(() => repository.downloadAttachment(any(), any(), any(), any()));
    });

    testWidgets('reuses an already-downloaded original attachment instead of re-downloading it',
        (tester) async {
      _growViewport(tester);
      const attachment = MailAttachment(
        id: 1,
        messageId: 42,
        filename: 'invoice.pdf',
        mimeType: 'application/pdf',
        size: 3,
        localPath: '/already/downloaded/invoice.pdf',
      );
      final repository = MockMailRepository();
      ComposedMessage? sent;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
          mailRepositoryProvider.overrideWith((ref) async => repository),
          sendMessageProvider.overrideWithValue((MailAccount a, ComposedMessage m) async {
            sent = m;
          }),
        ],
        child: MaterialApp(
          home: ComposeScreen(
            accountId: 1,
            folder: folder,
            forwardOf: forwardMessage(),
            forwardAttachments: const [attachment],
          ),
        ),
      ));

      await tester.enterText(find.byKey(const Key('toField')), 'bob@example.com');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
      await tester.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!.attachmentFilePaths, ['/already/downloaded/invoice.pdf']);
      verifyNever(() => repository.downloadAttachment(any(), any(), any(), any()));
    });
  });
}
