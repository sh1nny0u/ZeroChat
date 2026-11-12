import 'package:flutter/material.dart';
import '../services/moments_service.dart';

/// 发布朋友圈页面
class PublishMomentPage extends StatefulWidget {
  const PublishMomentPage({super.key});

  @override
  State<PublishMomentPage> createState() => _PublishMomentPageState();
}

class _PublishMomentPageState extends State<PublishMomentPage> {
  final TextEditingController _contentController = TextEditingController();
  bool _isPublishing = false;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            '取消',
            style: TextStyle(color: Color(0xFF000000), fontSize: 16),
          ),
        ),
        leadingWidth: 70,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              onPressed: _isPublishing ? null : _publish,
              style: TextButton.styleFrom(
                backgroundColor: _contentController.text.trim().isEmpty
                    ? const Color(0xFFCCCCCC)
                    : const Color(0xFF07C160),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: _isPublishing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '发表',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 输入区域
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _contentController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '这一刻的想法...',
                  hintStyle: TextStyle(color: Color(0xFFBBBBBB), fontSize: 16),
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 16, height: 1.5),
                onChanged: (value) => setState(() {}),
              ),
            ),
          ),
          // 底部工具栏
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // 表情（预留）
                IconButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请使用系统键盘输入表情')));
                  },
                  icon: const Icon(
                    Icons.emoji_emotions_outlined,
                    color: Color(0xFF888888),
                  ),
                ),
                // 图片（预留）
                IconButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前朋友圈仅支持文字，图片发布尚未开放')));
                  },
                  icon: const Icon(
                    Icons.image_outlined,
                    color: Color(0xFF888888),
                  ),
                ),
                const Spacer(),
                // 位置（预留）
                IconButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('位置分享尚未开放，不会读取或上传位置')));
                  },
                  icon: const Icon(
                    Icons.location_on_outlined,
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

  Future<void> _publish() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) return;

    setState(() => _isPublishing = true);

    try {
      await MomentsService.instance.publishPost(content: content);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error'),
        action: SnackBarAction(label: '重试', onPressed: _publish)));
    } finally { if (mounted) setState(() => _isPublishing = false); }
  }
}
