import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailMessage extends Equatable {
  const MailMessage({
    this.id,
    required this.folderId,
    required this.uid,
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.snippet,
    this.bodyText,
    this.bodyHtml,
    this.isRead = false,
    this.isFlagged = false,
    this.isDownloaded = false,
    this.sendStatus = MailSendStatus.none,
  });

  final int? id;
  final int folderId;
  final int uid;
  final String subject;
  final String from;
  final String to;
  final DateTime date;
  final String snippet;
  final String? bodyText;
  final String? bodyHtml;
  final bool isRead;
  final bool isFlagged;
  final bool isDownloaded;
  final MailSendStatus sendStatus;

  MailMessage copyWith({
    int? id,
    int? folderId,
    int? uid,
    String? subject,
    String? from,
    String? to,
    DateTime? date,
    String? snippet,
    String? bodyText,
    String? bodyHtml,
    bool? isRead,
    bool? isFlagged,
    bool? isDownloaded,
    MailSendStatus? sendStatus,
  }) {
    return MailMessage(
      id: id ?? this.id,
      folderId: folderId ?? this.folderId,
      uid: uid ?? this.uid,
      subject: subject ?? this.subject,
      from: from ?? this.from,
      to: to ?? this.to,
      date: date ?? this.date,
      snippet: snippet ?? this.snippet,
      bodyText: bodyText ?? this.bodyText,
      bodyHtml: bodyHtml ?? this.bodyHtml,
      isRead: isRead ?? this.isRead,
      isFlagged: isFlagged ?? this.isFlagged,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      sendStatus: sendStatus ?? this.sendStatus,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'folder_id': folderId,
      'uid': uid,
      'subject': subject,
      'from_address': from,
      'to_address': to,
      'date': date.toUtc().millisecondsSinceEpoch,
      'snippet': snippet,
      'body_text': bodyText,
      'body_html': bodyHtml,
      'is_read': isRead ? 1 : 0,
      'is_flagged': isFlagged ? 1 : 0,
      'is_downloaded': isDownloaded ? 1 : 0,
      'send_status': sendStatus.name,
    };
  }

  factory MailMessage.fromMap(Map<String, Object?> map) {
    return MailMessage(
      id: map['id'] as int?,
      folderId: map['folder_id'] as int,
      uid: map['uid'] as int,
      subject: map['subject'] as String,
      from: map['from_address'] as String,
      to: map['to_address'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int, isUtc: true),
      snippet: map['snippet'] as String,
      bodyText: map['body_text'] as String?,
      bodyHtml: map['body_html'] as String?,
      isRead: (map['is_read'] as int) == 1,
      isFlagged: ((map['is_flagged'] as int?) ?? 0) == 1,
      isDownloaded: (map['is_downloaded'] as int) == 1,
      sendStatus: MailSendStatus.values.byName(map['send_status'] as String),
    );
  }

  @override
  List<Object?> get props => [
        id,
        folderId,
        uid,
        subject,
        from,
        to,
        date,
        snippet,
        bodyText,
        bodyHtml,
        isRead,
        isFlagged,
        isDownloaded,
        sendStatus,
      ];
}
