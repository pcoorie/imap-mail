import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/unified_message.dart';

void main() {
  test('bundles a message with the folder and account it came from', () {
    const account = MailAccount(
      id: 1,
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      imapPort: 993,
      imapSecurity: MailSecurity.ssl,
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      smtpSecurity: MailSecurity.ssl,
      username: 'me@example.com',
    );
    final folder = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
    final message = MailMessage(
      id: 100,
      folderId: 10,
      uid: 1,
      subject: 'Hello',
      from: 'a@example.com',
      to: 'me@example.com',
      date: DateTime.utc(2026, 8, 19),
      snippet: 'Hi',
    );

    final unified = UnifiedMessage(message: message, folder: folder, account: account);

    expect(unified.message, message);
    expect(unified.folder, folder);
    expect(unified.account, account);
  });
}
