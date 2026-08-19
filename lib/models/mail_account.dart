import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailAccount extends Equatable {
  const MailAccount({
    this.id,
    required this.displayName,
    required this.email,
    required this.imapHost,
    required this.imapPort,
    required this.imapSecurity,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSecurity,
    required this.username,
  });

  final int? id;
  final String displayName;
  final String email;
  final String imapHost;
  final int imapPort;
  final MailSecurity imapSecurity;
  final String smtpHost;
  final int smtpPort;
  final MailSecurity smtpSecurity;
  final String username;

  MailAccount copyWith({
    int? id,
    String? displayName,
    String? email,
    String? imapHost,
    int? imapPort,
    MailSecurity? imapSecurity,
    String? smtpHost,
    int? smtpPort,
    MailSecurity? smtpSecurity,
    String? username,
  }) {
    return MailAccount(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      imapSecurity: imapSecurity ?? this.imapSecurity,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpSecurity: smtpSecurity ?? this.smtpSecurity,
      username: username ?? this.username,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'display_name': displayName,
      'email': email,
      'imap_host': imapHost,
      'imap_port': imapPort,
      'imap_security': imapSecurity.name,
      'smtp_host': smtpHost,
      'smtp_port': smtpPort,
      'smtp_security': smtpSecurity.name,
      'username': username,
    };
  }

  factory MailAccount.fromMap(Map<String, Object?> map) {
    return MailAccount(
      id: map['id'] as int?,
      displayName: map['display_name'] as String,
      email: map['email'] as String,
      imapHost: map['imap_host'] as String,
      imapPort: map['imap_port'] as int,
      imapSecurity: MailSecurity.values.byName(map['imap_security'] as String),
      smtpHost: map['smtp_host'] as String,
      smtpPort: map['smtp_port'] as int,
      smtpSecurity: MailSecurity.values.byName(map['smtp_security'] as String),
      username: map['username'] as String,
    );
  }

  @override
  List<Object?> get props => [
        id,
        displayName,
        email,
        imapHost,
        imapPort,
        imapSecurity,
        smtpHost,
        smtpPort,
        smtpSecurity,
        username,
      ];
}
