import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../services/role_service.dart';
import '../services/memory_service.dart';
import '../services/task_service.dart';
import '../core/message_store.dart';
import '../core/proactive_message_scheduler.dart';
import 'role_settings_page.dart';
import 'task_manager_page.dart';

/// 聊天设置页面
/// ZeroChat 风格的聊天信息页面
class ChatSettingsPage extends StatefulWidget {
  final String chatId;
  final String chatName;
  final Role? currentRole;
  final VoidCallback? onRoleChanged;
  final VoidCallback? onClearHistory;

  const ChatSettingsPage({
    super.key,
    required this.chatId,
    required this.chatName,
    this.currentRole,
    this.onRoleChanged,
    this.onClearHistory,
  });

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  late Role _currentRole;

  @override
  void initState() {
    super.initState();
    _currentRole = widget.currentRole ?? RoleService.getCurrentRole();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '聊天信息',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 头像和名称
          _buildSection([_buildAvatarItem()]),

          const SizedBox(height: 10),

          // 聊天记录
          _buildSection([
            _buildItem(
              title: '聊天记录',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${MessageStore.instance.getMessageCount(widget.chatId)} 条',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showChatHistory,
            ),
          ]),

          const SizedBox(height: 10),

          // 核心记忆总结轮数
          _buildSection([
            _buildItem(
              title: '核心记忆总结轮数',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_currentRole.summaryEveryNRounds} 轮',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _editMemoryRounds,
            ),
          ]),

          const SizedBox(height: 10),

          // 核心记忆
          _buildSection([
            _buildItem(
              title: '核心记忆',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_currentRole.coreMemory.length} 条',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showCoreMemory,
            ),
          ]),

          const SizedBox(height: 10),

          // 安静时间（全局设置）
          _buildSection([_buildQuietTimeItem()]),

          const SizedBox(height: 10),

          // 主动消息配置
          _buildSection([
            _buildItem(
              title: '主动消息',
              trailing: Switch(
                value: _currentRole.proactiveConfig.enabled,
                onChanged: (value) => _toggleProactiveMessage(value),
                activeColor: const Color(0xFF07C160),
              ),
            ),
            if (_currentRole.proactiveConfig.enabled) ...[
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '触发提示词',
                trailing: const Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: Color(0xFFCCCCCC),
                ),
                onTap: _editProactivePrompt,
              ),
              const Divider(height: 1, indent: 16),
              _buildItem(
                title: '倒计时区间',
                trailing: Text(
                  '${_currentRole.proactiveConfig.minCountdownHours.toInt()}-${_currentRole.proactiveConfig.maxCountdownHours.toInt()} 小时',
                  style: const TextStyle(color: Color(0xFF888888)),
                ),
                onTap: _editProactiveCountdown,
              ),
            ],
          ]),

          const SizedBox(height: 10),

          // 定时任务
          _buildSection([
            _buildItem(
              title: '定时任务',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${TaskService.getTasksForChat(widget.chatId).where((t) => !t.isCompleted).length} 个',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _openTaskManager,
            ),
          ]),

          const SizedBox(height: 10),

          // 外挂 JSON 记录
          _buildSection([
            _buildItem(
              title: '外挂记录',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentRole.attachedJsonContent != null
                        ? '已导入 (${_currentRole.attachedJsonContent!.length} 字)'
                        : '未导入',
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _showAttachedJsonOptions,
            ),
          ]),

          const SizedBox(height: 10),

          // 角色设置入口
          _buildSection([
            _buildItem(
              title: '角色设置',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentRole.name,
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                ],
              ),
              onTap: _openRoleSettings,
            ),
          ]),

          const SizedBox(height: 10),

          // 清空聊天记录
          _buildSection([
            _buildItem(
              title: '清空聊天记录',
              titleColor: const Color(0xFFFA5151),
              onTap: _confirmClearHistory,
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

  Widget _buildAvatarItem() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          _buildAvatar(),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.chatName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '角色: ${_currentRole.name}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final colors = [
      const Color(0xFF7EB7E7),
      const Color(0xFF95EC69),
      const Color(0xFFFFB347),
      const Color(0xFFFF7B7B),
      const Color(0xFFB19CD9),
    ];
    final colorIndex = _currentRole.name.hashCode.abs() % colors.length;

    if (_currentRole.avatarUrl != null && _currentRole.avatarUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          _currentRole.avatarUrl!,
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildDefaultAvatar(colors[colorIndex]),
        ),
      );
    }
    return _buildDefaultAvatar(colors[colorIndex]);
  }

  Widget _buildDefaultAvatar(Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 60,
        height: 60,
        color: color,
        child: Center(
          child: Text(
            _currentRole.name.isNotEmpty
                ? _currentRole.name[0].toUpperCase()
                : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
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
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _buildQuietTimeItem() {
    final settings = TaskService.getQuietTimeSettings();
    final enabled = settings['enabled'] as bool;
    final start = settings['start_hour'] as int;
    final end = settings['end_hour'] as int;

    return InkWell(
      onTap: _showQuietTimePicker,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('安静时间', style: TextStyle(fontSize: 16)),
                if (enabled)
                  Text(
                    '$start:00 - $end:00',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                    ),
                  ),
              ],
            ),
            Switch(
              value: enabled,
              activeColor: const Color(0xFF07C160),
              onChanged: (value) {
                TaskService.setQuietTime(
                  enabled: value,
                  startHour: start,
                  endHour: end,
                );
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showQuietTimePicker() async {
    final settings = TaskService.getQuietTimeSettings();
    int startHour = settings['start_hour'] as int;
    int endHour = settings['end_hour'] as int;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: Text(
                        '设置安静时间',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 开始时间
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('开始时间', style: TextStyle(fontSize: 16)),
                        GestureDetector(
                          onTap: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(
                                hour: startHour,
                                minute: 0,
                              ),
                            );
                            if (time != null) {
                              setModalState(() {
                                startHour = time.hour;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$startHour:00',
                              style: const TextStyle(
                                fontSize: 16,
                                color: Color(0xFF07C160),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 结束时间
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('结束时间', style: TextStyle(fontSize: 16)),
                        GestureDetector(
                          onTap: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(hour: endHour, minute: 0),
                            );
                            if (time != null) {
                              setModalState(() {
                                endHour = time.hour;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$endHour:00',
                              style: const TextStyle(
                                fontSize: 16,
                                color: Color(0xFF07C160),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // 确定按钮
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          TaskService.setQuietTime(
                            enabled: true,
                            startHour: startHour,
                            endHour: endHour,
                          );
                          Navigator.pop(context);
                          setState(() {});
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('确定', style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

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
            // 使用 MessageStore 获取消息
            final currentMessages = MessageStore.instance.getMessages(
              widget.chatId,
            );

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
                            '聊天记录 (${currentMessages.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (currentMessages.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await MessageStore.instance.clearMessages(
                                  widget.chatId,
                                );
                                MemoryService.clearShortTermMemory(
                                  widget.chatId,
                                );
                                setModalState(() {});
                                widget.onClearHistory?.call();
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
                      child: currentMessages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无聊天记录',
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: currentMessages.length,
                              itemBuilder: (context, index) {
                                final msg = currentMessages[index];
                                return _buildMessageItem(msg, setModalState);
                              },
                            ),
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
    return Dismissible(
      key: Key(msg.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        // 添加二次确认
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除消息'),
            content: const Text('确定要删除这条消息吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await MessageStore.instance.deleteMessage(widget.chatId, msg.id);
          setModalState(() {});
          // 注意：这里不要调用 onClearHistory，因为那会清空所有消息
        }
        return false; // 不自动移除，手动刷新列表
      },
      child: ListTile(
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
      ),
    );
  }

  /// 显示消息全文
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
              isSender ? '我' : _currentRole.name,
              style: const TextStyle(fontSize: 16),
            ),
            const Spacer(),
            Text(
              '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
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

  void _showCoreMemory() {
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
            // 使用角色的核心记忆
            final memories = _currentRole.coreMemory;

            return DraggableScrollableSheet(
              initialChildSize: 0.6,
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
                            '核心记忆 (${memories.length} 条)',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => _addCoreMemory(setModalState),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加'),
                              ),
                              if (memories.isNotEmpty)
                                TextButton(
                                  onPressed: () async {
                                    _currentRole = _currentRole
                                        .clearCoreMemory();
                                    await RoleService.updateRole(_currentRole);
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
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: memories.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无核心记忆\n点击"添加"来创建',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: memories.length,
                              itemBuilder: (context, index) {
                                return ListTile(
                                  title: Text(memories[index]),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          color: Color(0xFF888888),
                                        ),
                                        onPressed: () => _editCoreMemory(
                                          index,
                                          memories[index],
                                          setModalState,
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                        ),
                                        onPressed: () async {
                                          _currentRole = _currentRole
                                              .removeCoreMemory(index);
                                          await RoleService.updateRole(
                                            _currentRole,
                                          );
                                          setModalState(() {});
                                          setState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
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

  void _addCoreMemory(StateSetter setModalState) async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加核心记忆'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '例如：用户喜欢编程',
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
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _currentRole = _currentRole.addCoreMemory(result);
      await RoleService.updateRole(_currentRole);
      setModalState(() {});
      setState(() {});
    }
  }

  void _editCoreMemory(
    int index,
    String oldMemory,
    StateSetter setModalState,
  ) async {
    final controller = TextEditingController(text: oldMemory);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑核心记忆'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != oldMemory) {
      // 移除旧的，添加新的
      var role = _currentRole.removeCoreMemory(index);
      final newMemory = List<String>.from(role.coreMemory);
      newMemory.insert(index, result);
      _currentRole = role.copyWith(coreMemory: newMemory);
      await RoleService.updateRole(_currentRole);
      setModalState(() {});
      setState(() {});
    }
  }

  /// 编辑核心记忆总结轮数（角色独立）
  void _editMemoryRounds() async {
    int value = _currentRole.summaryEveryNRounds;

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
      // 更新角色的总结轮数（角色独立设置）
      _currentRole = _currentRole.copyWith(summaryEveryNRounds: result);
      await RoleService.updateRole(_currentRole);
      setState(() {});
    }
  }

  void _confirmClearHistory() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: const Text('确定要清空所有聊天记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await MessageStore.instance.clearMessages(widget.chatId);
              MemoryService.clearShortTermMemory(widget.chatId);
              widget.onClearHistory?.call();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _openRoleSettings() async {
    final result = await Navigator.push<Role>(
      context,
      MaterialPageRoute(
        builder: (context) => RoleSettingsPage(role: _currentRole),
      ),
    );
    if (result != null) {
      await RoleService.updateRole(result);
      setState(() {
        _currentRole = result;
      });
      widget.onRoleChanged?.call();
    }
  }

  void _openTaskManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TaskManagerPage(roleId: widget.chatId, roleName: _currentRole.name),
      ),
    ).then((_) => setState(() {})); // 刷新任务数量
  }

  // ========== 主动消息配置方法 ==========

  Future<void> _toggleProactiveMessage(bool enabled) async {
    _currentRole = _currentRole.copyWith(
      proactiveConfig: _currentRole.proactiveConfig.copyWith(enabled: enabled),
    );
    await RoleService.updateRole(_currentRole);

    // 从 RoleService 重新加载确认保存成功
    final saved = RoleService.getRoleById(_currentRole.id);
    if (saved != null) {
      _currentRole = saved;
    }

    // 通知调度器
    ProactiveMessageScheduler.instance.onRoleConfigChanged(_currentRole.id);

    if (mounted) setState(() {});
  }

  Future<void> _editProactivePrompt() async {
    final controller = TextEditingController(
      text: _currentRole.proactiveConfig.triggerPrompt,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('触发提示词'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '例如：请你模拟角色，给用户发消息...',
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
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null) {
      _currentRole = _currentRole.copyWith(
        proactiveConfig: _currentRole.proactiveConfig.copyWith(
          triggerPrompt: result,
        ),
      );
      await RoleService.updateRole(_currentRole);

      // 从 RoleService 重新加载确认保存成功
      final saved = RoleService.getRoleById(_currentRole.id);
      if (saved != null) {
        _currentRole = saved;
      }

      if (mounted) setState(() {});
    }
  }

  Future<void> _editProactiveCountdown() async {
    double min = _currentRole.proactiveConfig.minCountdownHours;
    double max = _currentRole.proactiveConfig.maxCountdownHours;

    final result = await showDialog<Map<String, double>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('倒计时区间'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI 在此区间内随机选择触发时间'),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('最小：'),
                  Expanded(
                    child: Slider(
                      value: min,
                      min: 0.5,
                      max: 12,
                      divisions: 23,
                      label: '${min.toStringAsFixed(1)} 小时',
                      onChanged: (v) => setState(() {
                        min = v;
                        if (max < min) max = min;
                      }),
                    ),
                  ),
                  Text('${min.toStringAsFixed(1)}h'),
                ],
              ),
              Row(
                children: [
                  const Text('最大：'),
                  Expanded(
                    child: Slider(
                      value: max,
                      min: min,
                      max: 24,
                      divisions: 47,
                      label: '${max.toStringAsFixed(1)} 小时',
                      onChanged: (v) => setState(() => max = v),
                    ),
                  ),
                  Text('${max.toStringAsFixed(1)}h'),
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
              onPressed: () => Navigator.pop(context, {'min': min, 'max': max}),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      _currentRole = _currentRole.copyWith(
        proactiveConfig: _currentRole.proactiveConfig.copyWith(
          minCountdownHours: result['min'],
          maxCountdownHours: result['max'],
        ),
      );
      await RoleService.updateRole(_currentRole);

      // 从 RoleService 重新加载确认保存成功
      final saved = RoleService.getRoleById(_currentRole.id);
      if (saved != null) {
        _currentRole = saved;
      }

      ProactiveMessageScheduler.instance.onRoleConfigChanged(_currentRole.id);
      if (mounted) setState(() {});
    }
  }

  /// 导入外挂 JSON 文件
  void _importJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();

      if (content.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('文件内容为空')));
        }
        return;
      }

      // 更新角色
      final updated = _currentRole.copyWith(attachedJsonContent: content);
      await RoleService.updateRole(updated);
      setState(() {
        _currentRole = updated;
      });
      widget.onRoleChanged?.call();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入 ${content.length} 字的记录')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  /// 清除外挂 JSON
  void _clearAttachedJson() async {
    final updated = _currentRole.copyWith(attachedJsonContent: '');
    // 设为空字符串后再设为 null
    final cleared = Role(
      id: updated.id,
      name: updated.name,
      description: updated.description,
      systemPrompt: updated.systemPrompt,
      avatarUrl: updated.avatarUrl,
      temperature: updated.temperature,
      topP: updated.topP,
      frequencyPenalty: updated.frequencyPenalty,
      presencePenalty: updated.presencePenalty,
      maxContextRounds: updated.maxContextRounds,
      allowWebSearch: updated.allowWebSearch,
      coreMemory: updated.coreMemory,
      summaryEveryNRounds: updated.summaryEveryNRounds,
      proactiveConfig: updated.proactiveConfig,
      stickerConfig: updated.stickerConfig,
    );
    await RoleService.updateRole(cleared);
    setState(() {
      _currentRole = cleared;
    });
    widget.onRoleChanged?.call();
  }

  /// 显示外挂 JSON 选项
  void _showAttachedJsonOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_upload),
              title: const Text('导入 JSON 文件'),
              subtitle: const Text('选择 .json 或 .txt 文件作为外挂记录'),
              onTap: () {
                Navigator.pop(ctx);
                _importJsonFile();
              },
            ),
            if (_currentRole.attachedJsonContent != null) ...[
              ListTile(
                leading: const Icon(Icons.visibility),
                title: const Text('查看内容'),
                subtitle: Text('${_currentRole.attachedJsonContent!.length} 字'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAttachedJsonContent();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  '清除外挂记录',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _clearAttachedJson();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 显示外挂 JSON 内容
  void _showAttachedJsonContent() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.7,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '外挂记录内容',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '共 ${_currentRole.attachedJsonContent?.length ?? 0} 字（只读）',
              style: const TextStyle(color: Color(0xFF888888), fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _currentRole.attachedJsonContent ?? '',
                  style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
