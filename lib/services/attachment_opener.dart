import 'package:open_filex/open_filex.dart';

/// Presents a downloaded attachment using the OS's native file preview /
/// associated app — on iOS, `UIDocumentInteractionController`'s
/// QuickLook-style preview, which has its own built-in Share/Action button
/// for saving to Files, saving to Photos (for images), AirDrop, etc. That's
/// why this app doesn't build its own save-destination picker: the native
/// preview already is one. See MessageDetailScreen's `_openAttachment`.
abstract class AttachmentOpener {
  /// Returns true if the OS successfully opened/previewed the file, false
  /// otherwise (e.g. no viewer available for that file type). Never throws.
  Future<bool> open(String path);
}

class PlatformAttachmentOpener implements AttachmentOpener {
  /// [openFile] is an injectable seam for tests — it defaults to the real
  /// `OpenFilex.open` and should never be supplied in production code.
  /// `OpenFilex.open` branches internally on `Platform.isIOS`/`.isAndroid`,
  /// which are both false under a host `flutter test` run, so tests can't
  /// exercise this class's actual logic through the real call at all.
  PlatformAttachmentOpener({Future<OpenResult> Function(String path)? openFile})
    : _openFile = openFile ?? OpenFilex.open;

  final Future<OpenResult> Function(String path) _openFile;

  @override
  Future<bool> open(String path) async {
    final result = await _openFile(path);
    return result.type == ResultType.done;
  }
}
