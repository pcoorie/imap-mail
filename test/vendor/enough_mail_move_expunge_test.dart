// Regression test for a bug in the vendored `enough_mail` copy
// (third_party/enough_mail), several layers below any interface Cobalt's
// own repository/transport tests mock out — a test against
// `MailTransport`/`MailRepository` never exercises the real code path this
// covers, so it wouldn't have caught the bug. See
// docs/superpowers/specs/2026-08-27-imap-move-expunge-fix-design.md.
//
// The bug: when a server doesn't advertise the IMAP MOVE capability
// (RFC 6851), `MailClient.moveMessages()` falls back to COPY + STORE
// +FLAGS (\Deleted) on the original — but never expunges it. The message
// stays fully present in the source mailbox, visible to every other IMAP
// client, forever. This test runs a real (loopback, in-process) IMAP
// conversation against a scripted fake server that omits MOVE, and asserts
// that an EXPUNGE (or UID EXPUNGE) command is sent after the STORE.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MailClient.moveMessages against a MOVE-incapable server', () {
    late _FakeImapServer server;
    late MailClient client;

    setUp(() async {
      server = await _FakeImapServer.bind();
      final account = MailAccount.fromManualSettings(
        name: 'test',
        email: 'test@example.com',
        incomingHost: '127.0.0.1',
        outgoingHost: '127.0.0.1',
        password: 'password',
        userName: 'test@example.com',
        incomingPort: server.port,
        outgoingPort: server.port,
        incomingSocketType: SocketType.plain,
        outgoingSocketType: SocketType.plain,
      );
      client = MailClient(account, isLogEnabled: true, logName: 'fake-imap-test');
    });

    tearDown(() async {
      await client.disconnect();
      await server.close();
    });

    test('expunges the flagged original after COPY + STORE \\Deleted',
        () async {
      await client.connect();
      final mailboxes = await client.listMailboxes();
      final inbox = mailboxes.firstWhere((box) => box.path == 'INBOX');
      final archive = mailboxes.firstWhere((box) => box.path == 'Archive');
      await client.selectMailbox(inbox);

      final sequence = MessageSequence.fromId(1, isUid: true);
      await client.moveMessages(sequence, archive);

      final commands = server.receivedCommands
          .map((line) => line.split(' ').skip(1).join(' ').trim().toUpperCase())
          .toList();

      final storeIndex = commands.indexWhere((c) => c.contains('STORE'));
      final expungeIndex = commands.indexWhere((c) => c.contains('EXPUNGE'));

      expect(
        storeIndex,
        greaterThanOrEqualTo(0),
        reason: 'expected a STORE command flagging the message \\Deleted:\n'
            '${server.receivedCommands.join('\n')}',
      );
      expect(
        expungeIndex,
        greaterThanOrEqualTo(0),
        reason: 'the server-lacks-MOVE fallback never finished the move '
            'with an EXPUNGE/UID EXPUNGE — this is the bug: without it the '
            'original stays in the source mailbox forever, so other IMAP '
            'clients never see it as moved. Commands sent:\n'
            '${server.receivedCommands.join('\n')}',
      );
      expect(
        expungeIndex,
        greaterThan(storeIndex),
        reason: 'EXPUNGE must come after the STORE that flagged the message',
      );
    });
  });
}

/// A minimal scripted IMAP server: accepts one connection, replies to each
/// command by matching on its verb, and records every command line it
/// receives (tag included) for the test to assert against. Advertises
/// `LOGIN UIDPLUS` but deliberately not `MOVE`, forcing the client into the
/// COPY + STORE fallback this test targets.
class _FakeImapServer {
  _FakeImapServer._(this._serverSocket, this._clientSocketFuture);

  static Future<_FakeImapServer> bind() async {
    final serverSocket =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientSocketFuture = serverSocket.first;
    final server = _FakeImapServer._(serverSocket, clientSocketFuture);
    unawaited(server._serve());
    return server;
  }

  final ServerSocket _serverSocket;
  final Future<Socket> _clientSocketFuture;
  final List<String> receivedCommands = [];
  StreamSubscription<String>? _subscription;
  Socket? _clientSocket;

  int get port => _serverSocket.port;

  Future<void> _serve() async {
    final socket = await _clientSocketFuture;
    _clientSocket = socket;
    _writeLine('* OK IMAP4rev1 Service Ready');
    _subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
  }

  void _writeLine(String line) {
    _clientSocket?.write('$line\r\n');
  }

  void _onLine(String line) {
    receivedCommands.add(line);
    final tag = line.split(' ').first;
    final upper = line.toUpperCase();

    if (upper.contains(' LOGIN ')) {
      _writeLine('$tag OK [CAPABILITY IMAP4rev1 LOGIN UIDPLUS] '
          'LOGIN completed');
    } else if (upper.contains(' LIST ')) {
      _writeLine('* LIST (\\HasNoChildren) "/" "INBOX"');
      _writeLine('* LIST (\\HasNoChildren) "/" "Archive"');
      _writeLine('$tag OK LIST completed');
    } else if (upper.contains(' SELECT ')) {
      _writeLine('* 3 EXISTS');
      _writeLine('* 0 RECENT');
      _writeLine('* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)');
      _writeLine('* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted '
          '\\Seen \\Draft \\*)] Flags permitted');
      _writeLine('* OK [UIDVALIDITY 1] UIDs valid');
      _writeLine('* OK [UIDNEXT 4] Predicted next UID');
      _writeLine('$tag OK [READ-WRITE] SELECT completed');
    } else if (upper.contains('COPY')) {
      _writeLine('$tag OK [COPYUID 1 1 100] COPY completed');
    } else if (upper.contains('STORE')) {
      _writeLine('* 1 FETCH (FLAGS (\\Deleted))');
      _writeLine('$tag OK STORE completed');
    } else if (upper.contains('EXPUNGE')) {
      _writeLine('* 1 EXPUNGE');
      _writeLine('$tag OK EXPUNGE completed');
    } else if (upper.contains('LOGOUT')) {
      _writeLine('* BYE logging out');
      _writeLine('$tag OK LOGOUT completed');
    } else {
      _writeLine('$tag BAD unrecognized command in fake server: $line');
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _clientSocket?.close();
    await _serverSocket.close();
  }
}
