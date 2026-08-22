import 'package:flutter/material.dart';
import '../models/mail_attachment.dart';

/// A tap on the whole row does the work now — downloads the attachment
/// first if needed, then opens it in the OS's native preview (which has its
/// own Share/Action button for saving elsewhere, so this widget doesn't need
/// a separate download button or a save-destination popup of its own). The
/// trailing icon is a pure status indicator: spinner while busy, checkmark
/// once a local copy exists, plain download glyph otherwise.
class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.attachment, required this.onTap, this.downloading = false});

  final MailAttachment attachment;
  final VoidCallback onTap;
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.attach_file),
      title: Text(attachment.filename),
      subtitle: Text('${(attachment.size / 1024).toStringAsFixed(1)} KB'),
      trailing: downloading
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : attachment.localPath != null
              ? const Icon(Icons.check_circle, color: Colors.green)
              : const Icon(Icons.download),
      onTap: downloading ? null : onTap,
    );
  }
}
