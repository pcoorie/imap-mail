import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/attachment_opener.dart';

final attachmentOpenerProvider = Provider<AttachmentOpener>((ref) => PlatformAttachmentOpener());
