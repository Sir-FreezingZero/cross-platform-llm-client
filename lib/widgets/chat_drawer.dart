import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../models/chat_folder.dart';
import '../models/chat_session.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';

/// Two-bar "sidebar" glyph — the long bar over a short one reads as a list
/// rather than the generic hamburger.
class SidebarGlyph extends StatelessWidget {
  final Color color;
  const SidebarGlyph({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    Widget bar(double w) => Container(
          width: w,
          height: 2,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(1)),
        );
    return SizedBox(
      width: 22,
      height: 22,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [bar(18), const SizedBox(height: 5), bar(11)],
      ),
    );
  }
}

TextStyle _bodyStyle(Color color) =>
    GoogleFonts.inter(fontSize: 15, letterSpacing: -0.15, color: color);

/// How the chat list is ordered. Pinned chats always stay on top.
enum _ChatSort {
  recent('Recent activity', Icons.schedule_rounded),
  newest('Newest first', Icons.arrow_downward_rounded),
  oldest('Oldest first', Icons.arrow_upward_rounded),
  alphabetical('Name (A–Z)', Icons.sort_by_alpha_rounded);

  final String label;
  final IconData icon;
  const _ChatSort(this.label, this.icon);

  int compareChats(ChatSession a, ChatSession b) => switch (this) {
        recent => b.updatedAt.compareTo(a.updatedAt),
        newest => b.createdAt.compareTo(a.createdAt),
        oldest => a.createdAt.compareTo(b.createdAt),
        alphabetical => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      };

  int compareFolders(
      ChatFolder a, ChatFolder b, Map<String, DateTime> lastActivity) {
    return switch (this) {
      recent => (lastActivity[b.id] ?? b.createdAt)
          .compareTo(lastActivity[a.id] ?? a.createdAt),
      newest => b.createdAt.compareTo(a.createdAt),
      oldest => a.createdAt.compareTo(b.createdAt),
      alphabetical => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    };
  }
}

sealed class _ListRow {
  /// Approximate height, used to bring the open chat into view.
  double get extent;
}

/// One folder inside the shared folders bubble.
class _FolderSection {
  static const headerExtent = 44.0;
  static const rowExtent = 42.0;

  final ChatFolder folder;
  final bool expanded;
  final List<ChatSession> chats;
  _FolderSection(this.folder, this.expanded, this.chats);

  double get extent {
    if (!expanded) return headerExtent;
    return headerExtent + (chats.isEmpty ? 28 : chats.length * rowExtent) + 4;
  }
}

/// The single bubble that holds every folder and its open chats.
class _FoldersEntry extends _ListRow {
  final List<_FolderSection> sections;
  _FoldersEntry(this.sections);

  @override
  double get extent =>
      12 + sections.fold<double>(0, (sum, section) => sum + section.extent);

  /// Distance from the bubble's top to [chatId], if it's in an open folder.
  double? offsetOf(String chatId) {
    var top = 8.0;
    for (final section in sections) {
      final index = section.chats.indexWhere((c) => c.id == chatId);
      if (section.expanded && index >= 0) {
        return top +
            _FolderSection.headerExtent +
            index * _FolderSection.rowExtent;
      }
      top += section.extent;
    }
    return null;
  }
}

class _ChatEntry extends _ListRow {
  final ChatSession session;
  _ChatEntry(this.session);
  @override
  double get extent => 40;
}

enum _ChatAction { pin, rename, addToFolder, removeFromFolder, delete }

enum _FolderAction { rename, delete }

class _MenuAction<T> {
  final T value;
  final String label;
  final IconData? icon;
  final bool checked;
  final bool destructive;
  const _MenuAction(this.value, this.label,
      {this.icon, this.checked = false, this.destructive = false});
}

/// Pop-up menu directly below [anchor].
Future<T?> _showAnchoredMenu<T>(
    BuildContext anchor, List<_MenuAction<T>> actions) {
  const menuWidth = 216.0;
  const edge = 8.0;
  final t = AppTokens.of(anchor);
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final anchorTop = box.localToGlobal(Offset.zero, ancestor: overlay);
  final anchorBottom = anchorTop.dy + box.size.height;
  final insets = MediaQuery.paddingOf(anchor);
  final menuHeight = actions.length * 44.0 + (actions.length - 1) * 0.5;
  final screen = overlay.size;

  // Below the row when it fits, otherwise above it.
  var top = anchorBottom + 4;
  if (top + menuHeight > screen.height - insets.bottom - edge) {
    top = anchorTop.dy - menuHeight - 4;
  }
  top = top < insets.top + edge ? insets.top + edge : top;
  final maxLeft = screen.width - menuWidth - edge;
  final left = anchorTop.dx < edge
      ? edge
      : (anchorTop.dx > maxLeft ? maxLeft : anchorTop.dx);

  return showGeneralDialog<T>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.12),
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (ctx, _, __) => Stack(children: [
      Positioned(
        left: left,
        top: top,
        width: menuWidth,
        child: Material(
          color: Colors.transparent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.5 : 0.12),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: AppGroup(radius: 22, dividerIndent: 0, children: [
              for (final a in actions)
                AppRow(
                  icon: a.icon,
                  title: a.label,
                  selected: a.checked,
                  destructive: a.destructive,
                  onTap: () => Navigator.pop(ctx, a.value),
                ),
            ]),
          ),
        ),
      ),
    ]),
  );
}

/// Conversation sidebar: a floating card with search, new chat, folders, and
/// pinned, sortable chats.
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({super.key});

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  static const _rowIndent = 12.0;
  static const _newFolderChoice = '\u0000new-folder';

  late final TextEditingController _search;
  final _scroll = ScrollController();
  Timer? _debounce;

  /// Ids matching the search; null when not searching.
  Set<String>? _matches;
  late _ChatSort _sort;
  late final Set<String> _imageChatIds;
  List<_ListRow> _rows = const [];

  ChatController get _chat => Get.find<ChatController>();
  HiveService get _hive => Get.find<HiveService>();
  HomeController get _home => Get.find<HomeController>();

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: _chat.drawerQuery);
    final query = _chat.drawerQuery.trim();
    if (query.isNotEmpty) _matches = _chat.searchChatIds(query);

    _imageChatIds = _hive.chatIdsWithImageGeneration();

    final saved = _hive.getSetting<String>(AppConstants.keyChatListSort);
    _sort = _ChatSort.values.asNameMap()[saved] ?? _ChatSort.recent;

    // The folder holding the open chat opens with it.
    final currentFolder = _chat.sessions
        .firstWhereOrNull((s) => s.id == _chat.currentSessionId.value)
        ?.folderId;
    if (currentFolder != null &&
        !_chat.expandedFolderIds.contains(currentFolder)) {
      _chat.expandedFolderIds.add(currentFolder);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _revealCurrent() {
    if (!mounted || !_scroll.hasClients) return;
    final current = _chat.currentSessionId.value;
    var top = 0.0;
    double? found;
    for (final row in _rows) {
      if (row is _ChatEntry && row.session.id == current) {
        found = top;
        break;
      }
      if (row is _FoldersEntry) {
        final inner = row.offsetOf(current);
        if (inner != null) {
          found = top + inner;
          break;
        }
      }
      top += row.extent;
    }
    if (found == null) return;
    top = found;
    const height = 40.0;
    final p = _scroll.position;
    if (top >= p.pixels && top + height <= p.pixels + p.viewportDimension) {
      return;
    }
    _scroll.jumpTo(
        (top - (p.viewportDimension - height) / 2).clamp(0.0, p.maxScrollExtent));
  }

  void _scrollToTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _onQueryChanged(String value) {
    _chat.drawerQuery = value;
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() => _matches = null);
      _scrollToTop();
      return;
    }
    setState(() {}); // Show the clear button right away.
    // A short pause after typing avoids a scan per key.
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _matches = _chat.searchChatIds(query));
      _scrollToTop();
    });
  }

  void _clearQuery() {
    _search.clear();
    _onQueryChanged('');
  }

  void _showChatTab() {
    _home.changeTab(0);
    _home.closeSidebar();
  }

  void _newChat() {
    _clearQuery();
    _chat.startChatFromSidebar();
    _showChatTab();
  }

  void _open(ChatSession s) {
    Haptics.selectionClick();
    if (_chat.currentSessionId.value != s.id) _chat.openChat(s.id);
    _showChatTab();
  }

  ModelController get _models => Get.find<ModelController>();

  void _newDefaultChat() {
    if (!_startWithDefaultModel(AppConstants.keyDefaultChatModel)) _newChat();
  }

  /// The saved default for [key], or null for "currently loaded model"
  /// (also when the saved model has since been deleted).
  String? _defaultModel(String key) {
    final saved = _hive.getSetting<String>(key);
    if (saved == null || saved.isEmpty) return null;
    return _models.downloadedFiles.contains(saved) ? saved : null;
  }

  /// Starts a chat with the default model for [key], loading it if needed.
  /// Returns false when no default applies, leaving the normal flow to run.
  bool _startWithDefaultModel(String key) {
    final model = _defaultModel(key);
    if (model == null ||
        Get.find<SettingsController>().inferenceMode.value != 'local') {
      return false;
    }
    _newChat();
    final inference = Get.find<InferenceService>();
    final image = Get.find<LocalImageService>();
    final loaded = (inference.isModelLoaded.value &&
            inference.loadedModelName.value == model) ||
        (image.isModelLoaded.value && image.loadedModelName.value == model);
    if (!loaded &&
        !inference.isLoadingModel.value &&
        !image.isLoadingModel.value) {
      unawaited(_models.loadModel(model));
    }
    return true;
  }

  String _loadedModelSummary() {
    final inference = Get.find<InferenceService>();
    final image = Get.find<LocalImageService>();
    if (inference.isModelLoaded.value) return inference.loadedModelName.value;
    if (image.isModelLoaded.value) return image.loadedModelName.value;
    return 'No model loaded';
  }

  Future<void> _pickDefaultModel(
      {required String key, required bool image}) async {
    Haptics.selectionClick();
    // Read the models folder now so a recent download is always listed.
    await _models.refreshDownloaded();
    if (!mounted) return;
    final current = _defaultModel(key);
    final muted = AppTokens.of(context).muted;
    final models = _models.displayedModels
        .where((m) =>
            _models.isDownloaded(m.filename) &&
            _models.isImageModel(m) == image)
        .toList();
    String fileOf(AiModel m) => m.filename.toLowerCase().endsWith('.zip')
        ? m.filename.substring(0, m.filename.length - 4)
        : m.filename;

    // Empty string means "currently loaded model"; null means dismissed.
    final picked = await showAppSheet<String>(
      context,
      title: image ? 'Default image model' : 'Default chat model',
      subtitle: '${image ? 'Loaded when you tap New Image Gen' : 'Loaded when you tap New Chat'}'
          ', if it isn\'t already. Now loaded: ${_loadedModelSummary()}',
      builder: (ctx) => AppGroup(radius: 22, dividerIndent: 0, children: [
        AppRow(
          icon: Icons.memory_rounded,
          title: 'Currently loaded model',
          selected: current == null,
          titleColor: current == null ? null : muted,
          onTap: () => Navigator.pop(ctx, ''),
        ),
        for (final m in models)
          AppRow(
            icon: image ? Icons.image_outlined : Icons.chat_bubble_outline_rounded,
            title: m.name,
            selected: fileOf(m) == current,
            titleColor: fileOf(m) == current ? null : muted,
            onTap: () => Navigator.pop(ctx, fileOf(m)),
          ),
      ]),
    );
    if (picked != null) _hive.setSetting(key, picked);
  }

  /// Image generation runs whenever an image model is loaded, so this is a
  /// new chat when one is ready and the image model list when it isn't.
  void _newImageGen() {
    if (_startWithDefaultModel(AppConstants.keyDefaultImageModel)) return;
    final ready = Get.find<SettingsController>().inferenceMode.value == 'local' &&
        Get.find<LocalImageService>().isModelLoaded.value;
    if (ready) {
      _newChat();
      return;
    }
    Get.find<ModelController>().localFilter.value = 'image';
    _home.changeTab(1);
    _home.closeSidebar();
    showToast('Load an image model',
        'Image generation needs an image model loaded first.');
  }

  void _toggleFolder(ChatFolder folder) {
    Haptics.selectionClick();
    if (!_chat.expandedFolderIds.remove(folder.id)) {
      _chat.expandedFolderIds.add(folder.id);
    }
  }

  Future<String?> _askName({
    required String title,
    required String confirm,
    String initial = '',
    String? hint,
  }) {
    return showAppSheet<String>(
      context,
      title: title,
      builder: (_) =>
          _NameSheet(confirm: confirm, initial: initial, hint: hint),
    );
  }

  Future<void> _newFolder({String? moveSessionId}) async {
    final name = await _askName(
        title: 'New folder', confirm: 'Create', hint: 'Folder name');
    if (name != null) _chat.createFolder(name, moveSessionId: moveSessionId);
  }

  Future<void> _pickSort(BuildContext anchor) async {
    final picked = await _showAnchoredMenu<_ChatSort>(anchor, [
      for (final option in _ChatSort.values)
        _MenuAction(option, option.label,
            icon: option.icon, checked: option == _sort),
    ]);
    if (picked == null || !mounted) return;
    setState(() => _sort = picked);
    _hive.setSetting(AppConstants.keyChatListSort, picked.name);
    _scrollToTop();
  }

  Future<void> _chatMenu(BuildContext anchor, ChatSession s) async {
    Haptics.mediumImpact();
    final action = await _showAnchoredMenu<_ChatAction>(anchor, [
      _MenuAction(_ChatAction.pin, s.pinned ? 'Unpin' : 'Pin',
          icon: Icons.push_pin_outlined),
      const _MenuAction(_ChatAction.rename, 'Rename',
          icon: Icons.edit_outlined),
      const _MenuAction(_ChatAction.addToFolder, 'Add to folder',
          icon: Icons.folder_outlined),
      if (s.folderId != null)
        const _MenuAction(_ChatAction.removeFromFolder, 'Remove from folder',
            icon: Icons.folder_off_outlined),
      const _MenuAction(_ChatAction.delete, 'Delete',
          icon: Icons.delete_outline_rounded, destructive: true),
    ]);
    if (!mounted) return;
    switch (action) {
      case _ChatAction.pin:
        _chat.setChatPinned(s.id, !s.pinned);
      case _ChatAction.rename:
        final name = await _askName(
            title: 'Rename Conversation', confirm: 'Rename', initial: s.title);
        if (name != null) _chat.renameChat(s.id, name);
      case _ChatAction.addToFolder:
        await _addToFolder(s);
      case _ChatAction.removeFromFolder:
        _chat.moveChatToFolder(s.id, null);
      case _ChatAction.delete:
        _chat.deleteChat(s.id);
      case null:
        break;
    }
  }

  Future<void> _addToFolder(ChatSession s) async {
    final choice = await showAppSheet<String>(
      context,
      title: 'Add to folder',
      builder: (ctx) => AppGroup(children: [
        AppRow(
          icon: Icons.create_new_folder_outlined,
          title: 'New folder',
          onTap: () => Navigator.pop(ctx, _newFolderChoice),
        ),
        for (final f in _chat.folders)
          AppRow(
            icon: Icons.folder_outlined,
            title: f.name,
            selected: f.id == s.folderId,
            onTap: () => Navigator.pop(ctx, f.id),
          ),
      ]),
    );
    if (choice == null || !mounted) return;
    if (choice == _newFolderChoice) {
      await _newFolder(moveSessionId: s.id);
      return;
    }
    _chat.moveChatToFolder(s.id, choice);
    if (!_chat.expandedFolderIds.contains(choice)) {
      _chat.expandedFolderIds.add(choice);
    }
  }

  Future<void> _folderMenu(BuildContext anchor, ChatFolder folder) async {
    Haptics.mediumImpact();
    final action = await _showAnchoredMenu<_FolderAction>(anchor, const [
      _MenuAction(_FolderAction.rename, 'Rename folder',
          icon: Icons.edit_outlined),
      _MenuAction(_FolderAction.delete, 'Delete folder',
          icon: Icons.delete_outline_rounded, destructive: true),
    ]);
    if (!mounted) return;
    switch (action) {
      case _FolderAction.rename:
        final name = await _askName(
            title: 'Rename folder', confirm: 'Rename', initial: folder.name);
        if (name != null) _chat.renameFolder(folder.id, name);
      case _FolderAction.delete:
        _chat.deleteFolder(folder.id);
      case null:
        break;
    }
  }

  int _compareChats(ChatSession a, ChatSession b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final bySort = _sort.compareChats(a, b);
    if (bySort != 0) return bySort;
    final byUpdated = b.updatedAt.compareTo(a.updatedAt);
    return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
  }

  /// While searching, a flat list of matches; otherwise the chats outside any
  /// folder, then the folders, each followed by its chats when open.
  List<_ListRow> _buildRows(List<ChatSession> visible, List<ChatFolder> folders,
      Set<String> expanded) {
    final matches = _matches;
    if (matches != null) {
      return [
        for (final s in visible.where((s) => matches.contains(s.id)).toList()
          ..sort(_compareChats))
          _ChatEntry(s),
      ];
    }

    final folderIds = folders.map((f) => f.id).toSet();
    final byFolder = <String, List<ChatSession>>{};
    final loose = <ChatSession>[];
    final lastActivity = <String, DateTime>{};
    for (final s in visible) {
      final id = s.folderId;
      if (id == null || !folderIds.contains(id)) {
        loose.add(s);
        continue;
      }
      byFolder.putIfAbsent(id, () => []).add(s);
      final last = lastActivity[id];
      if (last == null || s.updatedAt.isAfter(last)) {
        lastActivity[id] = s.updatedAt;
      }
    }

    final sortedFolders = folders.toList()
      ..sort((a, b) {
        final bySort = _sort.compareFolders(a, b, lastActivity);
        return bySort != 0 ? bySort : a.id.compareTo(b.id);
      });

    loose.sort(_compareChats);
    final rows = <_ListRow>[for (final s in loose) _ChatEntry(s)];
    if (sortedFolders.isNotEmpty) {
      rows.add(_FoldersEntry([
        for (final folder in sortedFolders)
          _FolderSection(
            folder,
            expanded.contains(folder.id),
            (byFolder[folder.id] ?? <ChatSession>[])..sort(_compareChats),
          ),
      ]));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final width = (MediaQuery.of(context).size.width - 56).clamp(0.0, 300.0);

    return Drawer(
      width: width,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.only(left: 6, top: 6, bottom: 6),
          child: Material(
            color: t.bg,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(color: t.outline, width: 0.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(t),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  // Radius 22 = icon radius 16 + the row's 6 inset (concentric).
                  child: AppGroup(radius: 22, dividerIndent: 0, children: [
                    AppRow(
                      icon: Icons.edit_note_rounded,
                      title: 'New Chat',
                      onTap: _newDefaultChat,
                      trailing: _DefaultModelButton(
                        tooltip: 'Default chat model',
                        onTap: () => _pickDefaultModel(
                            key: AppConstants.keyDefaultChatModel,
                            image: false),
                      ),
                    ),
                    AppRow(
                      icon: Icons.image_outlined,
                      title: 'New Image Gen',
                      onTap: _newImageGen,
                      trailing: _DefaultModelButton(
                        tooltip: 'Default image model',
                        onTap: () => _pickDefaultModel(
                            key: AppConstants.keyDefaultImageModel,
                            image: true),
                      ),
                    ),
                  ]),
                ),
                _buildSearch(t),
                _buildChatsHeader(t),
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
                  child: Divider(height: 1.5, thickness: 1.5, color: t.outline),
                ),
                Expanded(child: _buildList(t)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppTokens t) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 12),
        child: Row(children: [
          Expanded(
            child: Text('Conversations',
                style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    color: t.text)),
          ),
        ]),
      ),
    );
  }

  Widget _buildSearch(AppTokens t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
            color: t.fill, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.search_rounded, size: 18, color: t.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: _onQueryChanged,
              style: _bodyStyle(t.text),
              cursorColor: t.accent,
              textAlignVertical: TextAlignVertical.center,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search chats',
                hintStyle: _bodyStyle(t.muted),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_search.text.isNotEmpty)
            _SmallIconButton(
              icon: Icons.cancel_rounded,
              box: 32,
              iconSize: 17,
              color: t.muted,
              tooltip: 'Clear',
              onPressed: _clearQuery,
            ),
        ]),
      ),
    );
  }

  Widget _buildChatsHeader(AppTokens t) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 12, top: 12, bottom: 4),
      child: Row(children: [
        Expanded(
          child: Text('Chats', style: t.label),
        ),
        _SmallIconButton(
          icon: Icons.create_new_folder_outlined,
          box: 36,
          iconSize: 20,
          color: t.muted,
          tooltip: 'New folder',
          onPressed: _newFolder,
        ),
        Builder(
          builder: (anchor) => _SmallIconButton(
            icon: Icons.sort_rounded,
            box: 36,
            iconSize: 20,
            color: t.muted,
            tooltip: 'Sort chats',
            onPressed: () => _pickSort(anchor),
          ),
        ),
      ]),
    );
  }

  Widget _buildList(AppTokens t) {
    return Obx(() {
      final current = _chat.currentSessionId.value;
      // Hide blank "New Chat" shells, except the one that's open.
      final visible = _chat.sessions
          .where((s) =>
              (s.lastMessage ?? '').trim().isNotEmpty || s.id == current)
          .toList();
      final rows = _buildRows(
          visible, _chat.folders.toList(), _chat.expandedFolderIds.toSet());
      _rows = rows;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_matches != null && rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Text('No matching chats', style: _bodyStyle(t.text)),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              // Keeps the last rows reachable above the soft keyboard.
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom),
              itemCount: rows.length,
              itemBuilder: (_, i) => switch (rows[i]) {
                _FoldersEntry(:final sections) =>
                    _buildFolders(t, sections, current),
                _ChatEntry(:final session) => _SessionRow(
                    key: ValueKey(session.id),
                    session: session,
                    active: session.id == current,
                    tokens: t,
                    indent: _rowIndent,
                    isImageChat: _imageChatIds.contains(session.id),
                    onTap: () => _open(session),
                    onLongPress: (anchor) => _chatMenu(anchor, session),
                  ),
              },
            ),
          ),
        ],
      );
    });
  }

  Widget _buildFolders(
      AppTokens t, List<_FolderSection> sections, String current) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      // Radius 22 = icon radius 16 + the row's 6 inset (concentric).
      child: AppGroup(radius: 22, dividerIndent: 0, children: [
        for (final section in sections)
          Column(
            key: ValueKey('folder:${section.folder.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FolderRow(
                folder: section.folder,
                expanded: section.expanded,
                tokens: t,
                onToggle: () => _toggleFolder(section.folder),
                onLongPress: (anchor) => _folderMenu(anchor, section.folder),
              ),
              if (section.expanded) ...[
                if (section.chats.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.only(left: 50, top: 6, bottom: 6),
                    child: Text('No chats in this folder', style: t.small),
                  ),
                for (final chat in section.chats)
                  _SessionRow(
                    key: ValueKey(chat.id),
                    session: chat,
                    active: chat.id == current,
                    tokens: t,
                    indent: 38,
                    endInset: 6,
                    isImageChat: _imageChatIds.contains(chat.id),
                    onTap: () => _open(chat),
                    onLongPress: (anchor) => _chatMenu(anchor, chat),
                  ),
                const SizedBox(height: 4),
              ],
            ],
          ),
      ]),
    );
  }
}

class _DefaultModelButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;
  const _DefaultModelButton({required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          highlightColor: t.surfacePressed,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 32,
            child: Icon(Icons.tune_rounded,
                size: 17, color: t.text.withValues(alpha: 0.8)),
          ),
        ),
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  final IconData icon;
  final double box;
  final double iconSize;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _SmallIconButton({
    required this.icon,
    required this.box,
    required this.iconSize,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: box,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: color),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final ChatSession session;
  final bool active;
  final AppTokens tokens;
  final double indent;
  final double endInset;
  final bool isImageChat;
  final VoidCallback onTap;
  final ValueChanged<BuildContext> onLongPress;

  const _SessionRow({
    super.key,
    required this.session,
    required this.active,
    required this.tokens,
    required this.indent,
    this.endInset = 12,
    required this.isImageChat,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endInset, top: 1, bottom: 1),
      child: Material(
        color: active
            ? (t.isDark ? const Color(0xFF2C2C2F) : t.fill)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          highlightColor: t.surfacePressed,
          onLongPress: () => onLongPress(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                child: Text(session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: active
                        ? t.bodyStrong
                        : _bodyStyle(t.text)),
              ),
              if (session.pinned) ...[
                const SizedBox(width: 6),
                Icon(Icons.push_pin_rounded,
                    size: 14, color: t.muted, semanticLabel: 'Pinned'),
              ],
              if (isImageChat) ...[
                const SizedBox(width: 6),
                Icon(Icons.image_outlined,
                    size: 15, color: t.muted, semanticLabel: 'Image chat'),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final ChatFolder folder;
  final bool expanded;
  final AppTokens tokens;
  final VoidCallback onToggle;
  final ValueChanged<BuildContext> onLongPress;

  const _FolderRow({
    required this.folder,
    required this.expanded,
    required this.tokens,
    required this.onToggle,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        onLongPress: () => onLongPress(context),
        splashFactory: NoSplash.splashFactory,
        highlightColor: t.surfacePressed,
        child: Padding(
          padding: const EdgeInsets.only(left: 6, right: 10, top: 6, bottom: 6),
          child: Row(children: [
            IconBadge(
                expanded ? Icons.folder_open_outlined : Icons.folder_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body),
            ),
            Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 20,
                color: t.muted),
          ]),
        ),
      ),
    );
  }
}

/// Sheet body that asks for a name; pops the trimmed text.
class _NameSheet extends StatefulWidget {
  final String confirm;
  final String initial;
  final String? hint;

  const _NameSheet({required this.confirm, required this.initial, this.hint});

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _text.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _text,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
          decoration: appInputDecoration(context, hint: widget.hint ?? ''),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: widget.confirm,
          onPressed: name.isEmpty ? null : () => Navigator.pop(context, name),
        ),
      ],
    );
  }
}
