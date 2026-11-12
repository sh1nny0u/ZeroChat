import 'package:flutter/material.dart';
import '../services/role_capability_service.dart';
import '../services/entity_sync_service.dart';
import '../widgets/wechat_form_list.dart';
import '../widgets/api_provider_presets.dart';

class RoleApiPage extends StatefulWidget {
  final String roleId;
  const RoleApiPage({super.key, required this.roleId});
  @override
  State<RoleApiPage> createState() => _RoleApiPageState();
}

class _RoleApiPageState extends State<RoleApiPage> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  bool _clearKey = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    for (final controller in [_url, _model, _key]) {
      controller.addListener(() => _dirty = true);
    }
    EntitySyncService.instance.addListener(_synced);
    _load();
  }

  void _synced() {
    if (mounted && !_busy && !_dirty) _load();
  }

  @override
  void dispose() {
    EntitySyncService.instance.removeListener(_synced);
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await RoleCapabilityService.api(widget.roleId);
      if (!mounted) return;
      _url.text = data['api_url'] as String? ?? '';
      _model.text = data['model'] as String? ?? '';
      setState(() {
        _data = data;
        _key.clear();
        _clearKey = false;
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RoleCapabilityService.saveApi(widget.roleId, {
        'revision': _data?['revision'],
        'api_url': _url.text.trim(),
        'model': _model.text.trim(),
        if (_clearKey || _key.text.isNotEmpty)
          'api_key': _clearKey ? '' : _key.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('角色 API 已保存')));
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('角色聊天 API'),
      actions: [
        TextButton(
          onPressed: _busy || _data == null ? null : _save,
          child: const Text('保存'),
        ),
      ],
    ),
    body: WechatFormList(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '地址和模型留空继承全局。密钥仅保存在后端，不回显；输入框留空保留已存密钥。更换到不同供应商地址时须单独填写密钥，避免将全局密钥发送到其他服务。',
        ),
        const SizedBox(height: 16),
        ApiProviderPresets(
          urlController: _url,
          enabled: !_busy && _data != null,
          onSelected: (preset) {
            if (preset.url.isEmpty) return;
            if (ApiProviderPreset.forUrl(_url.text) == preset) return;
            setState(() {
              _url.text = preset.url;
              _model.clear();
              _key.clear();
              _dirty = true;
            });
          },
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          SelectableText(_error!, style: const TextStyle(color: Colors.red)),
        TextField(
          controller: _url,
          enabled: !_busy && _data != null,
          decoration: const InputDecoration(labelText: 'API 地址（留空继承）'),
        ),
        TextField(
          controller: _model,
          enabled: !_busy && _data != null,
          decoration: const InputDecoration(labelText: '模型（留空继承）'),
        ),
        TextField(
          controller: _key,
          enabled: !_busy && _data != null && !_clearKey,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: _data?['api_key_configured'] == true
                ? '密钥已配置；输入新值替换'
                : '角色密钥（可选）',
          ),
        ),
        CheckboxListTile(
          value: _clearKey,
          onChanged: _busy ? null : (v) => setState(() => _clearKey = v!),
          title: const Text('清除角色密钥，恢复继承'),
        ),
        if (_data != null)
          Text(
            '生效模型：${_data!['effective_model']}\n生效地址：${_data!['effective_url']}\n${_data!['ready'] == true ? '配置完整' : '配置不完整，请检查地址和密钥'}',
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || _data == null ? null : _save,
          child: const Text('保存'),
        ),
        TextButton(
          onPressed: _busy ? null : _load,
          child: const Text('重新载入后端配置'),
        ),
      ],
    ),
  );
}
