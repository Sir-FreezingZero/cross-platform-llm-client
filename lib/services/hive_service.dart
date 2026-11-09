import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';

class HiveService extends GetxService {
  late Box _sessionsBox;
  late Box _messagesBox;
  late Box _foldersBox;
  late Box _tasksBox;
  late Box _settingsBox;

  Box get sessionsBox => _sessionsBox;
  Box get messagesBox => _messagesBox;
  Box get tasksBox => _tasksBox;
  Box get settingsBox => _settingsBox;

  Future<HiveService> init() async {
    _sessionsBox = await Hive.openBox(AppConstants.chatSessionsBox);
    _messagesBox = await Hive.openBox(AppConstants.chatMessagesBox);
    _foldersBox = await Hive.openBox(AppConstants.chatFoldersBox);
    _tasksBox = await Hive.openBox(AppConstants.tasksBox);
    _settingsBox = await Hive.openBox(AppConstants.settingsBox);
    // Preserve current local-server settings and purge obsolete provider data.
    // Any new server_* setting must be added here or it is wiped on launch.
    const currentServerKeys = {
      AppConstants.keyServerApiKey,
      AppConstants.keyServerUseApiKey,
      AppConstants.keyServerAllowNetwork,
    };
    final obsoleteServerKeys = _settingsBox.keys.where((key) =>
        key is String &&
        key.startsWith('server_') &&
        !currentServerKeys.contains(key));
    await _settingsBox.deleteAll(obsoleteServerKeys);
    return this;
  }

  // ─── Settings helpers ───────────────────────────

  T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  // ─── Chat Sessions ─────────────────────────────

  List<Map<dynamic, dynamic>> getAllSessions() {
    return _sessionsBox.values
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveSession(String id, Map<String, dynamic> data) async {
    await _sessionsBox.put(id, data);
  }

  Future<void> deleteSession(String id) async {
    await _sessionsBox.delete(id);
    // Delete all messages for this session
    final keysToDelete = <dynamic>[];
    for (var key in _messagesBox.keys) {
      final msg = _messagesBox.get(key);
      if (msg is Map && msg['chatId'] == id) {
        keysToDelete.add(key);
      }
    }
    await _messagesBox.deleteAll(keysToDelete);
  }

  // ─── Chat Messages ─────────────────────────────

  List<Map<dynamic, dynamic>> getMessagesForChat(String chatId) {
    return _messagesBox.values
        .where((v) => v is Map && v['chatId'] == chatId)
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveMessage(String id, Map<String, dynamic> data) async {
    await _messagesBox.put(id, data);
  }

  /// Ids of the chats with a message containing [lowerQuery] (lower-cased).
  Set<String> chatIdsWithMessageMatching(String lowerQuery) {
    final ids = <String>{};
    for (final v in _messagesBox.values) {
      if (v is! Map) continue;
      final chatId = v['chatId'];
      final content = v['content'];
      if (chatId is String &&
          content is String &&
          !ids.contains(chatId) &&
          content.toLowerCase().contains(lowerQuery)) {
        ids.add(chatId);
      }
    }
    return ids;
  }

  /// Ids of the chats where an image generation has run.
  Set<String> chatIdsWithImageGeneration() {
    final ids = <String>{};
    for (final v in _messagesBox.values) {
      if (v is! Map || v['role'] != 'assistant') continue;
      final chatId = v['chatId'];
      final image = v['imageBase64'];
      if (chatId is String &&
          (v['imageGenDurationMs'] != null ||
              (image is String && image.isNotEmpty))) {
        ids.add(chatId);
      }
    }
    return ids;
  }

  // ─── Chat Folders ──────────────────────────────

  List<Map<dynamic, dynamic>> getAllFolders() {
    return _foldersBox.values
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveFolder(String id, Map<String, dynamic> data) async {
    await _foldersBox.put(id, data);
  }

  Future<void> deleteFolder(String id) async {
    await _foldersBox.delete(id);
  }

  // ─── Tasks ─────────────────────────────────────

  List<Map<dynamic, dynamic>> getAllTasks() {
    return _tasksBox.values.map((v) => Map<dynamic, dynamic>.from(v)).toList();
  }

  Future<void> saveTask(String id, Map<String, dynamic> data) async {
    await _tasksBox.put(id, data);
  }

  Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
  }
}
