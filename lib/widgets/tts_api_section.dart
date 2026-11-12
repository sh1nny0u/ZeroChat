import 'package:flutter/material.dart';
import '../pages/tts_settings_page.dart';
import '../services/tts_service.dart';

/// The global voice switch lives beside the other AI provider settings.
class TtsApiSection extends StatefulWidget {
  const TtsApiSection({super.key});
  @override
  State<TtsApiSection> createState() => _TtsApiSectionState();
}

class _TtsApiSectionState extends State<TtsApiSection> {
  Map<String, dynamic>? _data;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await TtsService.load(null);
      if (mounted)
        setState(() {
          _data = data;
          _error = null;
        });
    } catch (_) {
      if (mounted) setState(() => _error = '语音设置未加载，请重试');
    }
  }

  Future<void> _toggle(bool enabled) async {
    if (_data == null || _busy) return;
    setState(() => _busy = true);
    try {
      await TtsService.save(null, {
        ...Map<String, dynamic>.from(_data!['value'] as Map),
        'enabled': enabled,
      }, _data!['version'] as String?);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '语音开关保存失败，请重新载入后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    child: Column(
      children: [
        if (_busy || (_data == null && _error == null))
          const LinearProgressIndicator(),
        SwitchListTile(
          key: const ValueKey('api-tts-enabled'),
          title: const Text('启用语音 TTS'),
          subtitle: const Text('语音总开关，关闭后所有角色仅发送文字。开关即时保存；开启后仍遵循角色设置和额度。'),
          value: (_data?['value'] as Map?)?['enabled'] == true,
          onChanged: _busy || _data == null ? null : _toggle,
        ),
        const Divider(height: 1, indent: 16),
        ListTile(
          title: const Text('豆包音色与密钥'),
          subtitle: const Text('音色、资源 ID、API Key、语速、额度及试听'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TtsSettingsPage()),
            );
            if (mounted) await _load();
          },
        ),
        if (_error != null) TextButton(onPressed: _load, child: Text(_error!)),
      ],
    ),
  );
}
