import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/services/attachment_opener.dart';
import 'package:open_filex/open_filex.dart';

/// `OpenFilex.open` branches internally on `Platform.isIOS`/`.isAndroid` —
/// under `flutter test` (running on the host machine, not a simulator),
/// neither is true, so it takes a desktop shell-`open` fallback path that
/// never touches the platform channel at all. Mocking the channel therefore
/// can't actually exercise `PlatformAttachmentOpener`'s mapping logic here —
/// hence the injectable `openFile` seam (same pattern as
/// `PlatformAppIconBadge`'s `requestNotificationPermission`), supplied only
/// in this test; production code always gets the real `OpenFilex.open`.
void main() {
  test('returns true when the OS reports the file was opened (type.done)', () async {
    final opener = PlatformAttachmentOpener(
      openFile: (path) async => OpenResult(type: ResultType.done),
    );

    final result = await opener.open('/some/report.pdf');

    expect(result, isTrue);
  });

  test('returns false when the OS reports no app can open the file', () async {
    final opener = PlatformAttachmentOpener(
      openFile: (path) async => OpenResult(type: ResultType.noAppToOpen),
    );

    final result = await opener.open('/some/report.xyz');

    expect(result, isFalse);
  });

  test('returns false on any other non-done result (fileNotFound, permissionDenied, error)', () async {
    for (final type in [ResultType.fileNotFound, ResultType.permissionDenied, ResultType.error]) {
      final opener = PlatformAttachmentOpener(openFile: (path) async => OpenResult(type: type));
      expect(await opener.open('/some/report.pdf'), isFalse, reason: 'for $type');
    }
  });

  test('passes the given path through to the underlying opener unchanged', () async {
    String? receivedPath;
    final opener = PlatformAttachmentOpener(
      openFile: (path) async {
        receivedPath = path;
        return OpenResult(type: ResultType.done);
      },
    );

    await opener.open('/some/report.pdf');

    expect(receivedPath, '/some/report.pdf');
  });
}
