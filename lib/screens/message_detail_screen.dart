import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:path/path.dart' as p;
import '../models/enums.dart';
import '../models/mail_attachment.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../data/transport/mail_transport.dart';
import '../providers/account_providers.dart';
import '../providers/attachment_opener_providers.dart';
import '../providers/filesystem_providers.dart';
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

  // Tracked so _forward() can await whichever _load() call is currently in
  // flight (the initial one, or a Retry's) instead of racing it — see
  // _forward's own doc comment.
  Future<void>? _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
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
      // view from rendering its already-fetched content. Swallow any error
      // (e.g. offline) rather than surfacing it here — this isn't a swipe
      // action, there's no retry affordance on this screen for it.
      //
      // revertLocalOnFailure: false for exactly that reason. The server sync
      // is still attempted, but a failure must not undo the local read flag:
      // with no Retry UI and the error swallowed below, reverting would mean
      // opening and reading a cached message offline silently never marks it
      // read, with zero feedback.
      if (resolved.id != null) {
        unawaited(repository
            .markRead(account, widget.folder, resolved, true, revertLocalOnFailure: false)
            .catchError((_) {}));
      }
    } on MessageNotFoundException {
      // The repository already dropped the now-confirmed-gone local row.
      // Invalidate the folder's list so navigating back doesn't still show
      // it, and explain what happened rather than leaving a generic error
      // whose Retry button would just repeat the same "gone" fetch forever.
      ref.invalidate(messagesProvider(widget.folder));
      if (mounted) {
        setState(() => _error =
            'This message no longer exists — it may have been deleted on another device.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not load message: $e');
      }
    }
  }

  /// Pushes ComposeScreen to forward this message, first waiting for
  /// whichever _load() call is currently in flight.
  ///
  /// Without this, tapping the AppBar's Forward icon — which is enabled the
  /// instant the screen appears, before _load()'s body fetch has finished —
  /// forwarded `widget.message`: the un-hydrated row from the list, whose
  /// bodyText/bodyHtml are both null until a message has actually been
  /// opened once. The result was a forwarded email with no content at all,
  /// just the "---" quote separator.
  Future<void> _forward() async {
    await _loadFuture;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComposeScreen(
          accountId: widget.folder.accountId,
          forwardOf: _resolved ?? widget.message,
          folder: widget.folder,
          forwardAttachments: _attachments,
        ),
      ),
    );
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
        if (!mounted) return;
        final accounts = await ref.read(accountsProvider.future);
        if (!mounted) return;
        final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
        await repository.deleteMessage(account, widget.folder, _resolved ?? widget.message);
        // Guarded because deleting is now a full IMAP MOVE round-trip, not
        // the instant local DAO write it used to be: pressing back during a
        // slow delete disposes this State, and `ref` throws a StateError
        // once disposed.
        if (!mounted) return;
        // Without this, the folder view keeps showing the just-deleted
        // message until a manual pull-to-refresh.
        ref.invalidate(messagesProvider(widget.folder));
        Navigator.of(context).pop();
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

  /// Downloads [attachment] if it isn't cached locally yet, then hands it to
  /// the OS's native preview (see `AttachmentOpener`) — a single tap does
  /// both, matching Apple Mail. The native preview's own Share/Action button
  /// is where the user gets "save to Files/Photos/AirDrop", so there's no
  /// separate save-destination popup here.
  Future<void> _openAttachment(MailAttachment attachment) async {
    setState(() {
      _downloadingAttachmentId = attachment.id;
      _error = null;
    });
    try {
      var current = attachment;
      if (current.localPath == null) {
        final repository = await ref.read(mailRepositoryProvider.future);
        final accounts = await ref.read(accountsProvider.future);
        final account = accounts.firstWhere((a) => a.id == widget.folder.accountId);
        final bytes = await repository.downloadAttachment(account, widget.folder, widget.message, current);
        final dir = await ref.read(documentsDirectoryProvider.future);
        final file = File(p.join(dir.path, current.filename));
        // Synchronous write, deliberately: attachments are small-to-medium
        // documents, not multi-gigabyte streams, so blocking briefly here
        // costs nothing noticeable. The async `writeAsBytes` dispatches to
        // Dart's IO isolate and waits for it to post back — under a widget
        // test's fake-async zone that crossing never resolves (the exact
        // same class of hang this file's own databaseFactoryFfiNoIsolate
        // comment already documents for sqflite's isolate dispatch).
        file.writeAsBytesSync(bytes);
        await repository.recordAttachmentLocalPath(current.id!, file.path);
        current = current.copyWith(localPath: file.path);
        if (mounted) {
          setState(() {
            _attachments = _attachments.map((a) => a.id == current.id ? current : a).toList();
          });
        }
      }
      final opened = await ref.read(attachmentOpenerProvider).open(current.localPath!);
      if (!opened && mounted) {
        setState(() => _error = 'Could not open ${current.filename} — no app available to view it.');
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
            onPressed: _forward,
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
                  ElevatedButton(
                    onPressed: () => _loadFuture = _load(),
                    child: const Text('Retry'),
                  ),
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
                          onTap: () => _openAttachment(attachment),
                        )),
                  ],
                )
              : const Center(child: CircularProgressIndicator()),
    );
  }
}
