import '../services/resource_cache_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/input_bar.dart';
import '../core/chat_controller.dart';
import '../core/message_store.dart';
import '../services/role_service.dart';
import '../services/favorite_service.dart';
import '../services/settings_service.dart';
import '../services/diagnostics_service.dart';
import 'chat_settings_page.dart';
import 'group_settings_page.dart';

/// 引用状态
class QuoteState {
  final String messageId;
  final String content;
  final String senderName;

  const QuoteState({
    required this.messageId,
    required this.content,
    required this.senderName,
  });
}

/// 聊天详情页面
/// 使用 ChatController 架构，支持多选收藏
class ChatDetailPage extends StatelessWidget {
  final String chatId;
  final String chatName;
  final bool isAI;
  final bool isGroup;
  final List<String>? memberIds;

  const ChatDetailPage({
    super.key,
    required this.chatId,
    required this.chatName,
    this.isAI = true,
    this.isGroup = false,
    this.memberIds,
  });

  @override
  Widget build(BuildContext context) => _ChatDetailContent(
    key: ValueKey(chatId),
    chatId: chatId,
    chatName: chatName,
    isAI: isAI,
    isGroup: isGroup,
    memberIds: memberIds,
  );
}

class _ChatDetailContent extends StatefulWidget {
  final String chatId;
  final String chatName;
  final bool isAI;
  final bool isGroup;
  final List<String>? memberIds;
  const _ChatDetailContent({
    super.key,
    required this.chatId,
    required this.chatName,
    required this.isAI,
    required this.isGroup,
    this.memberIds,
  });
  @override
  State<_ChatDetailContent> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<_ChatDetailContent> {
  final ScrollController _scrollController = ScrollController();
  bool _showTyping = false;
  bool _loadingOlder = false;
  late Stream<List<Message>> _messageStream;

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    setState(() => _loadingOlder = true);
    await MessageStore.instance.loadOlder(widget.chatId);
    if (mounted) setState(() => _loadingOlder = false);
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 160 &&
        MessageStore.instance.hasMore(widget.chatId) &&
        MessageStore.instance.historyError(widget.chatId) == null) {
      _loadOlder();
    }
  }

  late Role _currentRole;

  /// 当前引用状态
  QuoteState? _quoteState;

  /// 多选模式
  bool _isMultiSelectMode = false;
  final Set<String> _selectedMessageIds = {};

  @override
  void initState() {
    super.initState();

    _currentRole =
        RoleService.getRoleById(widget.chatId) ??
        Role(id: widget.chatId, name: widget.chatName, systemPrompt: '');

    ChatController.instance.registerTypingCallback(
      widget.chatId,
      _onTypingChanged,
    );

    // 监听设置更新（包括背景图）
    SettingsService.instance.addListener(_onSettingsChanged);

    _messageStream = MessageStore.instance.watchMessages(widget.chatId);
    _scrollController.addListener(_onScroll);
    _initializeChat();
  }

  Future<void> _initializeChat() async {
    await ChatController.instance.initChat(
      widget.chatId,
      isGroup: widget.isGroup,
      memberIds: widget.memberIds,
    );

    await ChatController.instance.onChatPageEnter(widget.chatId);
    if (!mounted) return;
    MessageStore.instance.refreshFromBackend(widget.chatId);

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animate: false);
      });
    }
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    ChatController.instance.unregisterTypingCallback(widget.chatId);
    ChatController.instance.onChatPageExit(widget.chatId);
    MessageStore.instance.releaseHistory(widget.chatId);
    _scrollController.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    // 设置更新时刷新背景图
    if (mounted) setState(() {});
  }

  void _onTypingChanged(bool isTyping) {
    if (mounted) {
      setState(() => _showTyping = isTyping);
    }
  }

  /// 发送消息（支持引用）
  Future<bool> _confirmResend() async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            titleTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF181818),
            ),
            contentTextStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 15,
              height: 1.5,
              color: Color(0xFF666666),
            ),
            title: const Text('确认重新发送？'),
            content: const Text(
              '上次请求已停止等待，后端没有找到回复。但供应商可能已处理并计费。重新发送会发起一次新请求，可能重复计费。是否继续？',
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF666666),
                ),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留原文'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF07C160),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重新发送'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (ChatController.instance.isProcessing(widget.chatId))
      throw StateError('正在处理上一条消息');

    if (_quoteState != null) {
      await ChatController.instance.sendUserMessageWithQuote(
        widget.chatId,
        text,
        _quoteState!.messageId,
        _quoteState!.content,
        confirmResend: _confirmResend,
      );
      if (mounted) setState(() => _quoteState = null);
    } else {
      await ChatController.instance.sendUserMessage(
        widget.chatId,
        text,
        confirmResend: _confirmResend,
      );
    }

    _scrollToBottom();
  }

  /// 发送图片消息
  Future<void> _sendImageMessage(String imagePath) async {
    await ChatController.instance.sendUserImageMessage(
      widget.chatId,
      imagePath,
      confirmResend: _confirmResend,
    );
    _scrollToBottom();
  }

  /// 设置引用状态
  void _setQuote(Message message) {
    final senderName = message.senderId == 'me'
        ? '我'
        : (RoleService.getRoleById(message.senderId)?.name ?? widget.chatName);

    setState(() {
      _quoteState = QuoteState(
        messageId: message.id,
        content: message.content.length > 50
            ? '${message.content.substring(0, 50)}...'
            : message.content,
        senderName: senderName,
      );
    });
  }

  /// 清除引用状态
  void _clearQuote() {
    setState(() => _quoteState = null);
  }

  // ========== 多选模式 ==========

  /// 进入多选模式
  void _enterMultiSelectMode(Message initialMessage) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedMessageIds.clear();
      _selectedMessageIds.add(initialMessage.id);
    });
  }

  /// 退出多选模式
  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedMessageIds.clear();
    });
  }

  /// 切换消息选中状态
  void _toggleMessageSelection(Message message) {
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  /// 收藏选中的消息
  Future<void> _favoriteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;

    final messages = MessageStore.instance.getMessages(widget.chatId);
    final selectedMessages = messages
        .where((m) => _selectedMessageIds.contains(m.id))
        .toList();

    if (selectedMessages.isEmpty) return;

    await FavoriteService.instance.createCollection(
      chatId: widget.chatId,
      chatName: widget.chatName,
      userName: '我',
      roleName: _currentRole.name,
      messages: selectedMessages,
      getSenderName: (senderId) {
        final role = RoleService.getRoleById(senderId);
        return role?.name ?? widget.chatName;
      },
    );

    _exitMultiSelectMode();
  }

  /// 删除消息
  void _deleteMessage(Message message) async {
    await MessageStore.instance.deleteMessage(widget.chatId, message.id);
  }

  void _scrollToBottom({bool animate = true}) {
    if (_scrollController.hasClients) {
      const position = 0.0;
      if (animate) {
        _scrollController.animateTo(
          position,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(position);
      }
    }
  }

  bool _shouldShowTime(List<Message> messages, int index) {
    if (index == 0) return true;
    final current = messages[index];
    final previous = messages[index - 1];
    return current.timestamp.difference(previous.timestamp).inMinutes > 5;
  }

  String _formatTime(DateTime time) {
    time = time.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(time.year, time.month, time.day);

    if (messageDay == today) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (messageDay == today.subtract(const Duration(days: 1))) {
      return '昨天 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  void _openSettings() {
    if (widget.isGroup) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GroupSettingsPage(groupId: widget.chatId),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatSettingsPage(
            chatId: widget.chatId,
            chatName: widget.chatName,
            currentRole: _currentRole,
            onRoleChanged: () {
              final role = RoleService.getRoleById(widget.chatId);
              if (!mounted || role == null) return;
              setState(() {
                _currentRole = role;
                DiagnosticsService.event(
                  'settings',
                  'chat_role_callback',
                  chatId: widget.chatId,
                  roleId: _currentRole.id,
                );
              });
            },
            onClearHistory: () {
              if (mounted) setState(() {});
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isGroup &&
        widget.isAI &&
        RoleService.getRoleById(widget.chatId) == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.chatName)),
        body: const Center(child: Text('角色不存在，请返回角色列表后重试')),
      );
    }
    final backgroundUrl = SettingsService.instance.chatBackgroundUrl;

    return Scaffold(
      appBar: _buildAppBar(),
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFEDEDED),
          image: backgroundUrl.isNotEmpty && ResourceCacheService.accessAllowed
              ? DecorationImage(
                  image:
                      (backgroundUrl.startsWith('http') ||
                          backgroundUrl.startsWith('/api/'))
                      ? ResourceCacheService.provider(backgroundUrl)
                            as ImageProvider
                      : FileImage(File(backgroundUrl)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Column(
          children: [
            // 消息列表
            Expanded(
              child: StreamBuilder<List<Message>>(
                stream: _messageStream,
                builder: (context, snapshot) {
                  final messages = snapshot.data ?? [];

                  if (messages.isEmpty &&
                      snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (messages.isEmpty &&
                      MessageStore.instance.historyError(widget.chatId) !=
                          null) {
                    return Center(
                      child: TextButton(
                        onPressed: () => MessageStore.instance
                            .refreshFromBackend(widget.chatId),
                        child: const Text('聊天记录加载失败，点击重试'),
                      ),
                    );
                  }
                  if (messages.isEmpty) {
                    return const Center(
                      child: Text(
                        '暂无消息',
                        style: TextStyle(
                          color: Color(0xFFBBBBBB),
                          fontSize: 14,
                        ),
                      ),
                    );
                  }

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!_isMultiSelectMode &&
                        !_loadingOlder &&
                        _scrollController.hasClients &&
                        _scrollController.position.pixels < 80) {
                      _scrollToBottom();
                    }
                  });

                  return ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, reverseIndex) {
                      if (reverseIndex == messages.length) {
                        final error = MessageStore.instance.historyError(
                          widget.chatId,
                        );
                        return Center(
                          child: _loadingOlder
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: CircularProgressIndicator(),
                                )
                              : TextButton(
                                  onPressed: error != null
                                      ? () async {
                                          await MessageStore.instance
                                              .refreshFromBackend(
                                                widget.chatId,
                                              );
                                          await _loadOlder();
                                        }
                                      : MessageStore.instance.hasMore(
                                          widget.chatId,
                                        )
                                      ? _loadOlder
                                      : null,
                                  child: Text(
                                    error ??
                                        (MessageStore.instance.hasMore(
                                              widget.chatId,
                                            )
                                            ? '加载更早消息'
                                            : '没有更早消息'),
                                  ),
                                ),
                        );
                      }
                      final index = messages.length - 1 - reverseIndex;
                      final message = messages[index];
                      final showTime = _shouldShowTime(messages, index);

                      return Column(
                        key: ValueKey(message.id),
                        children: [
                          if (showTime)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCECECE),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _formatTime(message.timestamp),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          _buildMessageBubble(message),
                          if (MessageStore.instance.isOutgoing(
                            widget.chatId,
                            message.id,
                          ))
                            const Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(0, 0, 16, 6),
                                child: Text(
                                  '等待服务器确认',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF888888),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            // 引用预览（如果有）
            if (_quoteState != null && !_isMultiSelectMode)
              _buildQuotePreview(),
            // 多选工具栏或输入栏
            if (_isMultiSelectMode)
              _buildMultiSelectToolbar()
            else
              InputBar(
                draftKey: widget.chatId,
                onSend: _sendMessage,
                onImageSend: _sendImageMessage,
              ),
          ],
        ),
      ),
    );
  }

  /// 构建 AppBar（支持多选模式）
  PreferredSizeWidget _buildAppBar() {
    if (_isMultiSelectMode) {
      return AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          onPressed: _exitMultiSelectMode,
          icon: const Icon(Icons.close, size: 24),
        ),
        title: Text(
          '已选择 ${_selectedMessageIds.length} 条',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      );
    }

    return AppBar(
      backgroundColor: const Color(0xFFEDEDED),
      foregroundColor: const Color(0xFF000000),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.chatName,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          if (_showTyping && !widget.isGroup)
            const Text(
              '对方正在输入...',
              style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
        ],
      ),
      leading: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.arrow_back_ios, size: 20),
      ),
      actions: [
        IconButton(
          onPressed: _openSettings,
          icon: const Icon(Icons.more_horiz, size: 24),
        ),
      ],
    );
  }

  /// 构建多选工具栏
  Widget _buildMultiSelectToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildToolbarButton(
              icon: Icons.star_border,
              label: '收藏',
              onTap: _selectedMessageIds.isEmpty
                  ? null
                  : _favoriteSelectedMessages,
            ),
            _buildToolbarButton(
              icon: Icons.delete_outline,
              label: '删除',
              onTap: _selectedMessageIds.isEmpty
                  ? null
                  : _deleteSelectedMessages,
              color: Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? color,
  }) {
    final isEnabled = onTap != null;
    final finalColor = isEnabled
        ? (color ?? const Color(0xFF333333))
        : const Color(0xFFCCCCCC);

    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: finalColor),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: finalColor)),
        ],
      ),
    );
  }

  /// 删除选中的消息
  Future<void> _deleteSelectedMessages() async {
    for (final id in _selectedMessageIds) {
      await MessageStore.instance.deleteMessage(widget.chatId, id);
    }
    _exitMultiSelectMode();
  }

  /// 构建引用预览
  Widget _buildQuotePreview() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 32, color: const Color(0xFF07C160)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '引用 ${_quoteState!.senderName}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF07C160),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _quoteState!.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _clearQuote,
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF888888)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    // 错误消息
    if (message.senderId == 'error') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEEEE),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFFFCCCC)),
            ),
            child: Text(
              message.content,
              style: const TextStyle(color: Color(0xFFFF4444), fontSize: 13),
            ),
          ),
        ),
      );
    }

    // 系统消息
    if (message.senderId == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              message.content,
              style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 13),
            ),
          ),
        ),
      );
    }

    // 普通消息
    final isMe = message.senderId == 'me';
    final role = isMe ? null : RoleService.getRoleById(message.senderId);
    final senderName = isMe ? '我' : (role?.name ?? widget.chatName);
    final isSelected = _selectedMessageIds.contains(message.id);

    // 多选模式
    if (_isMultiSelectMode) {
      return GestureDetector(
        onTap: () => _toggleMessageSelection(message),
        child: Container(
          color: isSelected
              ? const Color(0xFF07C160).withValues(alpha: 0.1)
              : Colors.transparent,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? const Color(0xFF07C160)
                      : const Color(0xFFCCCCCC),
                  size: 22,
                ),
              ),
              Expanded(
                child: ChatBubble(
                  message: message,
                  isSender: isMe,
                  avatarUrl: isMe ? null : role?.avatarUrl,
                  senderName: senderName,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 普通模式
    return ChatBubble(
      message: message,
      isSender: isMe,
      avatarUrl: isMe ? null : role?.avatarUrl,
      senderName: senderName,
      onLongPress: () => _enterMultiSelectMode(message),
      onQuote: () => _setQuote(message),
      onDelete: () => _deleteMessage(message),
    );
  }
}
