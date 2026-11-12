import '../widgets/resource_image.dart';
import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import '../services/group_chat_service.dart';
import 'role_detail_page.dart';
import 'group_settings_page.dart';
import 'role_share_page.dart';

/// 通讯录页面
/// ZeroChat 风格，显示所有 AI 角色，按字母排序
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => ContactsPageState();
}

class ContactsPageState extends State<ContactsPage>
    with WidgetsBindingObserver {
  List<Role> _roles = [];
  Map<String, List<Role>> _groupedRoles = {};
  List<String> _indexLetters = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RoleService.changes.addListener(_loadRoles);
    _loadRoles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RoleService.changes.removeListener(_loadRoles);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadRoles();
    }
  }

  // 公开刷新方法供外部调用
  void refresh() {
    _loadRoles();
  }

  void _loadRoles() {
    final roles = RoleService.getAllRoles();
    // 按名称首字母分组
    final Map<String, List<Role>> grouped = {};

    for (final role in roles) {
      final firstChar = _getFirstLetter(role.name);
      grouped[firstChar] ??= [];
      grouped[firstChar]!.add(role);
    }

    // 排序
    final sortedKeys = grouped.keys.toList()..sort();
    final sortedGrouped = <String, List<Role>>{};
    for (final key in sortedKeys) {
      sortedGrouped[key] = grouped[key]!
        ..sort((a, b) => a.name.compareTo(b.name));
    }

    if (mounted) {
      setState(() {
        _roles = roles;
        _groupedRoles = sortedGrouped;
        _indexLetters = sortedKeys;
      });
    }
  }

  String _getFirstLetter(String name) {
    if (name.isEmpty) return '#';
    final first = name[0].toUpperCase();
    // 检查是否是英文字母
    if (RegExp(r'[A-Z]').hasMatch(first)) {
      return first;
    }
    // 中文拼音首字母
    try {
      final pinyin = PinyinHelper.getFirstWordPinyin(name);
      if (pinyin.isNotEmpty) {
        final pinyinFirst = pinyin[0].toUpperCase();
        if (RegExp(r'[A-Z]').hasMatch(pinyinFirst)) {
          return pinyinFirst;
        }
      }
    } catch (_) {}
    return '#';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: Column(
        children: [
          // 群聊入口
          _buildGroupChatEntry(),
          ListTile(leading: const Icon(Icons.person_add_alt), title: const Text('输入好友码导入角色'), trailing: const Icon(Icons.chevron_right, color: Color(0xFFBBBBBB)),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const RoleSharePage()));
              _loadRoles();
            }),
          // 角色列表
          Expanded(
            child: _roles.isEmpty
                ? _buildEmptyState()
                : Stack(children: [_buildContactsList(), _buildIndexBar()]),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChatEntry() {
    final groups = GroupChatService.getAllGroups();
    return Container(
      color: Colors.white,
      child: InkWell(
        onTap: _showGroupChats,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF07C160),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.group, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('群聊', style: TextStyle(fontSize: 16))),
              Text(
                '${groups.length} 个',
                style: const TextStyle(color: Color(0xFF888888), fontSize: 14),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: Color(0xFFCCCCCC),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGroupChats() {
    final groups = GroupChatService.getAllGroups();

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
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '群聊列表',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              if (groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '暂无群聊',
                    style: TextStyle(color: Color(0xFF888888)),
                  ),
                )
              else
                ...groups.map(
                  (group) => ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFB347),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.group,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    title: Text(group.name),
                    subtitle: Text('${group.memberIds.length} 人'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => GroupSettingsPage(groupId: group.id),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无角色', style: TextStyle(fontSize: 16, color: Colors.grey[500])),
          const SizedBox(height: 8),
          Text(
            '点击右上角 + 添加角色',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildContactsList() {
    return ListView.builder(
      itemCount: _indexLetters.length,
      itemBuilder: (context, sectionIndex) {
        final letter = _indexLetters[sectionIndex];
        final rolesInSection = _groupedRoles[letter]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 分组标题
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: const Color(0xFFEDEDED),
              child: Text(
                letter,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF888888),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // 角色列表
            ...rolesInSection.map((role) => _buildContactItem(role)),
          ],
        );
      },
    );
  }

  Widget _buildContactItem(Role role) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _openRoleDetail(role),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFFEEEEEE), width: 0.5),
            ),
          ),
          child: Row(
            children: [
              // 头像
              _buildAvatar(role),
              const SizedBox(width: 12),
              // 名称和描述
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (role.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          role.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

  Widget _buildIndexBar() {
    return Positioned(
      right: 4,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _indexLetters.map((letter) {
              return GestureDetector(
                onTap: () {
                  // TODO: 滚动到对应位置
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    letter,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF888888),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _openRoleDetail(Role role) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => RoleDetailPage(role: role)),
    );
    // 返回后刷新列表
    if (result == true || result == null) {
      _loadRoles();
    }
  }
}
