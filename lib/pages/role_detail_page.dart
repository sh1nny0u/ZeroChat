import '../services/session_service.dart';
import '../widgets/resource_image.dart';
import '../services/diagnostics_service.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/backend_http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../models/role.dart';
import '../services/role_service.dart';
import '../services/memory_service.dart';
import '../services/entity_sync_service.dart';
import '../services/chat_list_service.dart';
import '../services/settings_service.dart';
import 'role_settings_page.dart';
import 'chat_detail_page.dart';
import 'role_api_page.dart';
import 'role_share_page.dart';

/// 角色详情页面
/// 查看和编辑角色信息，开始聊天
class RoleDetailPage extends StatefulWidget {
  final Role role;

  const RoleDetailPage({super.key, required this.role});

  @override
  State<RoleDetailPage> createState() => _RoleDetailPageState();
}

class _RoleDetailPageState extends State<RoleDetailPage> {
  late Role _role;

  @override
  void initState() {
    super.initState();
    _role = widget.role;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          IconButton(
            onPressed: _editRole,
            icon: const Icon(Icons.more_horiz, size: 24),
          ),
        ],
      ),
      body: ListView(
        children: [
          // 头像和名称
          _buildHeader(),

          const SizedBox(height: 10),

          // 发消息按钮
          _buildSection([
            _buildActionButton(
              icon: Icons.chat_bubble_outline,
              label: '发消息',
              onTap: _startChat,
            ),
          ]),

          const SizedBox(height: 10),

          // 角色设置项
          ListTile(tileColor: Colors.white, title: const Text('角色聊天 API'), trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RoleApiPage(roleId: _role.id)))),
          ListTile(tileColor: Colors.white, title: const Text('分享角色好友码'), trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RoleSharePage(roleId: _role.id)))),
          _buildSection([
            _buildInfoItem('系统提示词', _role.systemPrompt, onTap: _editRole),
            _buildDivider(),
            _buildInfoItem('Temperature', _role.temperature.toStringAsFixed(2)),
            _buildDivider(),
            _buildInfoItem('上下文轮数', '${_role.maxContextRounds} 轮'),
          ]),

          const SizedBox(height: 10),

          // 删除按钮
          if (_role.id != 'default')
            _buildSection([
              InkWell(
                onTap: _confirmDelete,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      '删除角色',
                      style: TextStyle(color: Color(0xFFFA5151), fontSize: 16),
                    ),
                  ),
                ),
              ),
            ]),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // 头像（可点击修改）
          GestureDetector(
            onTap: _changeAvatar,
            child: Stack(
              children: [
                _buildAvatar(size: 80),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF07C160),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 名称
          Text(
            _role.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          if (_role.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _role.description,
                style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatar({double size = 80}) {
    if (_role.avatarUrl != null && _role.avatarUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ResourceImage(
          _role.avatarUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildDefaultAvatar(size: size),
        ),
      );
    }
    return _buildDefaultAvatar(size: size);
  }

  Widget _buildDefaultAvatar({double size = 80}) {
    final colors = [
      const Color(0xFF7EB7E7),
      const Color(0xFF95EC69),
      const Color(0xFFFFB347),
      const Color(0xFFFF7B7B),
      const Color(0xFFB19CD9),
    ];
    final colorIndex = _role.name.hashCode.abs() % colors.length;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: colors[colorIndex],
        child: Center(
          child: Text(
            _role.name.isNotEmpty ? _role.name[0].toUpperCase() : '?',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.4,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(0xFF07C160), size: 22),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 16, color: Color(0xFF07C160)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(label, style: const TextStyle(fontSize: 16)),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontSize: 15, color: Color(0xFF888888)),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: Color(0xFFCCCCCC),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, indent: 16, endIndent: 0);
  }

  void _changeAvatar() async {
    final generation = SessionService.instance.generation;
    final picker = ImagePicker();

    // 弹出选择对话框
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择头像'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      final pickedFile = await picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );

      if (pickedFile == null || !mounted || generation != SessionService.instance.generation) return;

      // 显示上传中
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在上传头像...')));

      // 上传到后端
      final backendUrl = SettingsService.instance.backendUrl;
      if (backendUrl.isEmpty) {
        // 后端未配置，使用本地路径
        final localPath = pickedFile.path;
        final updatedRole = _role.copyWith(avatarUrl: localPath);
        await RoleService.updateRole(updatedRole);
        if (!mounted) return;
        setState(() => _role = updatedRole);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('头像已更新')));
        return;
      }

      // 上传到后端
      final uri = Uri.parse('$backendUrl/api/roles/${_role.id}/avatar/upload');
      final request = http.MultipartRequest('POST', uri);

      final bytes = await pickedFile.readAsBytes();
      final ext = pickedFile.path.split('.').last.toLowerCase();

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'avatar.$ext',
          contentType: MediaType('image', ext == 'jpg' ? 'jpeg' : ext),
        ),
      );

      final response = await http.upload(request);
      if (response.statusCode == 200) {
        final respStr = response.body;
        final data = jsonDecode(respStr);
        final avatarUrl = data['avatar_url'] as String?;

        if (avatarUrl != null) {
          await EntitySyncService.instance.pull();
          final updatedRole = RoleService.getRoleById(_role.id);
          if (updatedRole == null) throw StateError('目标角色已删除');
          if (!mounted) return;
          setState(() => _role = updatedRole);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('头像上传成功')));
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('上传失败: ${response.statusCode}')));
      }
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('上传错误: $e')));
    }
  }

  void _startChat() {
    // 设置当前角色
    RoleService.setCurrentRole(_role.id);

    // 添加到聊天列表
    ChatListService.instance.getOrCreateChat(
      id: _role.id,
      name: _role.name,
      avatarUrl: _role.avatarUrl,
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ChatDetailPage(chatId: _role.id, chatName: _role.name, isAI: true),
      ),
    );
  }

  void _editRole() async {
    final result = await Navigator.push<Role>(
      context,
      MaterialPageRoute(builder: (context) => RoleSettingsPage(role: _role)),
    );
    if (result != null) {
      try {
        await RoleService.updateRole(result);
        if (!mounted) return;
        setState(() { _role = RoleService.getRoleById(result.id) ?? result; });
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存未完成，请到设置 → 数据同步与备份处理冲突或重试')));
      }
    }
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除角色'),
        content: Text('确定要删除"${_role.name}"吗？将同步到其他设备，服务器保留保护副本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await RoleService.deleteRole(_role.id);
              MemoryService.clearShortTermMemory(_role.id);
              // 同时删除聊天记录
              ChatListService.instance.removeFromList(_role.id);
              if (mounted) {
                Navigator.pop(context); // 关闭对话框
                Navigator.pop(context, true); // 返回通讯录
              }
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
