import '../widgets/resource_image.dart';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/chat_info.dart';
import '../services/chat_list_service.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../core/message_store.dart';
import 'chat_detail_page.dart';

/// 聊天列表页面
/// ZeroChat 风格，显示所有聊天会话
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  @override
  void initState() {
    super.initState();
    ChatListService.instance.addListener(_onChatListChanged);
    MessageStore.instance.addListener(_onChatListChanged);
    RoleService.changes.addListener(_onChatListChanged);
    _initChatList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 返回主界面或页面重新显示时刷新聊天列表
    _refreshLastMessages();
  }

  @override
  void dispose() {
    ChatListService.instance.removeListener(_onChatListChanged);
    MessageStore.instance.removeListener(_onChatListChanged);
    RoleService.changes.removeListener(_onChatListChanged);
    super.dispose();
  }

  void _onChatListChanged() {
    if (mounted) setState(() {});
  }

  /// 刷新所有聊天的最后一条消息
  void _refreshLastMessages() {
    final roles = RoleService.getAllRoles();
    for (final role in roles) {
      final lastMessage = MessageStore.instance.getLastMessage(role.id);
      if (lastMessage != null) {
        ChatListService.instance.updateChat(
          chatId: role.id,
          lastMessage: _getDisplayText(lastMessage),
          lastMessageTime: lastMessage.timestamp,
        );
      }
    }
  }

  void _initChatList() {
    // 从角色列表初始化聊天
    final roles = RoleService.getAllRoles();
    for (final role in roles) {
      // 从 MessageStore 获取最后一条消息
      final lastMessage = MessageStore.instance.getLastMessage(role.id);

      ChatListService.instance.getOrCreateChat(
        id: role.id,
        name: role.name,
        avatarUrl: role.avatarUrl,
      );

      // 更新最后一条消息
      if (lastMessage != null) {
        ChatListService.instance.updateChat(
          chatId: role.id,
          lastMessage: _getDisplayText(lastMessage),
          lastMessageTime: lastMessage.timestamp,
        );
      }
    }
  }

  /// 获取消息的显示文本（表情包和图片显示为 [图片]）
  String _getDisplayText(Message message) {
    switch (message.type) {
      case MessageType.sticker:
        return '[图片]';
      case MessageType.image:
        return '[图片]';
      default:
        return message.content;
    }
  }

  /// 获取有效的聊天列表（过滤掉孤立聊天）
  List<ChatInfo> _getValidChatList() {
    final allChats = ChatListService.instance.chatList;
    final roleIds = RoleService.getAllRoles().map((r) => r.id).toSet();
    final groupIds = GroupChatService.getAllGroups().map((g) => g.id).toSet();

    // 只保留角色存在的个人聊天和群聊
    return allChats.where((chat) {
      if (chat.isGroup) {
        return groupIds.contains(chat.id);
      } else {
        return roleIds.contains(chat.id);
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final chatList = _getValidChatList();

    if (chatList.isEmpty) {
      return const Center(
        child: Text('暂无聊天', style: TextStyle(color: Color(0xFF888888))),
      );
    }

    return ListView.builder(
      itemCount: chatList.length,
      itemBuilder: (context, index) {
        final chat = chatList[index];
        return _buildChatItem(chat);
      },
    );
  }

  Widget _buildChatItem(ChatInfo chat) {
    return Material(
      color: chat.isPinned ? const Color(0xFFF5F5F5) : Colors.white,
      child: InkWell(
        onTap: () => _openChat(chat),
        onLongPress: () => _showContextMenu(chat),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFEEEEEE), width: 0.5),
            ),
          ),
          child: Row(
            children: [
              // 头像 + 未读红点
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _buildAvatar(chat),
                  if (chat.unreadCount > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: _buildUnreadBadge(chat.unreadCount),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              // 名称和最后消息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chat.lastMessage,
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
              const SizedBox(width: 8),
              // 时间
              Text(
                _formatTime(chat.lastMessageTime),
                style: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(ChatInfo chat) {
    final colors = [
      const Color(0xFF7EB7E7),
      const Color(0xFF95EC69),
      const Color(0xFFFFB347),
      const Color(0xFFFF7B7B),
      const Color(0xFFB19CD9),
    ];
    final colorIndex = chat.name.hashCode.abs() % colors.length;

    // 对于单聊，从 RoleService 获取最新头像
    String? avatarUrl = chat.avatarUrl;
    if (!chat.isGroup) {
      final role = RoleService.getRoleById(chat.id);
      if (role != null &&
          role.avatarUrl != null &&
          role.avatarUrl!.isNotEmpty) {
        avatarUrl = role.avatarUrl;
      }
    }

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ResourceImage(
          avatarUrl,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              _buildDefaultAvatar(chat, colors[colorIndex]),
        ),
      );
    }
    return _buildDefaultAvatar(chat, colors[colorIndex]);
  }

  Widget _buildDefaultAvatar(ChatInfo chat, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 48,
        height: 48,
        color: color,
        child: Center(
          child: chat.isGroup
              ? const Icon(Icons.group, color: Colors.white, size: 24)
              : Text(
                  chat.name.isNotEmpty ? chat.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildUnreadBadge(int count) {
    final displayText = count > 99 ? '99+' : count.toString();
    final width = count > 99 ? 26.0 : (count > 9 ? 20.0 : 18.0);

    return Container(
      constraints: BoxConstraints(minWidth: width, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFA5151),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Center(
        child: Text(
          displayText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    time = time.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(time.year, time.month, time.day);

    if (messageDate == today) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      return '昨天';
    } else if (time.year == now.year) {
      return '${time.month}/${time.day}';
    } else {
      return '${time.year}/${time.month}/${time.day}';
    }
  }

  void _openChat(ChatInfo chat) {
    // 清除未读
    ChatListService.instance.clearUnread(chat.id);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailPage(
          chatId: chat.id,
          chatName: chat.name,
          isAI: !chat.isGroup,
          isGroup: chat.isGroup,
          memberIds: chat.memberIds,
        ),
      ),
    );
  }

  void _showContextMenu(ChatInfo chat) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 置顶/取消置顶
              ListTile(
                leading: Icon(
                  chat.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                  color: const Color(0xFF07C160),
                ),
                title: Text(chat.isPinned ? '取消置顶' : '置顶聊天'),
                onTap: () {
                  Navigator.pop(context);
                  ChatListService.instance.togglePin(chat.id);
                },
              ),
              // 标记未读
              ListTile(
                leading: const Icon(
                  Icons.mark_email_unread_outlined,
                  color: Color(0xFF07C160),
                ),
                title: const Text('标记为未读'),
                onTap: () {
                  Navigator.pop(context);
                  ChatListService.instance.markAsUnread(chat.id);
                },
              ),
              // 删除聊天
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Color(0xFFFA5151),
                ),
                title: const Text(
                  '删除聊天',
                  style: TextStyle(color: Color(0xFFFA5151)),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(chat);
                },
              ),
              const SizedBox(height: 8),
              // 取消
              ListTile(
                title: const Center(child: Text('取消')),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDelete(ChatInfo chat) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除聊天'),
        content: Text('确定要删除与"${chat.name}"的聊天吗？\n聊天记录将保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ChatListService.instance.removeFromList(chat.id);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
