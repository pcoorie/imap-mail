import 'package:equatable/equatable.dart';

class MailAttachment extends Equatable {
  const MailAttachment({
    this.id,
    required this.messageId,
    required this.filename,
    required this.mimeType,
    required this.size,
    this.localPath,
  });

  final int? id;
  final int messageId;
  final String filename;
  final String mimeType;
  final int size;
  final String? localPath;

  MailAttachment copyWith({
    int? id,
    int? messageId,
    String? filename,
    String? mimeType,
    int? size,
    String? localPath,
  }) {
    return MailAttachment(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      filename: filename ?? this.filename,
      mimeType: mimeType ?? this.mimeType,
      size: size ?? this.size,
      localPath: localPath ?? this.localPath,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'message_id': messageId,
      'filename': filename,
      'mime_type': mimeType,
      'size': size,
      'local_path': localPath,
    };
  }

  factory MailAttachment.fromMap(Map<String, Object?> map) {
    return MailAttachment(
      id: map['id'] as int?,
      messageId: map['message_id'] as int,
      filename: map['filename'] as String,
      mimeType: map['mime_type'] as String,
      size: map['size'] as int,
      localPath: map['local_path'] as String?,
    );
  }

  @override
  List<Object?> get props =>
      [id, messageId, filename, mimeType, size, localPath];
}
