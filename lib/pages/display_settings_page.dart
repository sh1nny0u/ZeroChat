import '../widgets/resource_image.dart';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// 显示设置页面
/// 朋友圈封面、聊天背景设置
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  final TextEditingController _coverController = TextEditingController();
  final TextEditingController _backgroundController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _coverController.text = SettingsService.instance.coverImageUrl;
    _backgroundController.text = SettingsService.instance.chatBackgroundUrl;
  }

  @override
  void dispose() {
    _coverController.dispose();
    _backgroundController.dispose();
    super.dispose();
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
          '显示设置',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 朋友圈封面
          _buildSection(
            title: '朋友圈封面',
            children: [
              _buildImageSetting(
                label: '封面图片 URL',
                controller: _coverController,
                onSave: () => _saveCover(),
                previewUrl: SettingsService.instance.coverImageUrl,
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 聊天背景
          _buildSection(
            title: '聊天背景',
            children: [
              _buildImageSetting(
                label: '背景图片 URL',
                controller: _backgroundController,
                onSave: () => _saveBackground(),
                previewUrl: SettingsService.instance.chatBackgroundUrl,
              ),
            ],
          ),

          const SizedBox(height: 20),

          // 说明
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '提示：输入图片 URL 后点击保存，设置将立即生效并持久化保存。',
              style: TextStyle(color: Color(0xFF888888), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildImageSetting({
    required String label,
    required TextEditingController controller,
    required VoidCallback onSave,
    required String previewUrl,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: label,
                    hintStyle: const TextStyle(color: Color(0xFFBBBBBB)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: onSave,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF07C160),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
        // 预览
        if (previewUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ResourceImage(
                previewUrl,
                height: 100,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 100,
                  width: double.infinity,
                  color: const Color(0xFFEEEEEE),
                  child: const Center(
                    child: Text(
                      '图片加载失败',
                      style: TextStyle(color: Color(0xFF888888)),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _saveCover() async {
    await SettingsService.instance.updateDisplaySettings(
      coverImageUrl: _coverController.text.trim(),
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('朋友圈封面已保存'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _saveBackground() async {
    await SettingsService.instance.updateDisplaySettings(
      chatBackgroundUrl: _backgroundController.text.trim(),
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('聊天背景已保存'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }
}
