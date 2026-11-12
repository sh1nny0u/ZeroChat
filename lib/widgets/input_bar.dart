import '../services/diagnostics_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// ZeroChat 风格输入栏组件
/// 用于聊天页面底部的消息输入区域
class InputBar extends StatefulWidget {
  final Function(String)? onSend;
  final Function(String imagePath)? onImageSend;
  final String? hintText;
  final String? draftKey;

  const InputBar({
    super.key,
    this.onSend,
    this.onImageSend,
    this.hintText,
    this.draftKey,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  bool _showSendButton = false;
  bool _sending = false;
  String? _failedDraft;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    if (widget.draftKey != null)
      _controller.text =
          StorageService.getString('draft_${widget.draftKey}') ?? '';
    _showSendButton = _controller.text.trim().isNotEmpty;
    if (widget.draftKey != null) {
      _failedDraft =
          StorageService.getString('failed_draft_${widget.draftKey}') ??
          StorageService.getString('pending_draft_${widget.draftKey}');
    }
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (widget.draftKey != null)
      unawaited(
        StorageService.setString('draft_${widget.draftKey}', _controller.text),
      );
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _showSendButton) {
      setState(() {
        _showSendButton = hasText;
      });
    }
  }

  Future<void> _handleSend() async {
    final seconds = SettingsService.instance.messageWaitSeconds;
    if (seconds > 0 && !_sending && _controller.text.trim().isNotEmpty) {
      _waitTimer?.cancel();
      _waitTimer = Timer(Duration(seconds: seconds), () {
        _waitTimer = null;
        _sendNow();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$seconds 秒后发送，期间可继续编辑合并输入'),
          action: SnackBarAction(
            label: '立即发送',
            onPressed: () {
              _waitTimer?.cancel();
              _waitTimer = null;
              _sendNow();
            },
          ),
        ),
      );
      return;
    }
    await _sendNow();
  }

  Future<void> _sendNow() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || widget.onSend == null) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      if (widget.draftKey != null) {
        await StorageService.setString(
          'pending_draft_${widget.draftKey}',
          text,
        );
      }
      final result = widget.onSend!.call(text);
      if (result is Future) await result;
      if (widget.draftKey != null) {
        await StorageService.remove('pending_draft_${widget.draftKey}');
      }
    } catch (error) {
      // Retain unconfirmed text even if the user has left this page.
      if (widget.draftKey != null) {
        await StorageService.setString('failed_draft_${widget.draftKey}', text);
        await StorageService.remove('pending_draft_${widget.draftKey}');
      }
      if (mounted) {
        if (_controller.text.isEmpty) {
          _controller.text = text;
          if (widget.draftKey != null) {
            await StorageService.remove('failed_draft_${widget.draftKey}');
          }
        } else {
          setState(() => _failedDraft = text);
        }
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('未能确认发送结果，原文已保留：$error'),
            action: SnackBarAction(
              label: '重试',
              onPressed: () {
                if (_controller.text.trim() == text) {
                  _handleSend();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('当前草稿已改变，请确认原文后手动发送')),
                  );
                }
              },
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 显示附件选项菜单
  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_sending)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    '正在等待后端与供应商回应，较慢模型可能需要数分钟',
                    style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                  ),
                ),
              // 拖拽指示器
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              // 选项网格
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildAttachmentOption(
                      icon: Icons.photo_library,
                      label: '相册',
                      color: const Color(0xFF07C160),
                      onTap: () => _pickImage(ImageSource.gallery),
                    ),
                    _buildAttachmentOption(
                      icon: Icons.camera_alt,
                      label: '拍照',
                      color: const Color(0xFF4A90D9),
                      onTap: () => _pickImage(ImageSource.camera),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 取消按钮
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  '取消',
                  style: TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 28, color: color),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context); // 关闭底部菜单

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null && widget.onImageSend != null) {
        try {
          final result = widget.onImageSend!(pickedFile.path);
          if (result is Future) await result;
        } catch (error) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('图片发送失败：$error'),
                action: SnackBarAction(
                  label: '重试',
                  onPressed: () async {
                    try {
                      final result = widget.onImageSend!(pickedFile.path);
                      if (result is Future) await result;
                    } catch (error) {
                      if (mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('图片发送失败：$error')),
                        );
                    }
                  },
                ),
              ),
            );
        }
      }
    } catch (e) {
      DiagnosticsService.event('chat', 'legacy_event', error: e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择图片失败: $e')));
      }
    }
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F7),
        border: Border(top: BorderSide(color: Color(0xFFD9D9D9), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_failedDraft != null)
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '上条消息未确认，原文已保留',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        _controller.text =
                            '${_failedDraft!}${_controller.text.isEmpty ? '' : '\n${_controller.text}'}';
                        setState(() => _failedDraft = null);
                        if (widget.draftKey != null) {
                          await StorageService.remove(
                            'failed_draft_${widget.draftKey}',
                          );
                          await StorageService.remove(
                            'pending_draft_${widget.draftKey}',
                          );
                        }
                      },
                      child: const Text('恢复原文'),
                    ),
                  ],
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 语音按钮
                  _buildIconButton(
                    Icons.keyboard_voice_outlined,
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('暂不支持录音发送，请使用文字或图片；收到的语音可点击播放'),
                        ),
                      );
                    },
                  ),

                  // 输入框
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: 36,
                        maxHeight: 120,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: const Color(0xFFDCDCDC),
                          width: 0.5,
                        ),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _handleSend(),
                        style: const TextStyle(
                          fontSize: 17,
                          color: Color(0xFF000000),
                        ),
                        decoration: InputDecoration(
                          hintText: widget.hintText ?? '',
                          hintMaxLines: 4,
                          hintStyle: const TextStyle(
                            color: Color(0xFFBBBBBB),
                            fontSize: 17,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),

                  // 表情按钮
                  _buildIconButton(
                    Icons.emoji_emotions_outlined,
                    onPressed: () {
                      _focusNode.requestFocus();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('请使用系统键盘输入表情；角色表情在聊天设置中管理'),
                        ),
                      );
                    },
                  ),

                  // 发送按钮或更多按钮
                  if (_showSendButton)
                    _buildSendButton()
                  else if (_sending)
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: Padding(
                        padding: EdgeInsets.all(9),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    _buildIconButton(
                      Icons.add_circle_outline,
                      onPressed: _showAttachmentMenu,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton(IconData icon, {VoidCallback? onPressed}) {
    return SizedBox(
      width: 40,
      height: 36,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 28, color: const Color(0xFF181818)),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildSendButton() {
    return GestureDetector(
      onTap: _sending
          ? () => ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('上一条消息正在处理中，当前草稿已保留')))
          : _handleSend,
      child: Container(
        width: 56,
        height: 36,
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF07C160),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(
          child: Text(
            '发送',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
