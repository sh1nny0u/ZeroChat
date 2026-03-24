import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../models/role.dart';
import '../models/chat_context.dart';
import '../models/group_chat.dart';
import '../services/api_service.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../services/chat_list_service.dart';
import '../services/settings_service.dart';
import '../services/notification_service.dart';
import 'message_store.dart';
import 'segment_sender.dart';
import 'group_scheduler.dart';
import 'memory_manager.dart';
import 'moments_scheduler.dart';
import '../services/intent_service.dart';
import '../services/memory_service.dart';
import '../services/sticker_service.dart';

/// 聊天核心引擎
/// 整个项目中唯一负责消息流转、AI 调度、分段发送、群聊控制、记忆更新的权威组件
/// UI 层严禁直接调用 AI、处理记忆、拆分消息
class ChatController extends ChangeNotifier {
  static final ChatController _instance = ChatController._internal();
  factory ChatController() => _instance;
  ChatController._internal();

  static ChatController get instance => _instance;

  final Random _random = Random();

  /// 聊天上下文缓存
  final Map<String, ChatContext> _contexts = {};

  /// 正在处理的聊天 ID 集合
  final Set<String> _processingChats = {};

  /// "正在输入"状态回调（按 chatId）- 仅用于单聊
  final Map<String, void Function(bool)> _typingCallbacks = {};

  /// 待发送消息队列（用于消息合并等待）
  final Map<String, List<String>> _pendingMessages = {};

  /// 等待定时器（用于消息合并）
  final Map<String, Timer> _waitTimers = {};

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
  /// 支持消息等待合并功能
  Future<void> sendUserMessage(
    String chatId,
    String content, {
    Message? quotedMessage,
  }) async {
    if (content.trim().isEmpty) return;

    debugPrint('ChatController: sendUserMessage to $chatId');

    // 创建用户消息并立即显示
    final userMessage = createMessage(
      senderId: 'me',
      receiverId: 'ai',
      content: content,
      quotedMessage: quotedMessage,
    );
    await MessageStore.instance.addMessage(chatId, userMessage);
    notifyListeners();

    // 获取等待时间配置
    final waitSeconds = SettingsService.instance.messageWaitSeconds;

    // 如果正在等待，重置定时器
    if (_waitTimers.containsKey(chatId)) {
      _waitTimers[chatId]?.cancel();
    }

    // 添加到待发送队列
    _pendingMessages.putIfAbsent(chatId, () => []);
    _pendingMessages[chatId]!.add(content);

    // 如果等待时间为 0，立即发送
    if (waitSeconds == 0) {
      await _sendBatchedMessages(chatId);
      return;
    }

    // 设置定时器
    _waitTimers[chatId] = Timer(
      Duration(seconds: waitSeconds),
      () => _sendBatchedMessages(chatId),
    );
  }

  /// 发送合并后的消息
  Future<void> _sendBatchedMessages(String chatId) async {
    // 取出待发送消息
    final messages = _pendingMessages.remove(chatId) ?? [];
    _waitTimers.remove(chatId);

    if (messages.isEmpty) return;
    if (_processingChats.contains(chatId)) {
      debugPrint('ChatController: Already processing $chatId, queueing');
      // 重新加入队列
      _pendingMessages[chatId] = messages;
      return;
    }

    // 合并消息（用换行连接）
    final combinedContent = messages.join('\n');

    debugPrint(
      'ChatController: Sending batched messages (${messages.length} msgs) to $chatId',
    );

    // 初始化上下文
    final context = await initChat(chatId);

    // 更新上下文消息数量
    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    // 标记正在处理
    _processingChats.add(chatId);
    notifyListeners();

    // 检查是否需要触发核心记忆总结
    MemoryManager.triggerSummarizeIfNeeded(chatId);

    // 根据聊天类型处理（后台执行）
    _processMessageInBackground(chatId, combinedContent, context.isGroup);
  }

  /// 发送用户图片消息
  Future<void> sendUserImageMessage(String chatId, String imagePath) async {
    if (_processingChats.contains(chatId)) {
      debugPrint('ChatController: Already processing $chatId, ignoring image');
      return;
    }

    debugPrint(
      'ChatController: sendUserImageMessage to $chatId, path=$imagePath',
    );

    // 初始化上下文
    final context = await initChat(chatId);

    // 1. 创建图片消息（使用 image 类型）
    final imageMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: 'me',
      receiverId: 'ai',
      content: imagePath, // 保存图片路径
      type: MessageType.image,
      timestamp: DateTime.now(),
    );

    // 2. 写入 MessageStore
    await MessageStore.instance.addMessage(chatId, imageMessage);

    // 更新上下文消息数量
    _contexts[chatId] = context.copyWith(
      messageCount: MessageStore.instance.getMessageCount(chatId),
      lastMessageTime: DateTime.now(),
    );

    // 标记正在处理
    _processingChats.add(chatId);
    notifyListeners();

    // 3. 后台处理图片消息（调用 vision API）
    _processImageMessageInBackground(chatId, imagePath, context.isGroup);
  }

  /// 后台处理图片消息
  Future<void> _processImageMessageInBackground(
    String chatId,
    String imagePath,
    bool isGroup,
  ) async {
    try {
      Role role;
      if (isGroup) {
        // 群聊：从群成员中随机选一个角色回复图片
        final context = _contexts[chatId];
        final memberIds = context?.memberIds ?? [];
        if (memberIds.isEmpty) {
          role = RoleService.getCurrentRole();
        } else {
          final randomId = memberIds[_random.nextInt(memberIds.length)];
          role =
              RoleService.getRoleById(randomId) ?? RoleService.getCurrentRole();
        }
      } else {
        role = RoleService.getRoleById(chatId) ?? RoleService.getCurrentRole();
      }

      // 显示 typing
      await _showTypingWithDelay(chatId, isGroup: isGroup);

      // 调用 vision API（包含 Base Prompt 以遵循全局规则）
      final systemPrompt =
          '${SettingsService.instance.basePrompt}\n\n${role.systemPrompt}';
      final aiReply = await ApiService.chatWithImage(
        imagePath: imagePath,
        userPrompt:
            '用户发送了一张图片，请以你扮演的角色身份自然地回应这张图片。不要描述图片内容，而是像朋友收到图片一样自然地回复，表达你的感受或想法。',
        rolePersona: systemPrompt,
      );

      // 发送 AI 回复
      await _sendSegmentsQueued(chatId, role.id, aiReply, isGroup: isGroup);

      // 更新聊天列表
      _updateChatList(chatId);
    } catch (e) {
      debugPrint('ChatController: Image message error: $e');
      // 添加错误消息
      final errorMsg = Message(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: 'ai',
        receiverId: 'me',
        content: '图片识别失败：$e',
        type: MessageType.text,
        timestamp: DateTime.now(),
      );
      await MessageStore.instance.addMessage(chatId, errorMsg);
    } finally {
      _hideTyping(chatId);
      _processingChats.remove(chatId);
      notifyListeners();
    }
  }

  /// 发送带引用的用户消息
  Future<void> sendUserMessageWithQuote(
    String chatId,
    String content,
    String quotedMessageId,
    String quotedContent,
  ) async {
    if (content.trim().isEmpty) return;

    // 获取被引用的消息
    final messages = MessageStore.instance.getMessages(chatId);
    final quotedMessage = messages
        .where((m) => m.id == quotedMessageId)
        .firstOrNull;

    if (quotedMessage != null) {
      await sendUserMessage(chatId, content, quotedMessage: quotedMessage);
    } else {
      // 如果找不到原消息，创建一个临时的引用
      final tempQuotedMessage = Message(
        id: quotedMessageId,
        senderId: 'unknown',
        receiverId: 'me',
        content: quotedContent,
        timestamp: DateTime.now(),
      );
      await sendUserMessage(chatId, content, quotedMessage: tempQuotedMessage);
    }
  }

  /// 后台处理消息
  void _processMessageInBackground(
    String chatId,
    String content,
    bool isGroup,
  ) {
    Future(() async {
      try {
        if (isGroup) {
          await _handleGroupChat(chatId, content);
        } else {
          await _handleSingleChat(chatId, content);
        }
      } catch (e) {
        debugPrint('ChatController: Error processing message: $e');
      } finally {
        _processingChats.remove(chatId);
        notifyListeners();
        _updateChatList(chatId);
      }
    });
  }

  /// 进入聊天页
  Future<void> onChatPageEnter(String chatId) async {
    await MessageStore.instance.ensureLoaded(chatId);
    MessageStore.instance.clearUnread(chatId);
    ChatListService.instance.clearUnread(chatId);
    MessageStore.instance.refreshStream(chatId);
    debugPrint(
      'ChatController: Entered chat $chatId (${getMessageCount(chatId)} messages)',
    );

    // 从后端同步角色数据（异步，不阻塞UI）
    RoleService.fetchFromBackend()
        .then((_) {
          debugPrint('ChatController: Role data synced from backend');
        })
        .catchError((e) {
          debugPrint('ChatController: Role sync failed: $e');
        });
  }

  /// 退出聊天页
  void onChatPageExit(String chatId) {
    debugPrint('ChatController: Exited chat $chatId');
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

  /// 发送定时任务消息（由 TaskService 调用）
  /// 使用角色人格生成自然的提醒消息
  Future<void> sendScheduledTaskMessage({
    required String chatId,
    required String roleId,
    required String taskContent,
    String? customPrompt,
  }) async {
    final role = RoleService.getRoleById(roleId);
    if (role == null) {
      debugPrint('ChatController: Role not found for scheduled task');
      return;
    }

    debugPrint('ChatController: Sending scheduled task message for $roleId');

    // 构建提示词
    final prompt =
        customPrompt ??
        '你需要自然地提醒用户以下事项，不要说"这是提醒"或"定时任务"之类的话，用日常对话的方式。提醒内容：$taskContent';

    // 调用 AI 生成消息
    final recentMessages = MessageStore.instance.getRecentRounds(
      chatId,
      role.maxContextRounds,
    );
    final history = MessageStore.toApiHistory(recentMessages);
    final coreMemory = MemoryManager.getCoreMemoryForRequest();

    final response = await ApiService.sendChatMessageWithRole(
      message: prompt,
      role: role,
      history: history,
      coreMemory: coreMemory,
    );

    String contentToSend;
    if (response.success && response.content != null) {
      contentToSend = response.content!;
    } else {
      // AI 失败时使用简洁的备用消息
      contentToSend = '嘿～$taskContent';
    }

    // 分段发送
    await _sendSegmentsQueued(chatId, roleId, contentToSend, isGroup: false);

    // 更新聊天列表
    _updateChatList(chatId);

    debugPrint('ChatController: Scheduled task message sent');
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

  Future<void> _handleSingleChat(String chatId, String userMessage) async {
    final role =
        RoleService.getRoleById(chatId) ?? RoleService.getCurrentRole();

    // 意图识别
    final intent = await IntentService.detectIntent(userMessage);
    debugPrint('ChatController: Intent detected: ${intent.type}');

    // 根据意图类型执行副作用（不直接回复，交给 AI 自然回复）
    switch (intent.type) {
      case IntentType.setMemory:
        // 保存到核心记忆
        await MemoryService.addToCoreMemory(
          intent.extractedContent ?? userMessage,
        );
        debugPrint(
          'ChatController: Memory saved, continuing to AI for natural reply',
        );
        break;

      case IntentType.clearMemory:
        // 清除记忆
        await MemoryService.clearCoreMemory();
        MemoryService.clearShortTermMemory(chatId);
        debugPrint(
          'ChatController: Memory cleared, continuing to AI for natural reply',
        );
        break;

      case IntentType.setReminder:
        if (intent.duration != null) {
          debugPrint(
            'ChatController: Reminder intent detected for ${intent.duration}',
          );
          // TODO: 集成 TaskService 创建定时任务
        }
        break;

      case IntentType.setQuietTime:
        if (intent.startHour != null && intent.endHour != null) {
          await SettingsService.instance.setQuietHours(
            intent.startHour!,
            intent.endHour!,
          );
          debugPrint(
            'ChatController: Quiet hours set ${intent.startHour}-${intent.endHour}',
          );
        }
        break;

      case IntentType.normalChat:
        break;
    }

    // 单聊显示"正在输入"
    await _showTypingWithDelay(chatId, isGroup: false);

    final rawReply = await _callAI(
      chatId: chatId,
      role: role,
      userMessage: userMessage,
      isGroup: false,
    );

    if (rawReply != null) {
      await _sendSegmentsQueued(chatId, role.id, rawReply, isGroup: false);
    }

    _hideTyping(chatId);
  }

  // ========== 群聊处理 ==========

  Future<void> _handleGroupChat(String chatId, String userMessage) async {
    final context = _contexts[chatId];
    if (context == null) return;

    // 获取群聊设置
    final group = GroupChatService.getGroup(chatId);
    final aiProbability = group?.aiReplyProbability ?? 0.6;
    final allowAiToAi = group?.allowAiToAiInteraction ?? true;
    final maxConsecutive = group?.maxConsecutiveSpeaks ?? 2;

    // 最大互动轮数
    final maxRounds = allowAiToAi ? 3 : 1;
    var currentRound = 0;
    String lastMessage = userMessage;
    String? lastSpeakerId;

    while (currentRound < maxRounds) {
      currentRound++;

      final schedule = GroupScheduler.selectRespondingRoles(
        memberIds: context.memberIds,
        userMessage: lastMessage,
        lastSpeakerRoleId: lastSpeakerId ?? context.lastSpeakerRoleId,
        consecutiveCounts: context.consecutiveSpeakCount,
        replyProbability: aiProbability,
        maxConsecutiveSpeaks: maxConsecutive,
      );

      if (schedule.selectedRoles.isEmpty) break;

      debugPrint(
        'ChatController: Group round $currentRound, ${schedule.selectedRoles.length} roles',
      );

      for (var i = 0; i < schedule.selectedRoles.length; i++) {
        final role = schedule.selectedRoles[i];

        if (i > 0 || currentRound > 1) {
          await Future.delayed(
            Duration(milliseconds: GroupScheduler.getReplyDelay(i)),
          );
        }

        // 群聊不显示"正在输入"

        final rawReply = await _callAI(
          chatId: chatId,
          role: role,
          userMessage: lastMessage,
          isGroup: true,
        );

        if (rawReply != null) {
          // 群聊分段发送也不显示 typing
          await _sendSegmentsQueued(chatId, role.id, rawReply, isGroup: true);
          context.incrementConsecutiveCount(role.id);
          lastSpeakerId = role.id;
          lastMessage = rawReply;
        }
      }

      // 决定是否继续 AI↔AI 互动
      if (!allowAiToAi) break;
      final continueProbability = 0.3 / currentRound;
      if (_random.nextDouble() > continueProbability) break;
    }
  }

  // ========== AI 调用 ==========

  Future<String?> _callAI({
    required String chatId,
    required Role role,
    required String userMessage,
    required bool isGroup,
  }) async {
    // 优先尝试后端 API
    final backendResponse = await ApiService.sendChatViaBackend(
      roleId: role.id,
      message: userMessage,
    );

    if (backendResponse.success && backendResponse.content != null) {
      debugPrint('ChatController: AI response via backend');
      return backendResponse.content;
    }

    // 后端不可用时，降级到直接调用（保持原有逻辑）
    debugPrint('ChatController: Backend unavailable, fallback to direct API');

    final recentMessages = MessageStore.instance.getRecentRounds(
      chatId,
      role.maxContextRounds,
    );
    final historyMessages = recentMessages.isNotEmpty
        ? recentMessages.sublist(0, recentMessages.length - 1)
        : <Message>[];
    final history = MessageStore.toApiHistory(historyMessages);
    final coreMemory = MemoryManager.getCoreMemoryForRequest();

    // 注入外挂 JSON 记录（与聊天记录同级）
    final attachedJson = role.attachedJsonContent;
    if (attachedJson != null && attachedJson.isNotEmpty) {
      history.insert(0, {'role': 'system', 'content': '[外挂记录]\n$attachedJson'});
    }

    // 获取朋友圈感知上下文（弱上下文，概率注入）
    final momentsContext = isGroup
        ? null
        : MomentsScheduler.instance.buildMomentsAwarenessContext();

    // 如果有朋友圈上下文，附加到消息后面
    final finalMessage = momentsContext != null
        ? '$userMessage\n\n$momentsContext'
        : userMessage;

    final response = await ApiService.sendChatMessageWithRole(
      message: finalMessage,
      role: role,
      history: history,
      coreMemory: coreMemory,
      isGroup: isGroup,
    );

    if (response.success && response.content != null) {
      return response.content;
    } else {
      debugPrint('ChatController: AI call failed: ${response.error}');
      final errorMessage = createMessage(
        senderId: 'error',
        receiverId: 'me',
        content: response.error ?? '发送失败，请重试',
      );
      await MessageStore.instance.addMessage(chatId, errorMessage);
      return null;
    }
  }

  // ========== 分段发送 ==========

  Future<void> _sendSegmentsQueued(
    String chatId,
    String roleId,
    String rawReply, {
    required bool isGroup,
  }) async {
    final segments = SegmentSender.splitMessage(rawReply);
    debugPrint('ChatController: Split into ${segments.length} segments');

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      // 非第一条时延迟（单聊显示 typing，群聊不显示）
      if (i > 0) {
        if (!isGroup) {
          _setTyping(chatId, true);
        }
        final delay = 500 + _random.nextInt(1001); // 500-1500ms
        await Future.delayed(Duration(milliseconds: delay));
      }

      // 解析情绪标签
      final (cleanedText, emotion) = StickerService.parseEmotionTag(segment);

      // 如果整段只是一个情绪标签且无文本内容，则跳过文本消息（仅发表情）
      if (cleanedText.isEmpty && emotion != null) {
        debugPrint('ChatController: Segment is emotion-only [$emotion], skipping text');
      } else {
        final displayText = cleanedText.isNotEmpty ? cleanedText : segment;

        final aiMessage = Message(
          id: '${DateTime.now().millisecondsSinceEpoch}_${i}_${segment.hashCode}',
          senderId: roleId,
          receiverId: 'me',
          content: displayText,
          timestamp: DateTime.now(),
        );

        await MessageStore.instance.addMessage(chatId, aiMessage);
      }

      // 更新未读并发送通知
      if (!_typingCallbacks.containsKey(chatId)) {
        MessageStore.instance.incrementUnread(chatId);
        ChatListService.instance.incrementUnread(chatId);

        // 发送本地通知
        final role = RoleService.getRoleById(roleId);
        NotificationService.instance.showMessageNotification(
          chatId: chatId,
          senderName: role?.name ?? 'AI',
          message: segment,
        );

        // 更新角标
        final totalUnread = ChatListService.instance.totalUnreadCount;
        NotificationService.instance.setBadgeCount(totalUnread);
      }

      // 更新上下文
      final context = _contexts[chatId];
      if (context != null) {
        _contexts[chatId] = context.copyWith(
          messageCount: MessageStore.instance.getMessageCount(chatId),
          lastMessageTime: DateTime.now(),
        );
      }

      debugPrint('ChatController: Sent segment ${i + 1}/${segments.length}');

      // 如果有情绪标签，从后端获取随机表情包并发送
      if (emotion != null) {
        try {
          final backendUrl = SettingsService.instance.backendUrl;
          final url = Uri.parse(
            '$backendUrl/api/roles/$roleId/emojis/$emotion/random',
          );
          final resp = await http.get(url).timeout(const Duration(seconds: 5));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            if (data['found'] == true && data['url'] != null) {
              // 延迟一小段时间再发表情包
              await Future.delayed(
                Duration(milliseconds: 300 + _random.nextInt(500)),
              );

              final stickerUrl = '$backendUrl${data['url']}';
              final stickerContent = StickerService.createStickerMessageContent(
                emotion,
                stickerUrl,
              );
              final stickerMessage = Message(
                id: '${DateTime.now().millisecondsSinceEpoch}_sticker_${emotion.hashCode}',
                senderId: roleId,
                receiverId: 'me',
                content: stickerContent,
                type: MessageType.sticker,
                timestamp: DateTime.now(),
              );
              await MessageStore.instance.addMessage(chatId, stickerMessage);
              debugPrint('ChatController: Sent sticker for emotion: $emotion');
            }
          }
        } catch (e) {
          debugPrint('ChatController: Sticker fetch error: $e');
        }
      }

      if (!isLast) {
        await Future.delayed(
          Duration(milliseconds: 100 + _random.nextInt(200)),
        );
      }
    }

    if (!isGroup) {
      _hideTyping(chatId);
    }
  }

  // ========== 辅助方法 ==========

  Future<void> _showTypingWithDelay(
    String chatId, {
    required bool isGroup,
  }) async {
    if (isGroup) return; // 群聊不显示 typing
    final delay = 500 + _random.nextInt(1500);
    await Future.delayed(Duration(milliseconds: delay));
    _setTyping(chatId, true);
  }

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
