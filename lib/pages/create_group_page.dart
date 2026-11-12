import '../widgets/resource_image.dart';
import 'package:flutter/material.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import '../services/chat_list_service.dart';

/// 创建群聊页面
/// 选择多个角色创建群聊
class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final Set<String> _selectedIds = {};
  final TextEditingController _nameController = TextEditingController();
  List<Role> _roles = [];

  @override
  void initState() {
    super.initState();
    _roles = RoleService.getAllRoles();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('发起群聊'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          TextButton(
            onPressed: _selectedIds.length >= 2 ? _createGroup : null,
            child: Text(
              '完成(${_selectedIds.length})',
              style: TextStyle(
                color: _selectedIds.length >= 2
                    ? const Color(0xFF07C160)
                    : const Color(0xFFCCCCCC),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 群名称输入
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '群聊名称',
                hintText: '选填，默认为成员名称组合',
                border: OutlineInputBorder(),
              ),
            ),
          ),

          const SizedBox(height: 10),

          // 提示
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '选择至少 2 个角色创建群聊',
              style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
          ),

          // 角色列表
          Expanded(
            child: ListView.builder(
              itemCount: _roles.length,
              itemBuilder: (context, index) {
                final role = _roles[index];
                final isSelected = _selectedIds.contains(role.id);

                return Material(
                  color: Colors.white,
                  child: CheckboxListTile(
                    value: isSelected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedIds.add(role.id);
                        } else {
                          _selectedIds.remove(role.id);
                        }
                      });
                    },
                    activeColor: const Color(0xFF07C160),
                    secondary: _buildAvatar(role),
                    title: Text(role.name),
                    subtitle: role.description.isNotEmpty
                        ? Text(
                            role.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                  ),
                );
              },
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

    if (role.avatarUrl != null && role.avatarUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ResourceImage(
          role.avatarUrl!,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              _buildDefaultAvatar(role, colors[colorIndex]),
        ),
      );
    }
    return _buildDefaultAvatar(role, colors[colorIndex]);
  }

  Widget _buildDefaultAvatar(Role role, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        color: color,
        child: Center(
          child: Text(
            role.name.isNotEmpty ? role.name[0].toUpperCase() : '?',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  void _createGroup() async {
    if (_selectedIds.length < 2) return;

    // 生成群名
    final selectedRoles = _roles
        .where((r) => _selectedIds.contains(r.id))
        .toList();
    final groupName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : selectedRoles.map((r) => r.name).take(3).join('、') +
              (_selectedIds.length > 3 ? '...' : '');

    // 创建群聊
    final group = await GroupChatService.createGroup(
      name: groupName,
      memberIds: _selectedIds.toList(),
    );

    // 添加到聊天列表
    ChatListService.instance.getOrCreateChat(
      id: group.id,
      name: group.name,
      isGroup: true,
      memberIds: group.memberIds,
    );

    if (mounted) {
      Navigator.pop(context, true);
    }
  }
}
