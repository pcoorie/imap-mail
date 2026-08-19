import 'package:equatable/equatable.dart';
import 'enums.dart';

class MailFolder extends Equatable {
  const MailFolder({
    this.id,
    required this.accountId,
    required this.name,
    required this.path,
    required this.type,
    this.unreadCount = 0,
    this.isLocalOnly = false,
  });

  final int? id;
  final int accountId;
  final String name;
  final String path;
  final MailFolderType type;
  final int unreadCount;
  final bool isLocalOnly;

  MailFolder copyWith({
    int? id,
    int? accountId,
    String? name,
    String? path,
    MailFolderType? type,
    int? unreadCount,
    bool? isLocalOnly,
  }) {
    return MailFolder(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      path: path ?? this.path,
      type: type ?? this.type,
      unreadCount: unreadCount ?? this.unreadCount,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'account_id': accountId,
      'name': name,
      'path': path,
      'type': type.name,
      'unread_count': unreadCount,
      'is_local_only': isLocalOnly ? 1 : 0,
    };
  }

  factory MailFolder.fromMap(Map<String, Object?> map) {
    return MailFolder(
      id: map['id'] as int?,
      accountId: map['account_id'] as int,
      name: map['name'] as String,
      path: map['path'] as String,
      type: MailFolderType.values.byName(map['type'] as String),
      unreadCount: map['unread_count'] as int,
      isLocalOnly: (map['is_local_only'] as int) == 1,
    );
  }

  @override
  List<Object?> get props =>
      [id, accountId, name, path, type, unreadCount, isLocalOnly];
}
