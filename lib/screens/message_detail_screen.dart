import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/mail_attachment.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/repository_providers.dart';
import '../widgets/attachment_tile.dart';

class MessageDetailScreen extends ConsumerStatefulWidget {
  const MessageDetailScreen({super.key, required this.folder, required this.message});

  final MailFolder folder;
  final MailMessage message;

  @override
  ConsumerState<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends ConsumerState<MessageDetailScreen> {
  MailMessage? _resolved;
  List<MailAttachment> _attachments = [];
  int? _downloadingAttachmentId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repository = await ref.read(mailRepositoryProvider.future);
    final accounts = await ref.read(accountsProvider.future);
    final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
    final resolved = await repository.fetchBodyIfNeeded(account, widget.folder, widget.message);
    if (mounted) setState(() => _resolved = resolved);
  }

  Future<void> _downloadAttachment(MailAttachment attachment) async {
    setState(() => _downloadingAttachmentId = attachment.id);
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
      final bytes = await repository.downloadAttachment(account, widget.folder, widget.message, attachment);
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, attachment.filename));
      await file.writeAsBytes(bytes);
      await repository.recordAttachmentLocalPath(attachment.id!, file.path);
      if (mounted) {
        setState(() {
          _attachments = _attachments
              .map((a) => a.id == attachment.id ? a.copyWith(localPath: file.path) : a)
              .toList();
        });
      }
    } finally {
      if (mounted) setState(() => _downloadingAttachmentId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _resolved ?? widget.message;
    return Scaffold(
      appBar: AppBar(title: Text(message.subject)),
      body: message.isDownloaded
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(message.subject, style: Theme.of(context).textTheme.titleLarge),
                Text('From: ${message.from}'),
                Text('To: ${message.to}'),
                const Divider(),
                if (message.bodyHtml != null)
                  HtmlWidget(message.bodyHtml!)
                else
                  Text(message.bodyText ?? ''),
                const Divider(),
                ..._attachments.map((attachment) => AttachmentTile(
                      attachment: attachment,
                      downloading: _downloadingAttachmentId == attachment.id,
                      onDownload: () => _downloadAttachment(attachment),
                    )),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
