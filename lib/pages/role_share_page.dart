import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/role_capability_service.dart';
import '../services/role_service.dart';
import '../services/entity_sync_service.dart';
import '../widgets/wechat_form_list.dart';

class RoleSharePage extends StatefulWidget {
  final String? roleId;
  const RoleSharePage({super.key, this.roleId});
  @override
  State<RoleSharePage> createState() => _RoleSharePageState();
}

class _RoleSharePageState extends State<RoleSharePage> {
  final _code = TextEditingController();
  bool _attachment = false;
  bool _busy = false;
  String? _error;
  String? _previewedCode;
  Map<String, dynamic>? _preview;
  Map<String, dynamic>? _export;
  Map<String, dynamic>? _pendingDecision;
  String _mode = 'create';
  String? _target;
  bool get _sharing => widget.roleId != null;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() => _run(() async {
    final data = await RoleCapabilityService.export(
      widget.roleId!,
      _attachment,
    );
    if (mounted) setState(() => _export = data);
    await EntitySyncService.instance.pull();
  });

  Future<void> _inspect() => _run(() async {
    final text = _code.text.trim();
    final result = await RoleCapabilityService.preview(text);
    if (!mounted) return;
    setState(() {
      _preview = result;
      _previewedCode = text;
      _pendingDecision = null;
      _mode = (result['matches'] as List).isEmpty ? 'create' : 'copy';
      _target = (result['matches'] as List).isEmpty
          ? null
          : (result['matches'] as List).first['id'] as String;
    });
  });

  Future<void> _import() => _run(() async {
    if (_previewedCode != _code.text.trim()) throw StateError('好友码已变化，请重新预览');
    final matches = (_preview!['matches'] as List).cast<Map>();
    final selected = matches.where((m) => m['id'] == _target).firstOrNull;
    final decision = {
      'code': _previewedCode,
      'mode': _mode,
      'target_id': _mode == 'update' ? _target : null,
      'base_version': _mode == 'update' ? (selected?['version']) : null,
    };
    final same =
        _pendingDecision != null &&
        decision.entries.every((e) => _pendingDecision![e.key] == e.value);
    if (!same) {
      _pendingDecision = {...decision, 'operation_id': ApiService.requestId()};
    }
    await RoleCapabilityService.importRole(_pendingDecision!);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('角色已导入，更新前的旧版本已由服务器保留')));
      Navigator.pop(context, true);
    }
  });

  List<Widget> _profile(Map data) => [
    for (final field in [
      'name',
      'description',
      'system_prompt',
      'attached_json_content',
    ])
      if (data.containsKey(field))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                {
                  'name': '名称',
                  'description': '简介',
                  'system_prompt': '完整人设',
                  'attached_json_content': '外挂 JSON（可能含私人记录）',
                }[field]!,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(data[field] as String),
            ],
          ),
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final matches = (_preview?['matches'] as List? ?? []).cast<Map>();
    final selected = matches.where((m) => m['id'] == _target).firstOrNull;
    final role = _sharing ? RoleService.getRoleById(widget.roleId!) : null;
    return Scaffold(
      appBar: AppBar(title: Text(_sharing ? '分享角色好友码' : '输入好友码')),
      body: WechatFormList(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '好友码只含名称、简介、人设，以及主动勾选的外挂 JSON。编码不是加密，接收者能读取和修改；发出后无法撤回，原作者修改不会自动更新副本。',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            SelectableText(_error!, style: const TextStyle(color: Colors.red)),
          if (_sharing) ...[
            CheckboxListTile(
              value: _attachment,
              title: const Text('包含外挂 JSON（默认关闭）'),
              subtitle: const Text('可能含私人记录，请先查看完整内容'),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _attachment = v!;
                      _export = null;
                    }),
            ),
            if (_attachment) ...[
              const Text('即将分享的外挂 JSON：'),
              SelectableText(role?.attachedJsonContent ?? '此角色没有外挂 JSON'),
            ],
            FilledButton(
              onPressed: _busy ? null : _generate,
              child: const Text('生成好友码并预览'),
            ),
            if (_export != null) ...[
              ..._profile(_export!['profile'] as Map),
              const Text('好友码'),
              SelectableText(_export!['code'] as String),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: _export!['code'] as String),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('好友码已复制')),
                          );
                        }
                      },
                child: const Text('复制好友码'),
              ),
            ],
          ] else ...[
            TextField(
              controller: _code,
              enabled: !_busy,
              maxLines: 6,
              maxLength: 350000,
              decoration: const InputDecoration(
                labelText: '粘贴完整 ZEROCHAT1. 好友码',
              ),
              onChanged: (_) => setState(() {
                _preview = null;
                _previewedCode = null;
              }),
            ),
            FilledButton(
              onPressed: _busy ? null : _inspect,
              child: const Text('校验并预览'),
            ),
            if (_preview != null) ...[
              ..._profile(_preview!['profile'] as Map),
              Text(_preview!['warning'] as String),
              if (matches.isNotEmpty) ...[
                const Text('检测到相同来源或内容。默认另存，不会覆盖同名角色。'),
                DropdownButtonFormField<String>(
                  initialValue: _mode,
                  items: const [
                    DropdownMenuItem(value: 'copy', child: Text('另存为新角色')),
                    DropdownMenuItem(value: 'update', child: Text('更新已有角色')),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _mode = v!),
                ),
                if (_mode == 'update') ...[
                  DropdownButtonFormField<String>(
                    initialValue: _target,
                    items: [
                      for (final m in matches)
                        DropdownMenuItem(
                          value: m['id'] as String,
                          child: Text('${m['name']} (${m['id']})'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _target = v),
                  ),
                  const Text('确认差异后更新；保留旧版本、聊天、记忆和 AI 配置。'),
                  for (final entry
                      in (selected?['differences'] as Map? ?? {}).entries)
                    SelectableText(
                      '${entry.key}\n原内容：${entry.value['before']}\n新内容：${entry.value['after']}\n',
                    ),
                  if ((selected?['differences'] as Map? ?? {}).isEmpty)
                    const Text('设定字段没有差异'),
                ],
              ],
              FilledButton(
                onPressed: _busy ? null : _import,
                child: Text(_mode == 'update' ? '确认差异并更新' : '确认导入独立角色'),
              ),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('取消导入'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
