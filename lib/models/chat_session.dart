class ChatSession {
  static const Object _unset = Object();

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastMessage;
  final bool pinned;
  final String? folderId;

  ChatSession({
    required this.id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastMessage,
    this.pinned = false,
    this.folderId,
  })  : title = title ?? 'New Chat',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastMessage': lastMessage,
        'pinned': pinned,
        'folderId': folderId,
      };

  factory ChatSession.fromMap(Map<dynamic, dynamic> map) => ChatSession(
        id: map['id'] ?? '',
        title: map['title'] ?? 'New Chat',
        createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(map['updatedAt'] ?? '') ?? DateTime.now(),
        lastMessage: map['lastMessage'],
        pinned: map['pinned'] == true,
        folderId: map['folderId'] as String?,
      );

  ChatSession copyWith({
    String? title,
    DateTime? updatedAt,
    String? lastMessage,
    bool? pinned,
    // Object? so that passing null can take a chat out of its folder.
    Object? folderId = _unset,
  }) =>
      ChatSession(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        lastMessage: lastMessage ?? this.lastMessage,
        pinned: pinned ?? this.pinned,
        folderId:
            identical(folderId, _unset) ? this.folderId : folderId as String?,
      );
}
