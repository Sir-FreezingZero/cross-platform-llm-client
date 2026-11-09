class ChatFolder {
  final String id;
  final String name;
  final DateTime createdAt;

  ChatFolder({required this.id, required this.name, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatFolder.fromMap(Map<dynamic, dynamic> map) => ChatFolder(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
      );

  ChatFolder copyWith({String? name}) =>
      ChatFolder(id: id, name: name ?? this.name, createdAt: createdAt);
}
