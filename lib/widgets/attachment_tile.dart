import 'package:flutter/material.dart';
import '../models/mail_attachment.dart';

class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.attachment, required this.onDownload, this.downloading = false});

  final MailAttachment attachment;
  final VoidCallback onDownload;
  final bool downloading;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.attach_file),
      title: Text(attachment.filename),
      subtitle: Text('${(attachment.size / 1024).toStringAsFixed(1)} KB'),
      trailing: attachment.localPath != null
          ? const Icon(Icons.check_circle, color: Colors.green)
          : IconButton(
              icon: downloading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              onPressed: downloading ? null : onDownload,
            ),
    );
  }
}
