import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../data/transport/mail_sender.dart';
import '../models/mail_attachment.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/compose_providers.dart';
import '../providers/filesystem_providers.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';
import '../providers/send_sound_providers.dart';
import '../utils/html_text.dart';

/// The body text to quote when forwarding [message]: its plain-text part
/// when it has one, otherwise its HTML part with tags stripped (a
/// text/plain-only fallback here left HTML-only messages — common, plenty
/// of real mail has no text/plain part at all — forwarding with an empty
/// quoted body, since bodyText is simply null for those), with blank-line
/// runs collapsed either way.
String _quotedBody(MailMessage message) =>
    _collapseBlankLines(message.bodyText ?? stripHtml(message.bodyHtml ?? ''));

/// Trims each line and collapses runs of blank lines down to a single one,
/// then trims the whole result.
///
/// Real mail routinely carries dozens of blank/whitespace-only lines before
/// any actual content — an HTML message's pretty-printed indentation is
/// still there once stripHtml removes only the tags, and even some
/// senders' plain-text parts are themselves templated with the same
/// padding. Left uncollapsed, a forwarded message's real content can end up
/// so far down the quoted body that it looks completely empty at a glance
/// — confirmed live: a real forwarded message's quoted body started with
/// over 400 characters of blank lines before its first visible word.
String _collapseBlankLines(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n')).map((line) => line.trim());
  final result = <String>[];
  var lastWasBlank = false;
  for (final line in lines) {
    final isBlank = line.isEmpty;
    if (isBlank && lastWasBlank) continue;
    result.add(line);
    lastWasBlank = isBlank;
  }
  return result.join('\n').trim();
}

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    required this.accountId,
    this.replyTo,
    this.forwardOf,
    this.folder,
    this.forwardAttachments = const [],
  });

  final int accountId;
  final MailMessage? replyTo;
  final MailMessage? forwardOf;

  /// The folder [forwardOf] lives in — needed only to download
  /// [forwardAttachments] (MailRepository.downloadAttachment addresses the
  /// server via account+folder+message, not the attachment alone). Unused
  /// when [forwardAttachments] is empty.
  final MailFolder? folder;

  /// [forwardOf]'s own attachments, offered as an "include the original
  /// attachment(s)" checkbox rather than attached unconditionally — see
  /// _send's _resolveOriginalAttachmentPaths for how these get downloaded
  /// (or reused, if already cached locally) at send time.
  final List<MailAttachment> forwardAttachments;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  late final TextEditingController _to;
  late final TextEditingController _cc = TextEditingController();
  late final TextEditingController _bcc = TextEditingController();
  late final TextEditingController _subject;
  late final TextEditingController _body;
  final List<String> _attachmentPaths = [];
  bool _includeOriginalAttachments = true;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final source = widget.replyTo ?? widget.forwardOf;
    _to = TextEditingController(text: widget.replyTo?.from ?? '');
    _subject = TextEditingController(
      text: source == null
          ? ''
          : widget.replyTo != null
              ? 'Re: ${source.subject}'
              : 'Fwd: ${source.subject}',
    );
    _body = TextEditingController(
      text: widget.forwardOf != null ? '\n\n---\n${_quotedBody(widget.forwardOf!)}' : '',
    );
    for (final controller in [_to, _cc, _bcc, _subject, _body]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _to.dispose();
    _cc.dispose();
    _bcc.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _isValid => _to.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  Future<void> _pickAttachment() async {
    // NOTE: deviates from the brief, which calls `FilePicker.platform.pickFiles()`
    // and reads `result.files.single.path`. The installed file_picker (^12.0.0)
    // dropped the `FilePicker.platform` singleton in favor of static methods
    // directly on `FilePicker`, and added a single-file `pickFile()` that
    // returns `PlatformFile?` directly — a closer match for "pick one file"
    // than `pickFiles()`'s `FilePickerResult` (a list of files).
    final file = await FilePicker.pickFile();
    final path = file?.path;
    if (path != null) setState(() => _attachmentPaths.add(path));
  }

  /// Local file paths for [ComposeScreen.forwardAttachments], to append
  /// alongside whatever the user separately picked via [_pickAttachment].
  /// Empty (no repository/network work at all) unless the "include original
  /// attachment(s)" checkbox is on and there's actually something to
  /// forward. An attachment already downloaded (e.g. the user opened it
  /// from MessageDetailScreen before forwarding) reuses its cached
  /// `localPath` instead of re-fetching it.
  Future<List<String>> _resolveOriginalAttachmentPaths() async {
    if (!_includeOriginalAttachments || widget.forwardAttachments.isEmpty) return const [];
    final repository = await ref.read(mailRepositoryProvider.future);
    final accounts = await ref.read(accountsProvider.future);
    final account = accounts.firstWhere((a) => a.id == widget.accountId);
    final paths = <String>[];
    for (final attachment in widget.forwardAttachments) {
      final cached = attachment.localPath;
      if (cached != null) {
        paths.add(cached);
        continue;
      }
      final bytes = await repository.downloadAttachment(
        account,
        widget.folder!,
        widget.forwardOf!,
        attachment,
      );
      final dir = await ref.read(documentsDirectoryProvider.future);
      final file = File(p.join(dir.path, attachment.filename));
      file.writeAsBytesSync(bytes);
      if (attachment.id != null) {
        await repository.recordAttachmentLocalPath(attachment.id!, file.path);
      }
      paths.add(file.path);
    }
    return paths;
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.accountId);
      final originalAttachmentPaths = await _resolveOriginalAttachmentPaths();
      final composed = ComposedMessage(
        to: _to.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        cc: _cc.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        bcc: _bcc.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        subject: _subject.text.trim(),
        bodyText: _body.text,
        bodyHtml: null,
        attachmentFilePaths: [..._attachmentPaths, ...originalAttachmentPaths],
      );
      final send = ref.read(sendMessageProvider);
      await send(account, composed);
      // Fire-and-forget: SendSoundPlayer.play() never throws and this is
      // pure UI polish, not part of the send operation — don't hold up
      // popping the screen waiting for a ~1s sound effect to finish.
      unawaited(ref.read(sendSoundPlayerProvider).play());
      // ComposeScreen has no Sent/Outbox MailFolder in scope (widget.folder,
      // when set, is only forwardOf's source folder) — can't target the
      // specific Sent/Outbox family instance the way MessageDetailScreen's
      // delete flow can. Invalidating the whole family
      // is the reachable, still-correct blanket fix: any folder view
      // currently alive re-syncs next time it's read instead of showing
      // stale contents until a manual pull-to-refresh.
      ref.invalidate(messagesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compose')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(key: const Key('toField'), controller: _to,
              decoration: const InputDecoration(labelText: 'To')),
          TextField(key: const Key('ccField'), controller: _cc,
              decoration: const InputDecoration(labelText: 'Cc')),
          TextField(key: const Key('bccField'), controller: _bcc,
              decoration: const InputDecoration(labelText: 'Bcc')),
          TextField(key: const Key('subjectField'), controller: _subject,
              decoration: const InputDecoration(labelText: 'Subject')),
          TextField(key: const Key('bodyField'), controller: _body, maxLines: 10,
              decoration: const InputDecoration(labelText: 'Message')),
          if (widget.forwardAttachments.isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _includeOriginalAttachments,
              onChanged: (value) => setState(() => _includeOriginalAttachments = value ?? true),
              title: Text(
                'Include ${widget.forwardAttachments.length} original attachment'
                '${widget.forwardAttachments.length == 1 ? '' : 's'}',
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickAttachment,
            icon: const Icon(Icons.attach_file),
            label: Text(_attachmentPaths.isEmpty ? 'Attach file' : '${_attachmentPaths.length} attached'),
          ),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isValid && !_sending ? _send : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
            ),
            child: Text(_sending ? 'Sending...' : 'Send'),
          ),
        ],
      ),
    );
  }
}
