import '../services/session_service.dart';
import '../widgets/resource_image.dart';
import '../services/diagnostics_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../services/backend_http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../services/settings_service.dart';
import 'api_settings_page.dart';
import 'global_prompts_page.dart';
import 'favorites_page.dart';
import 'settings_page.dart';

/// "我"页面
/// ZeroChat 风格的个人中心和全局设置
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: ListView(
        children: [
          // 用户信息卡片
          _buildProfileCard(),

          const SizedBox(height: 10),

          // API 设置
          _buildSection([
            _buildItem(
              icon: Icons.cloud_outlined,
              iconColor: const Color(0xFF07C160),
              title: 'AI 接口设置',
              subtitle: _getApiStatusText(),
              onTap: () => _navigateTo(const ApiSettingsPage()),
            ),
          ]),

          const SizedBox(height: 10),

          // 全局提示词
          _buildSection([
            _buildItem(
              icon: Icons.edit_note,
              iconColor: const Color(0xFFFFB347),
              title: '全局提示词',
              subtitle: 'Base / Group / Memory',
              onTap: () => _navigateTo(const GlobalPromptsPage()),
            ),
          ]),

          const SizedBox(height: 10),

          // 收藏
          _buildSection([
            _buildItem(
              icon: Icons.star_border,
              iconColor: const Color(0xFFFFAA00),
              title: '收藏',
              subtitle: '查看已收藏的消息',
              onTap: () => _navigateTo(const FavoritesPage()),
            ),
          ]),

          const SizedBox(height: 10),

          // 设置
          _buildSection([
            _buildItem(
              icon: Icons.settings_outlined,
              iconColor: const Color(0xFF888888),
              title: '设置',
              subtitle: '背景等',
              onTap: () => _navigateTo(const SettingsPage()),
            ),
          ]),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    final settings = SettingsService.instance;
    return InkWell(
      onTap: _editProfile,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            // 头像
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: settings.userAvatarUrl.isNotEmpty
                  ? ResourceImage(
                      settings.userAvatarUrl.startsWith('http')
                          ? settings.userAvatarUrl
                          : '${settings.backendUrl}${settings.userAvatarUrl}',
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultAvatar(),
                    )
                  : _buildDefaultAvatar(),
            ),
            const SizedBox(width: 16),
            // 用户信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    settings.userNickname,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '点击编辑个人信息',
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              color: Color(0xFFCCCCCC),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Container(
      width: 64,
      height: 64,
      color: const Color(0xFF07C160),
      child: const Center(
        child: Icon(Icons.person, color: Colors.white, size: 36),
      ),
    );
  }

  void _editProfile() async {
    final generation = SessionService.instance.generation;
    final nicknameController = TextEditingController(
      text: SettingsService.instance.userNickname,
    );
    String? selectedImagePath;
    String currentAvatarUrl = SettingsService.instance.userAvatarUrl;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑个人信息'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像选择
              GestureDetector(
                onTap: () async {
                  final picker = ImagePicker();
                  final image = await picker.pickImage(
                    source: ImageSource.gallery,
                    maxWidth: 512,
                    maxHeight: 512,
                  );
                  if (image != null) {
                    setDialogState(() {
                      selectedImagePath = image.path;
                    });
                  }
                },
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: selectedImagePath != null
                        ? Image.file(
                            File(selectedImagePath!),
                            fit: BoxFit.cover,
                          )
                        : (currentAvatarUrl.isNotEmpty
                              ? ResourceImage(
                                  currentAvatarUrl.startsWith('http')
                                      ? currentAvatarUrl
                                      : '${SettingsService.instance.backendUrl}$currentAvatarUrl',
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.add_a_photo,
                                    size: 32,
                                    color: Colors.grey,
                                  ),
                                )
                              : const Icon(
                                  Icons.add_a_photo,
                                  size: 32,
                                  color: Colors.grey,
                                )),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '点击选择头像',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nicknameController,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      if (!mounted || generation != SessionService.instance.generation) return;
      String? newAvatarUrl;

      // 上传头像到后端
      if (selectedImagePath != null) {
        try {
          final backendUrl = SettingsService.instance.backendUrl;
          final uri = Uri.parse('$backendUrl/api/settings/avatar');
          final request = http.MultipartRequest('POST', uri);
          request.files.add(
            await http.MultipartFile.fromPath(
              'file',
              selectedImagePath!,
              contentType: MediaType('image', 'jpeg'),
            ),
          );
          final response = await http.upload(request);
          if (response.statusCode == 200) {
            final respStr = response.body;
            // 解析 JSON 响应
            if (respStr.contains('"path"')) {
              final match = RegExp(
                r'"path"\s*:\s*"([^"]+)"',
              ).firstMatch(respStr);
              if (match != null) {
                newAvatarUrl = match.group(1);
              }
            }
            DiagnosticsService.event('chat', 'legacy_event');
          } else {
            throw StateError('头像上传失败（${response.statusCode}）');
          }
        } catch (e) {
          DiagnosticsService.event('chat', 'legacy_event', error: e);
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('头像上传失败，请恢复连接后手动重试')));
          return;
        }
      }

      if (!mounted || generation != SessionService.instance.generation) return;
      await SettingsService.instance.updateUserProfile(
        nickname: nicknameController.text.isNotEmpty
            ? nicknameController.text
            : null,
        avatarUrl: newAvatarUrl ?? currentAvatarUrl,
      );
    }
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              color: Color(0xFFCCCCCC),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  String _getApiStatusText() {
    final settings = SettingsService.instance;
    final parts = <String>[];

    if (settings.chatApiConfigured) {
      parts.add('聊天已配置');
    }
    if (settings.intentEnabled && settings.intentApiConfigured) {
      parts.add('意图已配置');
    }
    if (settings.visionEnabled && settings.visionApiConfigured) {
      parts.add('视觉已配置');
    }

    return parts.isEmpty ? '未配置' : parts.join(' · ');
  }

  void _navigateTo(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }
}
