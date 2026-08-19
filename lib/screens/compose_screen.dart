import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/transport/mail_sender.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/compose_providers.dart';
import '../providers/message_providers.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, required this.accountId, this.replyTo, this.forwardOf});

  final int accountId;
  final MailMessage? replyTo;
  final MailMessage? forwardOf;

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
      text: widget.forwardOf != null ? '\n\n---\n${widget.forwardOf!.bodyText ?? ''}' : '',
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

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final accounts = await ref.read(accountsProvider.future);
      final account = accounts.firstWhere((a) => a.id == widget.accountId);
      final composed = ComposedMessage(
        to: _to.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        cc: _cc.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        bcc: _bcc.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        subject: _subject.text.trim(),
        bodyText: _body.text,
        bodyHtml: null,
        attachmentFilePaths: _attachmentPaths,
      );
      final send = ref.read(sendMessageProvider);
      await send(account, composed);
      // ComposeScreen has no MailFolder in scope (only an accountId), so it
      // can't target the specific Sent/Outbox family instance the way
      // MessageDetailScreen's delete flow can. Invalidating the whole family
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
            child: Text(_sending ? 'Sending...' : 'Send'),
          ),
        ],
      ),
    );
  }
}
