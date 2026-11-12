import 'diagnostics_service.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_info.dart';
import 'storage_service.dart';

/// 聊天列表服务
/// 管理聊天列表状态、未读消息、置顶等
class ChatListService extends ChangeNotifier {
  Future<void> reconcileEntities(List<Map<String,dynamic>> roles, List<Map<String,dynamic>> groups) async {
    final all = [...roles, ...groups];
    final ids = all.map((r) => r['id']).toSet();
    _chatList.removeWhere((c) => !ids.contains(c.id));
    for (final row in all) {
      final id = row['id'] as String;
      final index = _chatList.indexWhere((c) => c.id == id);
      if (index >= 0) {
        _chatList[index] = _chatList[index].copyWith(name: row['name'] as String, avatarUrl: row['avatar_url'] as String?);
      } else {
        _chatList.add(ChatInfo(id: id, name: row['name'] as String, avatarUrl: row['avatar_url'] as String?,
          isGroup: row.containsKey('member_ids'), memberIds: (row['member_ids'] as List?)?.cast<String>()));
      }
    }
    await _saveChatList();
    notifyListeners();
  }
  static final ChatListService _instance = ChatListService._internal();
  factory ChatListService() => _instance;
  ChatListService._internal();

  static ChatListService get instance => _instance;

  final List<ChatInfo> _chatList = [];

  List<ChatInfo> get chatList {
    // 置顶的排在前面，然后按时间排序
    final sorted = List<ChatInfo>.from(_chatList);
    sorted.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.lastMessageTime.compareTo(a.lastMessageTime);
    });
    return sorted;
  }

  int get totalUnreadCount =>
      _chatList.fold(0, (sum, chat) => sum + chat.unreadCount);

  /// 初始化服务
  static Future<void> init() async {
    await _instance._loadChatList();
    DiagnosticsService.event('chat', 'chatlistservice_initialized_with');
  }

  /// 加载聊天列表
  Future<void> _loadChatList() async {
    _chatList.clear();
    final jsonList = StorageService.getJsonList('chat_list');
    if (jsonList != null) {
      _chatList.clear();
      for (final json in jsonList) {
        try {
          _chatList.add(ChatInfo.fromJson(json));
        } catch (e) {
          DiagnosticsService.event('chat', 'legacy_event', error: e);
        }
      }
    }
  }

  /// 保存聊天列表
  Future<void> _saveChatList() async {
    final jsonList = _chatList.map((c) => c.toJson()).toList();
    await StorageService.setJsonList('chat_list', jsonList);
  }

  /// 获取或创建聊天
  ChatInfo getOrCreateChat({
    required String id,
    required String name,
    String? avatarUrl,
    bool isGroup = false,
    List<String>? memberIds,
  }) {
    final existing = _chatList.where((c) => c.id == id).firstOrNull;
    if (existing != null) return existing;

    final newChat = ChatInfo(
      id: id,
      name: name,
      avatarUrl: avatarUrl,
      isGroup: isGroup,
      memberIds: memberIds,
    );
    _chatList.add(newChat);
    _saveChatList();
    notifyListeners();
    return newChat;
  }

  /// 更新聊天（新消息到达时）
  void updateChat({
    required String chatId,
    String? lastMessage,
    DateTime? lastMessageTime,
    bool incrementUnread = false,
    int unreadDelta = 0,
  }) {
    final index = _chatList.indexWhere((c) => c.id == chatId);
    if (index == -1) return;

    final chat = _chatList[index];
    _chatList[index] = chat.copyWith(
      lastMessage: lastMessage ?? chat.lastMessage,
      lastMessageTime: lastMessageTime ?? DateTime.now(),
      unreadCount: chat.unreadCount + unreadDelta + (incrementUnread ? 1 : 0),
    );
    _saveChatList();
    notifyListeners();
  }

  /// 清除未读数
  void clearUnread(String chatId) {
    final index = _chatList.indexWhere((c) => c.id == chatId);
    if (index == -1) return;

    final chat = _chatList[index];
    if (chat.unreadCount > 0) {
      _chatList[index] = chat.copyWith(unreadCount: 0);
      _saveChatList();
      notifyListeners();
    }
  }

  /// 标记为未读
  void markAsUnread(String chatId) {
    final index = _chatList.indexWhere((c) => c.id == chatId);
    if (index == -1) return;

    final chat = _chatList[index];
    _chatList[index] = chat.copyWith(
      unreadCount: chat.unreadCount == 0 ? 1 : chat.unreadCount,
    );
    _saveChatList();
    notifyListeners();
  }

  /// 增加未读数
  void incrementUnread(String chatId, {int count = 1}) {
    final index = _chatList.indexWhere((c) => c.id == chatId);
    if (index == -1) return;

    final chat = _chatList[index];
    _chatList[index] = chat.copyWith(unreadCount: chat.unreadCount + count);
    _saveChatList();
    notifyListeners();
  }

  /// 置顶/取消置顶
  void togglePin(String chatId) {
    final index = _chatList.indexWhere((c) => c.id == chatId);
    if (index == -1) return;

    final chat = _chatList[index];
    _chatList[index] = chat.copyWith(isPinned: !chat.isPinned);
    _saveChatList();
    notifyListeners();
  }

  /// 从列表删除聊天（不删除聊天记录）
  void removeFromList(String chatId) {
    _chatList.removeWhere((c) => c.id == chatId);
    _saveChatList();
    notifyListeners();
  }

  /// 删除聊天（包括聊天记录）
  Future<void> deleteChat(String chatId) async {
    _chatList.removeWhere((c) => c.id == chatId);
    await _saveChatList();
    notifyListeners();
  }

  /// 检查聊天是否存在
  bool hasChat(String chatId) {
    return _chatList.any((c) => c.id == chatId);
  }

  /// 获取聊天信息
  ChatInfo? getChat(String chatId) {
    return _chatList.where((c) => c.id == chatId).firstOrNull;
  }

  /// 刷新列表
  void refresh() {
    notifyListeners();
  }
}
