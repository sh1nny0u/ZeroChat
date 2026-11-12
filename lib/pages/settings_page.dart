import 'memory_management_page.dart';
import 'about_page.dart';
import 'behavior_settings_page.dart';
import 'account_page.dart';
import 'data_management_page.dart';
import '../widgets/resource_image.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/image_service.dart';
import '../services/data_export_service.dart';
import '../services/diagnostics_service.dart';

/// 设置页面
/// 整合背景设置等功能
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _exporting = false;

  Future<void> _exportData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出私密数据'),
        content: const Text(
          '备份包含当前服务器账号的本机聊天、角色、记忆、设置、应用内图片和表情包，不包含供应商密钥或登录凭证。'
          '请存到私人目录，勿上传或发给他人。外部文件及网络缓存不包含在内。'
          '导出期间请留在本页，避免其他设备写入。当前支持隔离恢复验证，尚不支持直接导回应用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择保存位置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _exporting = true);
    try {
      final saved = await DataExportService.exportToFile();
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('数据已导出，请妥善保管备份文件')));
      }
    } catch (error) {
      DiagnosticsService.event(
        'migration',
        'client_export_failed',
        error: error,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('数据导出失败，原数据未改动，请手动重试'),
            action: SnackBarAction(label: '重试', onPressed: _exportData),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          _buildSection([
            ListTile(
              leading: const Icon(Icons.security),
              title: const Text('账号与设备'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountPage()),
              ),
            ),
            const Divider(height: 1, thickness: .5, indent: 16),
            ListTile(
              leading: const Icon(Icons.nights_stay_outlined),
              title: const Text('自主行为与预算'),
              trailing: const Icon(Icons.chevron_right),
              subtitle: const Text('安静时段、频率、调用与每日用量'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BehaviorSettingsPage()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('记忆管理'),
              subtitle: const Text('分类、分域、修正、待验证与共享控制'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MemoryManagementPage()),
              ),
            ),
          ]),
          _buildSectionHeader('数据保护'),
          _buildSection([
            ListTile(
              leading: const Icon(Icons.cloud_sync),
              title: const Text('数据同步与备份'),
              subtitle: const Text('迁移报告、修改冲突、创建、下载及恢复'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DataManagementPage()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(_exporting ? '正在导出…' : '导出本机数据'),
              subtitle: const Text('本机保护副本，不含供应商密钥和登录凭证'),
              enabled: !_exporting,
              onTap: _exporting ? null : _exportData,
            ),
          ]),
          const SizedBox(height: 20),

          // 背景设置
          _buildSectionHeader('背景'),
          _buildSection([
            _buildImageItem(
              title: '朋友圈封面',
              currentPath: SettingsService.instance.coverImageUrl,
              onSelect: () => _selectImage('cover'),
            ),
            const Divider(height: 1, indent: 16),
            _buildImageItem(
              title: '聊天背景',
              currentPath: SettingsService.instance.chatBackgroundUrl,
              onSelect: () => _selectImage('background'),
            ),
          ]),

          const SizedBox(height: 20),

          // 消息等待时间设置
          _buildSectionHeader('消息发送'),
          _buildSection([_buildWaitIntervalItem()]),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '消息等待时间：点击发送后等待指定秒数，输入保留在编辑框，可继续编辑合并。再次发送会重新计时，也可立即发送。设为 0 表示立即发送。',
              style: TextStyle(color: Color(0xFF888888), fontSize: 12),
            ),
          ),

          const SizedBox(height: 20),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '点击设置背景图片，支持从相册选择本地图片。',
              style: TextStyle(color: Color(0xFF888888), fontSize: 12),
            ),
          ),
          ListTile(
            title: const Text('关于 ZeroChat'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建等待时间设置项
  Widget _buildWaitIntervalItem() {
    final seconds = SettingsService.instance.messageWaitSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('等待时间', style: TextStyle(fontSize: 16)),
              Text(
                seconds == 0 ? '立即发送' : '$seconds 秒',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0xFF07C160),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF07C160),
              inactiveTrackColor: const Color(0xFFE0E0E0),
              thumbColor: const Color(0xFF07C160),
              overlayColor: const Color(0x2007C160),
              trackHeight: 4,
            ),
            child: Slider(
              value: seconds.toDouble(),
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: (value) async {
                await SettingsService.instance.updateMessageWaitSeconds(
                  value.round(),
                );
                if (mounted) setState(() {});
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                '0',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
              Text(
                '10秒',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title,
        style: const TextStyle(color: Color(0xFF888888), fontSize: 13),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildImageItem({
    required String title,
    required String currentPath,
    required VoidCallback onSelect,
  }) {
    return InkWell(
      onTap: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
            if (currentPath.isNotEmpty)
              _buildPreview(currentPath)
            else
              _buildPlaceholder(),
            const SizedBox(width: 8),
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

  Widget _buildPreview(String path) {
    if (ImageService.isLocalPath(path)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildBrokenImage(),
        ),
      );
    } else {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ResourceImage(
          path,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildBrokenImage(),
        ),
      );
    }
  }

  Widget _buildBrokenImage() {
    return Container(
      width: 40,
      height: 40,
      color: const Color(0xFFEEEEEE),
      child: const Icon(Icons.broken_image, size: 20, color: Color(0xFFAAAAAA)),
    );
  }

  Widget _buildPlaceholder() {
    return const Text(
      '未设置',
      style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
    );
  }

  void _selectImage(String type) {
    final currentPath = type == 'cover'
        ? SettingsService.instance.coverImageUrl
        : SettingsService.instance.chatBackgroundUrl;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: Color(0xFF07C160),
              ),
              title: const Text('从相册选择'),
              onTap: () async {
                Navigator.pop(ctx);
                final path = await ImageService.instance.pickImage();
                if (path != null) {
                  await _saveImagePath(type, path);
                }
              },
            ),
            if (currentPath.isNotEmpty) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('清除'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _saveImagePath(type, '');
                },
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImagePath(String type, String path) async {
    if (type == 'cover') {
      await SettingsService.instance.updateDisplaySettings(coverImageUrl: path);
    } else {
      await SettingsService.instance.updateDisplaySettings(
        chatBackgroundUrl: path,
      );
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(type == 'cover' ? '朋友圈封面已更新' : '聊天背景已更新'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }
}
