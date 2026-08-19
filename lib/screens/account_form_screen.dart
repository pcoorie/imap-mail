import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../providers/account_providers.dart';
import '../providers/repository_providers.dart';

class AccountFormScreen extends ConsumerStatefulWidget {
  const AccountFormScreen({super.key, this.existing});

  final MailAccount? existing;

  @override
  ConsumerState<AccountFormScreen> createState() => _AccountFormScreenState();
}

class _AccountFormScreenState extends ConsumerState<AccountFormScreen> {
  late final TextEditingController _displayName;
  late final TextEditingController _email;
  late final TextEditingController _imapHost;
  late final TextEditingController _imapPort;
  late final TextEditingController _smtpHost;
  late final TextEditingController _smtpPort;
  late final TextEditingController _username;
  final _password = TextEditingController();
  MailSecurity _imapSecurity = MailSecurity.ssl;
  MailSecurity _smtpSecurity = MailSecurity.ssl;
  String? _testResult;
  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _displayName = TextEditingController(text: existing?.displayName ?? '');
    _email = TextEditingController(text: existing?.email ?? '');
    _imapHost = TextEditingController(text: existing?.imapHost ?? '');
    _imapPort = TextEditingController(text: existing?.imapPort.toString() ?? '993');
    _smtpHost = TextEditingController(text: existing?.smtpHost ?? '');
    _smtpPort = TextEditingController(text: existing?.smtpPort.toString() ?? '465');
    _username = TextEditingController(text: existing?.username ?? '');
    _imapSecurity = existing?.imapSecurity ?? MailSecurity.ssl;
    _smtpSecurity = existing?.smtpSecurity ?? MailSecurity.ssl;
    for (final controller in [
      _displayName, _email, _imapHost, _imapPort, _smtpHost, _smtpPort, _username, _password,
    ]) {
      controller.addListener(() => setState(() {}));
    }
  }

  bool get _isValid =>
      _displayName.text.trim().isNotEmpty &&
      _email.text.trim().contains('@') &&
      _imapHost.text.trim().isNotEmpty &&
      int.tryParse(_imapPort.text.trim()) != null &&
      _smtpHost.text.trim().isNotEmpty &&
      int.tryParse(_smtpPort.text.trim()) != null &&
      _username.text.trim().isNotEmpty &&
      _password.text.isNotEmpty;

  MailAccount _buildAccount() {
    return MailAccount(
      id: widget.existing?.id,
      displayName: _displayName.text.trim(),
      email: _email.text.trim(),
      imapHost: _imapHost.text.trim(),
      imapPort: int.parse(_imapPort.text.trim()),
      imapSecurity: _imapSecurity,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.parse(_smtpPort.text.trim()),
      smtpSecurity: _smtpSecurity,
      username: _username.text.trim(),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final transport = ref.read(mailTransportProvider);
      await transport.testConnection(_buildAccount(), _password.text);
      setState(() => _testResult = 'Connection succeeded');
    } catch (e) {
      setState(() => _testResult = 'Connection failed: $e');
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(accountsProvider.notifier).add(_buildAccount(), _password.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _testResult = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add account' : 'Edit account')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(key: const Key('displayNameField'), controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name')),
          TextField(key: const Key('emailField'), controller: _email,
              decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 16),
          TextField(key: const Key('imapHostField'), controller: _imapHost,
              decoration: const InputDecoration(labelText: 'IMAP host')),
          TextField(key: const Key('imapPortField'), controller: _imapPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'IMAP port')),
          const SizedBox(height: 16),
          TextField(key: const Key('smtpHostField'), controller: _smtpHost,
              decoration: const InputDecoration(labelText: 'SMTP host')),
          TextField(key: const Key('smtpPortField'), controller: _smtpPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'SMTP port')),
          const SizedBox(height: 16),
          TextField(key: const Key('usernameField'), controller: _username,
              decoration: const InputDecoration(labelText: 'Username')),
          TextField(key: const Key('passwordField'), controller: _password, obscureText: true,
              decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _testing ? null : _testConnection,
            child: Text(_testing ? 'Testing...' : 'Test connection'),
          ),
          if (_testResult != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_testResult!),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isValid && !_saving ? _save : null,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
    );
  }
}
