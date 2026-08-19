import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/enums.dart';
import '../models/mail_attachment.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';
import '../widgets/attachment_tile.dart';
import 'compose_screen.dart';

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
  String? _error;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
      final resolved = await repository.fetchBodyIfNeeded(account, widget.folder, widget.message);
      final attachments = await repository.getAttachments(widget.message.id!);
      if (mounted) {
        setState(() {
          _resolved = resolved;
          _attachments = attachments;
        });
      }
      // Fire-and-forget: marking a message read shouldn't block or fail the
      // view from rendering its already-fetched content.
      if (resolved.id != null) {
        unawaited(repository.markAsRead(resolved.id!));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not load message: $e');
      }
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text('Moves it to Trash, or removes it if already there.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final repository = await ref.read(mailRepositoryProvider.future);
        await repository.deleteMessage(widget.folder, _resolved ?? widget.message);
        // Without this, the folder view keeps showing the just-deleted
        // message until a manual pull-to-refresh.
        ref.invalidate(messagesProvider(widget.folder));
        if (mounted) {
          Navigator.of(context).pop();
        }
      } catch (e) {
        if (mounted) {
          setState(() => _error = 'Could not delete message: $e');
        }
      }
    }
  }

  Future<void> _retrySend() async {
    setState(() {
      _retrying = true;
      _error = null;
    });
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
      await repository.retryFailedMessage(account, _resolved ?? widget.message);
      ref.invalidate(messagesProvider(widget.folder));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not resend message: $e');
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _downloadAttachment(MailAttachment attachment) async {
    setState(() {
      _downloadingAttachmentId = attachment.id;
      _error = null;
    });
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
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not download attachment: $e');
      }
    } finally {
      if (mounted) setState(() => _downloadingAttachmentId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _resolved ?? widget.message;
    final failedToSend = message.sendStatus == MailSendStatus.failed;
    return Scaffold(
      appBar: AppBar(
        title: Text(message.subject),
        actions: [
          if (failedToSend)
            IconButton(
              icon: _retrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Retry sending',
              onPressed: _retrying ? null : _retrySend,
            ),
          IconButton(
            icon: const Icon(Icons.reply),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ComposeScreen(
                accountId: widget.folder.accountId,
                replyTo: message,
              )),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.forward),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ComposeScreen(
                accountId: widget.folder.accountId,
                forwardOf: message,
              )),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmDelete,
          ),
        ],
      ),
      body: _error != null && _resolved == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : message.isDownloaded
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!, style: const TextStyle(color: Colors.red)),
                      ),
                    if (failedToSend)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Failed to send', style: TextStyle(color: Colors.red)),
                      ),
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
