import '../services/session_service.dart';
import '../services/notification_service.dart';
import '../services/backend_sync_service.dart';
import '../services/diagnostics_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../services/storage_service.dart';
import 'package:flutter/foundation.dart';
import '../services/backend_http.dart' as http;
import '../models/message.dart';
import '../models/chat_context.dart';
import '../services/api_service.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../services/chat_list_service.dart';
import 'message_store.dart';
import 'memory_manager.dart';

class SendRecoveryRequired implements Exception {
  @override
  String toString() => '上次请求已结束，但供应商结果未确认；请确认重新发送，可能重复计费';
}

class SendRecoveryCancelled implements Exception {
  @override
  String toString() => '已取消重新发送，原文已保留';
}

/// 聊天核心引擎
/// 负责前端消息呈现；模型调用、群聊行为和任务调度由后端执行
/// UI 层严禁直接调用 AI、处理记忆、拆分消息
class ChatController extends ChangeNotifier {
  static final ChatController _instance = ChatController._internal();
  factory ChatController() => _instance;
  ChatController._internal();

  static ChatController get instance => _instance;

  Map<String, String> get _operations => Map<String, String>.from(
    StorageService.getJson('pending_ai_operations') ?? {},
  );
  String _operationKey(String chat, String content) =>
      sha256.convert(utf8.encode('$chat:$content')).toString();
  Future<void> _saveOperation(String chat, String content, String? id) async {
    final values = _operations;
    final key = _operationKey(chat, content);
    if (id == null) {
      values.remove(key);
    } else {
      values[key] = id;
    }
    await StorageService.setJson('pending_ai_operations', values);
  }

  Future<String?> _operation(
    String chat,
    String content,
    String kind, {
    String? roleId,
    Future<bool> Function()? confirmResend,
  }) async {
    final key = _operationKey(chat, content);
    final previous = _operations[key];
    if (previous != null) {
      final uri = Uri.parse(
        '${SessionService.backend}/api/ai/operations/$kind/$previous',
      ).replace(queryParameters: {'chat_id': chat, 'role_id': roleId ?? chat});
      final generation = SessionService.instance.generation;
      var result = await http.get(uri);
      if (result.statusCode != 200) throw StateError('无法确认上次发送结果，请恢复连接后重试');
      var data = jsonDecode(result.body) as Map;
      bool requiresConfirmation(Map value) =>
          (value['messages'] as List? ?? []).isEmpty &&
          (value['state'] == 'uncertain' ||
              (value['state'] == 'claimed' && value['in_flight'] == false));
      if (requiresConfirmation(data)) {
        if (confirmResend == null) throw SendRecoveryRequired();
        if (!await confirmResend()) throw SendRecoveryCancelled();
        // Check again after the dialog: another device or a session change
        // must not turn explicit consent into an unverified paid replay.
        if (generation != SessionService.instance.generation) {
          throw StateError('会话已切换，请重新确认发送');
        }
        result = await http.get(uri);
        if (result.statusCode != 200) throw StateError('无法确认上次发送结果，请恢复连接后重试');
        data = jsonDecode(result.body) as Map;
        if (requiresConfirmation(data)) {
          final id = ApiService.requestId();
          await _saveOperation(chat, content, id);
          return id;
        }
      }
      final rows = data['messages'] as List? ?? [];
      if (data['state'] == 'completed' ||
          (data['state'] != 'claimed' && rows.isNotEmpty)) {
        await MessageStore.instance.acceptServerMessages(chat, rows);
        await _saveOperation(chat, content, null);
        return null;
      }
      if (data['state'] != 'missing' &&
          (data['state'] != 'failed' ||
              (data['messages'] as List? ?? []).isNotEmpty))
        throw StateError('上次请求仍在处理，请稍后点击重试查询结果；不会重复调用供应商');
      if (data['state'] == 'missing') return previous;
    }
    final id = ApiService.requestId();
    await _saveOperation(chat, content, id);
    return id;
  }

  /// 聊天上下文缓存
  final Map<String, ChatContext> _contexts = {};

  /// 正在处理的聊天 ID 集合
  final Set<String> _processingChats = {};
  final Map<String, Completer<void>> _completion = {};
  Future<void> resetSession() async {
    await Future.wait(_completion.values.map((c) => c.future).toList());
    _contexts.clear();
    _typingCallbacks.clear();
    _processingChats.clear();
  }

  /// "正在输入"状态回调（按 chatId）- 仅用于单聊
  final Map<String, void Function(bool)> _typingCallbacks = {};

  /// 核心记忆总结轮数（默认 20 轮）
  int _summaryEveryNRounds = 20;

  /// 设置核心记忆总结轮数
  set summaryEveryNRounds(int value) {
    if (value > 0) {
      _summaryEveryNRounds = value;
      MemoryManager.summarizeInterval = value * 2;
    }
  }

  int get summaryEveryNRounds => _summaryEveryNRounds;

  /// 初始化
  static Future<void> init() async {
    await MessageStore.init();
    debugPrint('ChatController initialized');
  }

  // ========== 公开接口 ==========

  /// 初始化聊天上下文（确保消息已加载）
  Future<ChatContext> initChat(
    String chatId, {
    bool isGroup = false,
    List<String>? memberIds,
  }) async {
    // 确保消息已加载
    await MessageStore.instance.ensureLoaded(chatId);

    if (!_contexts.containsKey(chatId)) {
      _contexts[chatId] = ChatContext(
        chatId: chatId,
        isGroup: isGroup,
        memberIds: memberIds,
        messageCount: MessageStore.instance.getMessageCount(chatId),
      );
    } else {
      // 更新消息数量
      final ctx = _contexts[chatId]!;
      _contexts[chatId] = ctx.copyWith(
        messageCount: MessageStore.instance.getMessageCount(chatId),
      );
    }

    // 强制刷新 Stream 确保 UI 收到历史消息
    MessageStore.instance.refreshStream(chatId);

    return _contexts[chatId]!;
  }

  /// 获取聊天上下文
  ChatContext? getContext(String chatId) => _contexts[chatId];

  /// 获取聊天记录数量（从 MessageStore 读取，确保准确）
  int getMessageCount(String chatId) {
    return MessageStore.instance.getMessageCount(chatId);
  }

  /// 创建消息（统一入口）
  Message createMessage({
    required String senderId,
    required String receiverId,
    required String content,
    Message? quotedMessage,
  }) {
    if (quotedMessage != null) {
      return Message.withQuote(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: senderId,
        receiverId: receiverId,
        content: content,
        quotedMessage: quotedMessage,
      );
    }
    return Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  /// 发送用户消息（唯一入口）
  /// 请求期间显示临时气泡；历史只保存后端确认的数据，失败保留草稿。
  Future<void> sendUserMessage(
    String chatId,
    String content, {
    Message? quotedMessage,
    Future<bool> Function()? confirmResend,
  }) async {
    if (content.trim().isEmpty) return;
    if (!SessionService.instance.authenticated) throw StateError('请登录后重试');
    if (_processingChats.contains(chatId)) throw StateError('正在处理上一条消息，请稍后重试');
    _processingChats.add(chatId);
    _completion[chatId] = Completer<void>();
    notifyListeners();
    try {
      final context = await initChat(chatId);
      if (context.isGroup) {
        await _handleGroupChat(chatId, content, quotedMessage, confirmResend);
      } else {
        await _handleSingleChat(chatId, content, quotedMessage, confirmResend);
      }
      _updateChatList(chatId);
    } finally {
      MessageStore.instance.clearOutgoing(chatId);
      _hideTyping(chatId);
      _processingChats.remove(chatId);
      _completion.remove(chatId)?.complete();
      notifyListeners();
    }
  }

  Future<void> sendUserImageMessage(
    String chatId,
    String imagePath, {
    Future<bool> Function()? confirmResend,
  }) async {
    if (_processingChats.contains(chatId)) throw StateError('正在处理上一条消息');
    _processingChats.add(chatId);
    _completion[chatId] = Completer<void>();
    try {
      final context = await initChat(chatId);
      final role = context.isGroup
          ? RoleService.getRoleById(
              (context.memberIds.toList()..shuffle()).firstOrNull ?? '',
            )
          : RoleService.getRoleById(chatId);
      if (role == null) throw StateError('角色不存在或群聊没有可用成员');
      final operation = await _operation(
        chatId,
        imagePath,
        'vision',
        roleId: role.id,
        confirmResend: confirmResend,
      );
      if (operation == null) return;
      final result = await ApiService.chatWithImage(
        imagePath: imagePath,
        roleId: role.id,
        chatId: chatId,
        operationId: operation,
      );
      await MessageStore.instance.acceptServerMessages(
        chatId,
        result['messages'] as List? ?? [],
      );
      await _saveOperation(chatId, imagePath, null);
      _updateChatList(chatId);
    } finally {
      _processingChats.remove(chatId);
      _completion.remove(chatId)?.complete();
      notifyListeners();
    }
  }

  /// 发送带引用的用户消息
  Future<void> sendUserMessageWithQuote(
    String chatId,
    String content,
    String quotedMessageId,
    String quotedContent, {
    Future<bool> Function()? confirmResend,
  }) async {
    if (content.trim().isEmpty) return;

    // 获取被引用的消息
    final messages = MessageStore.instance.getMessages(chatId);
    final quotedMessage = messages
        .where((m) => m.id == quotedMessageId)
        .firstOrNull;

    if (quotedMessage != null) {
      await sendUserMessage(
        chatId,
        content,
        quotedMessage: quotedMessage,
        confirmResend: confirmResend,
      );
    } else {
      // 如果找不到原消息，创建一个临时的引用
      final tempQuotedMessage = Message(
        id: quotedMessageId,
        senderId: 'unknown',
        receiverId: 'me',
        content: quotedContent,
        timestamp: DateTime.now(),
      );
      await sendUserMessage(
        chatId,
        content,
        quotedMessage: tempQuotedMessage,
        confirmResend: confirmResend,
      );
    }
  }

  /// 进入聊天页
  Future<void> onChatPageEnter(String chatId) async {
    NotificationService.instance.setCurrentChat(chatId);
    NotificationService.instance
        .clearChatNotification(chatId)
        .catchError((_) {});
    MessageStore.instance.setHistoryOpen(chatId, true);
    await MessageStore.instance.ensureLoaded(chatId);
    MessageStore.instance.clearUnread(chatId);
    ChatListService.instance.clearUnread(chatId);
    MessageStore.instance.refreshStream(chatId);
    DiagnosticsService.event('chat', 'entered_chat', chatId: chatId);

    // 从后端同步角色数据（异步，不阻塞UI）
    RoleService.fetchFromBackend()
        .then((_) {
          debugPrint('ChatController: Role data synced from backend');
        })
        .catchError((e) {
          DiagnosticsService.event('chat', 'role_sync_failed', error: e);
        });
  }

  /// 退出聊天页
  void onChatPageExit(String chatId) {
    NotificationService.instance.setCurrentChat(null);
    MessageStore.instance.setHistoryOpen(chatId, false);
    DiagnosticsService.event('chat', 'exited_chat', chatId: chatId);
  }

  /// 手动标记未读
  void markChatUnread(String chatId) {
    MessageStore.instance.setUnread(chatId, 1);
    ChatListService.instance.markAsUnread(chatId);
  }

  /// 从聊天列表移除
  void deleteChatFromList(String chatId) {
    ChatListService.instance.removeFromList(chatId);
  }

  /// 删除消息
  Future<void> deleteMessage(String chatId, String messageId) async {
    await MessageStore.instance.deleteMessage(chatId, messageId);
  }

  /// 创建群聊
  Future<String> createGroupChat(List<String> roleIds, {String? name}) async {
    final group = await GroupChatService.createGroup(
      memberIds: roleIds,
      name: name ?? '群聊',
    );
    await initChat(group.id, isGroup: true, memberIds: roleIds);
    ChatListService.instance.getOrCreateChat(
      id: group.id,
      name: group.name,
      isGroup: true,
      memberIds: roleIds,
    );
    return group.id;
  }

  /// 注册 typing 回调（仅单聊使用）
  void registerTypingCallback(String chatId, void Function(bool) callback) {
    _typingCallbacks[chatId] = callback;
  }

  void unregisterTypingCallback(String chatId) {
    _typingCallbacks.remove(chatId);
  }

  bool isProcessing(String chatId) => _processingChats.contains(chatId);

  // ========== 单聊处理 ==========

  Future<void> _handleSingleChat(
    String chatId,
    String userMessage,
    Message? quote,
    Future<bool> Function()? confirmResend,
  ) async {
    final role = RoleService.getRoleById(chatId);
    if (role == null) throw StateError('角色不存在，请返回角色列表后重试');
    final operation = await _operation(
      chatId,
      userMessage,
      'event',
      confirmResend: confirmResend,
    );
    if (operation == null) return;
    MessageStore.instance.showOutgoing(
      chatId,
      Message(
        id: '${operation}_user',
        senderId: 'me',
        receiverId: chatId,
        content: userMessage,
        timestamp: DateTime.now(),
        quotedMessageId: quote?.id,
        quotedPreviewText: quote?.content,
      ),
    );
    _setTyping(chatId, true);
    final response = await ApiService.sendChatViaBackend(
      roleId: role.id,
      message: userMessage,
      operationId: operation,
      quoteId: quote?.id,
      quoteContent: quote?.content.substring(
        0,
        min(1000, quote.content.length),
      ),
    );
    if (!response.success) throw StateError(response.error ?? '发送失败，请手动重试');
    final rows = (response.metadata['messages'] as List?) ?? [];
    await MessageStore.instance.acceptServerMessages(chatId, rows);
    if (rows.isEmpty) await MessageStore.instance.refreshFromBackend(chatId);
    await _saveOperation(chatId, userMessage, null);
  }

  Future<void> _handleGroupChat(
    String chatId,
    String userMessage,
    Message? quote,
    Future<bool> Function()? confirmResend,
  ) async {
    final group = GroupChatService.getGroup(chatId);
    if (group == null) throw StateError('群聊不存在');
    await BackendSyncService.ensureGroup(group);
    final operation = await _operation(
      chatId,
      userMessage,
      'group',
      confirmResend: confirmResend,
    );
    if (operation == null) return;
    MessageStore.instance.showOutgoing(
      chatId,
      Message(
        id: '${operation}_user',
        senderId: 'me',
        receiverId: chatId,
        content: userMessage,
        timestamp: DateTime.now(),
        quotedMessageId: quote?.id,
        quotedPreviewText: quote?.content,
      ),
    );
    final result = await ApiService.request('/api/groups/$chatId/turn', {
      'request_id': operation,
      'content': userMessage,
      'quote_id': quote?.id,
      'quote_content': quote?.content.substring(
        0,
        min(1000, quote.content.length),
      ),
    });
    await MessageStore.instance.acceptServerMessages(
      chatId,
      result['messages'] as List? ?? [],
    );
    if (result['success'] != true)
      throw StateError(result['error'] as String? ?? '群聊供应商请求失败');
    await _saveOperation(chatId, userMessage, null);
  }

  // ========== 辅助方法 ==========

  void _hideTyping(String chatId) {
    _setTyping(chatId, false);
  }

  void _setTyping(String chatId, bool isTyping) {
    _typingCallbacks[chatId]?.call(isTyping);
  }

  void _updateChatList(String chatId) {
    final lastMessage = MessageStore.instance.getLastMessage(chatId);
    if (lastMessage != null) {
      ChatListService.instance.updateChat(
        chatId: chatId,
        lastMessage: _getMessageDisplayText(lastMessage),
        lastMessageTime: lastMessage.timestamp,
      );
    }
  }

  /// 获取消息的显示文本（用于聊天列表预览）
  static String _getMessageDisplayText(Message message) {
    switch (message.type) {
      case MessageType.sticker:
        return '[图片]';
      case MessageType.image:
        return '[图片]';
      default:
        return message.content;
    }
  }
}
