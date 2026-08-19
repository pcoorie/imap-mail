import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/mail_attachment.dart';

void main() {
  group('MailAccount', () {
    test('round-trips through toMap/fromMap', () {
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
      final restored = MailAccount.fromMap(account.toMap());
      expect(restored, account);
    });

    test('copyWith overrides only given fields', () {
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
      final renamed = account.copyWith(displayName: 'Personal');
      expect(renamed.displayName, 'Personal');
      expect(renamed.email, account.email);
    });
  });

  group('MailFolder', () {
    test('round-trips through toMap/fromMap including isLocalOnly', () {
      const folder = MailFolder(
        id: 5,
        accountId: 1,
        name: 'Outbox',
        path: 'Outbox',
        type: MailFolderType.other,
        unreadCount: 0,
        isLocalOnly: true,
      );
      expect(MailFolder.fromMap(folder.toMap()), folder);
    });
  });

  group('MailMessage', () {
    test('round-trips through toMap/fromMap including date and flags', () {
      final message = MailMessage(
        id: 10,
        folderId: 5,
        uid: 42,
        subject: 'Hello',
        from: 'a@example.com',
        to: 'b@example.com',
        date: DateTime.utc(2026, 8, 19, 12, 0),
        snippet: 'Hi there',
        bodyText: 'Hi there, full body',
        bodyHtml: null,
        isRead: true,
        isDownloaded: true,
        sendStatus: MailSendStatus.none,
      );
      expect(MailMessage.fromMap(message.toMap()), message);
    });
  });

  group('MailAttachment', () {
    test('round-trips through toMap/fromMap', () {
      const attachment = MailAttachment(
        id: 3,
        messageId: 10,
        filename: 'report.pdf',
        mimeType: 'application/pdf',
        size: 1024,
        localPath: null,
      );
      expect(MailAttachment.fromMap(attachment.toMap()), attachment);
    });
  });
}
