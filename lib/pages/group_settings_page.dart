import 'memory_management_page.dart';
import '../widgets/history_list.dart';
import 'package:flutter/material.dart';
import '../models/group_chat.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../services/group_chat_service.dart';
import '../services/role_service.dart';
import '../services/chat_list_service.dart';
import '../core/message_store.dart';

/// 群聊设置页面
/// 管理群成员、群名称、解散群聊
class GroupSettingsPage extends StatefulWidget {
  final String groupId;

  const GroupSettingsPage({super.key, required this.groupId});

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  GroupChat? _group;
  List<Role> _members = [];

  @override
  void initState() {
    super.initState();
    _loadGroup();
  }

  void _loadGroup() {
    _group = GroupChatService.getGroup(widget.groupId);
    if (_group != null) {
      _members = _group!.memberIds
          .map((id) => RoleService.getRoleById(id))
          .whereType<Role>()
          .toList();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_group == null) {
      return const Scaffold(body: Center(child: Text('群聊不存在')));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('群聊设置'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 群成员
          _buildSection([
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '群成员',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${_members.length}人',
                        style: const TextStyle(color: Color(0xFF888888)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      ..._members.map((r) => _buildMemberItem(r)),
                      _buildAddButton(),
                    ],
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 10),

          // 群名称
          _buildSection([
            _buildItem(
              title: '群聊名称',
              trailing: Text(
                _group!.name,
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _renameGroup,
            ),
          ]),

          const SizedBox(height: 10),

          // 聊天记录和记忆
          _buildSection([
            _buildItem(
              title: '聊天记录',
              trailing: Text(
                '${MessageStore.instance.getMessageCount(widget.groupId)} 条',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _showChatHistory,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '核心记忆总结轮数',
              trailing: Text(
                '${_group!.summaryEveryNRounds} 轮',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _editSummaryRounds,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '记忆管理',
              trailing: Text(
                '查看与修正',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _showCoreMemory,
            ),
          ]),

          const SizedBox(height: 10),

          // 防刷屏设置
          _buildSection([
            _buildItem(
              title: 'AI 回复冷却',
              trailing: Text(
                '${_group!.cooldownSeconds} 秒',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _editCooldown,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '每分钟最大回复',
              trailing: Text(
                '${_group!.maxRepliesPerMinute} 条',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _editMaxReplies,
            ),
          ]),

          const SizedBox(height: 10),

          // AI 行为设置
          _buildSection([
            _buildItem(
              title: 'AI 回复概率',
              trailing: Text(
                '${(_group!.aiReplyProbability * 100).toInt()}%',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _editAiReplyProbability,
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: 'AI 互相回复',
              trailing: Switch(
                value: _group!.allowAiToAiInteraction,
                onChanged: (value) async {
                  await GroupChatService.updateGroup(
                    _group!.copyWith(allowAiToAiInteraction: value),
                  );
                  _loadGroup();
                },
                activeColor: const Color(0xFF07C160),
              ),
            ),
            const Divider(height: 1, indent: 16),
            _buildItem(
              title: '连续发言上限',
              trailing: Text(
                '${_group!.maxConsecutiveSpeaks} 次',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              onTap: _editMaxConsecutiveSpeaks,
            ),
          ]),

          const SizedBox(height: 10),

          // 解散群聊
          _buildSection([
            _buildItem(
              title: '解散群聊',
              titleColor: const Color(0xFFFA5151),
              onTap: _confirmDissolve,
            ),
          ]),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildItem({
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
    Color? titleColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 16, color: titleColor ?? Colors.black),
            ),
            if (trailing != null)
              Row(
                children: [
                  trailing,
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Color(0xFFCCCCCC),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberItem(Role role) {
    return GestureDetector(
      onLongPress: () => _confirmRemoveMember(role),
      child: Column(
        children: [
          _buildAvatar(role),
          const SizedBox(height: 4),
          SizedBox(
            width: 50,
            child: Text(
              role.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(Role role) {
    final colors = [
      const Color(0xFF7EB7E7),
      const Color(0xFF95EC69),
      const Color(0xFFFFB347),
      const Color(0xFFFF7B7B),
      const Color(0xFFB19CD9),
    ];
    final colorIndex = role.name.hashCode.abs() % colors.length;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 50,
        height: 50,
        color: colors[colorIndex],
        child: Center(
          child: Text(
            role.name.isNotEmpty ? role.name[0].toUpperCase() : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: _addMember,
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFDDDDDD)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.add, color: Color(0xFF888888)),
          ),
          const SizedBox(height: 4),
          const SizedBox(width: 50),
        ],
      ),
    );
  }

  void _addMember() async {
    final allRoles = RoleService.getAllRoles();
    final availableRoles = allRoles
        .where((r) => !_group!.memberIds.contains(r.id))
        .toList();

    if (availableRoles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有更多可添加的角色')));
      return;
    }

    final selected = await showDialog<Role>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('添加成员'),
        children: availableRoles.map((role) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, role),
            child: Text(role.name),
          );
        }).toList(),
      ),
    );

    if (selected != null) {
      await GroupChatService.addMember(_group!.id, selected.id);
      _loadGroup();
    }
  }

  void _confirmRemoveMember(Role role) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除成员'),
        content: Text('确定要将"${role.name}"移出群聊吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await GroupChatService.removeMember(_group!.id, role.id);
              _loadGroup();
            },
            child: const Text('移除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _renameGroup() async {
    final controller = TextEditingController(text: _group!.name);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改群名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入新的群名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await GroupChatService.renameGroup(_group!.id, result);
      _loadGroup();
    }
  }

  void _editCooldown() async {
    int value = _group!.cooldownSeconds;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('AI 回复冷却'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('同一 AI 两次回复之间的最小间隔'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: value > 1 ? () => setState(() => value--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$value 秒', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: () => setState(() => value++),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(cooldownSeconds: result),
      );
      _loadGroup();
    }
  }

  void _editMaxReplies() async {
    int value = _group!.maxRepliesPerMinute;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('每分钟最大回复'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('防止 AI 刷屏，限制每分钟回复数'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: value > 1 ? () => setState(() => value--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$value 条', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: () => setState(() => value++),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(maxRepliesPerMinute: result),
      );
      _loadGroup();
    }
  }

  void _editAiReplyProbability() async {
    double value = _group!.aiReplyProbability;

    final result = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('AI 回复概率'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI 参与群聊回复的概率'),
              const SizedBox(height: 16),
              Text(
                '${(value * 100).toInt()}%',
                style: const TextStyle(fontSize: 24),
              ),
              Slider(
                value: value,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: '${(value * 100).toInt()}%',
                onChanged: (v) => setState(() => value = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(aiReplyProbability: result),
      );
      _loadGroup();
    }
  }

  void _editMaxConsecutiveSpeaks() async {
    int value = _group!.maxConsecutiveSpeaks;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('连续发言上限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('同一 AI 角色连续发言的最大次数'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: value > 1 ? () => setState(() => value--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$value 次', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: value < 5 ? () => setState(() => value++) : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(maxConsecutiveSpeaks: result),
      );
      _loadGroup();
    }
  }

  // ========== 聊天记录和记忆功能 ==========

  void _showChatHistory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final messages = MessageStore.instance.getMessages(widget.groupId);

            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '聊天记录 (${messages.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (messages.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await MessageStore.instance.clearMessages(
                                  widget.groupId,
                                );
                                setModalState(() {});
                                setState(() {});
                              },
                              child: const Text(
                                '清空',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: messages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无聊天记录',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : HistoryList(chatId: widget.groupId,
                              itemBuilder: (msg) => _buildMessageItem(msg, setModalState)),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildMessageItem(Message msg, StateSetter setModalState) {
    final isSender = msg.senderId == 'me';
    return ListTile(
      onTap: () => _showFullMessage(msg),
      leading: CircleAvatar(
        backgroundColor: isSender
            ? const Color(0xFF95EC69)
            : const Color(0xFF7EB7E7),
        child: Icon(
          isSender ? Icons.person : Icons.smart_toy,
          color: Colors.white,
          size: 20,
        ),
      ),
      title: Text(msg.content, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
    );
  }

  void _showFullMessage(Message msg) {
    final isSender = msg.senderId == 'me';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: isSender
                  ? const Color(0xFF95EC69)
                  : const Color(0xFF7EB7E7),
              child: Icon(
                isSender ? Icons.person : Icons.smart_toy,
                color: Colors.white,
                size: 16,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isSender ? '我' : msg.senderId,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            msg.content,
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _editSummaryRounds() async {
    int value = _group!.summaryEveryNRounds;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('核心记忆总结轮数'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('每隔多少轮对话后自动总结核心记忆'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: value > 5
                        ? () => setState(() => value -= 5)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$value 轮', style: const TextStyle(fontSize: 18)),
                  IconButton(
                    onPressed: value < 100
                        ? () => setState(() => value += 5)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              Slider(
                value: value.toDouble(),
                min: 5,
                max: 100,
                divisions: 19,
                label: '$value 轮',
                onChanged: (v) => setState(() => value = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await GroupChatService.updateGroup(
        _group!.copyWith(summaryEveryNRounds: result),
      );
      _loadGroup();
    }
  }

  void _showCoreMemory() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => MemoryManagementPage(groupId: widget.groupId)));
  }

  void _confirmDissolve() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解散群聊'),
        content: const Text('确定要解散群聊吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await GroupChatService.deleteGroup(_group!.id);
              ChatListService.instance.removeFromList(_group!.id);
              if (mounted) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('解散', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
