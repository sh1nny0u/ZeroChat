import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/tts_service.dart';
import '../services/entity_sync_service.dart';
import '../widgets/voice_message.dart';
import '../services/storage_service.dart';
import '../widgets/wechat_form_list.dart';

class TtsSettingsPage extends StatefulWidget {
  final String? roleId;
  const TtsSettingsPage({super.key, this.roleId});
  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  final _key = TextEditingController();
  final _speaker = TextEditingController();
  final _testText = TextEditingController(text: '你好，这是一个语音试听。');
  Map<String, dynamic>? _data;
  Map<String, dynamic> _draft = {};
  bool _inherit = true, _busy = false, _dirty = false;
  String? _error;
  Message? _sample;
  int _generation = 0;
  bool get _role => widget.roleId != null;
  @override
  void initState() {
    super.initState();
    EntitySyncService.instance.addListener(_sync);
    _load();
  }

  @override
  void didUpdateWidget(covariant TtsSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roleId != widget.roleId) {
      _data = null;
      _sample = null;
      _key.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    EntitySyncService.instance.removeListener(_sync);
    _key.dispose();
    _speaker.dispose();
    _testText.dispose();
    super.dispose();
  }

  void _sync() {
    if (mounted && !_busy && !_dirty) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final roleId = widget.roleId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await TtsService.load(widget.roleId);
      final pending = StorageService.getJson(
        'tts_pending_${widget.roleId ?? 'global'}',
      );
      Map<String, dynamic>? recovered;
      String? reconciliationError;
      try {
        recovered = pending == null
            ? null
            : await TtsService.resultFor(pending['id'] as String);
      } catch (_) {
        reconciliationError = '配置已加载；上次语音结果暂时无法查询，请恢复连接后重试，不会自动重新合成';
      }
      if (!mounted || generation != _generation || roleId != widget.roleId)
        return;
      if (recovered?['status'] == 'ready') {
        await StorageService.remove('tts_pending_${widget.roleId ?? 'global'}');
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _error = reconciliationError;
        final value = Map<String, dynamic>.from(data['value'] as Map);
        _inherit = _role && value['inherit'] == true;
        _draft = Map<String, dynamic>.from(
          (_role ? value['config'] : value) as Map,
        );
        if (_inherit) {
          _draft = Map<String, dynamic>.from(data['effective'] as Map);
        }
        _speaker.text = '${_draft['speaker']}';
        _dirty = false;
        if (recovered?['status'] == 'ready') {
          _sample = Message(
            id: pending!['id'] as String,
            senderId: widget.roleId ?? 'tts-test',
            receiverId: 'me',
            content: pending['text'] as String,
            timestamp: DateTime.now(),
            type: MessageType.voice,
            audioUrl: recovered!['audio_url'] as String,
            durationMs: recovered['duration_ms'] as int,
          );
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<bool> _save() async {
    final generation = _generation, roleId = widget.roleId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = {..._draft, 'speaker': _speaker.text.trim()};
      await TtsService.save(
        roleId,
        _role ? {'inherit': _inherit, 'config': value} : value,
        _data!['version'] as String?,
      );
      if (!mounted || generation != _generation) return false;
      await _load();
      return true;
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error；修改已保留');
      }
      return false;
    } finally {
      if (mounted && roleId == widget.roleId) setState(() => _busy = false);
    }
  }

  Future<void> _saveKey({bool clear = false}) async {
    if (!clear && _key.text.trim().isEmpty) {
      setState(() => _error = '请输入新的 API Key；清除请使用清除密钥按钮');
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TtsService.credential(
        widget.roleId,
        clear ? '' : _key.text,
        (_data!['credentials'] as Map)['revision'] as String?,
      );
      if (!mounted || generation != _generation) return;
      _key.clear();
      // Preserve unsaved non-secret settings when updating credentials.
      final fresh = await TtsService.load(widget.roleId);
      if (mounted && generation == _generation) {
        setState(() => _data!['credentials'] = fresh['credentials']);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (_key.text.isNotEmpty) {
      setState(() => _error = '请先保存输入的 API Key，再生成试听语音');
      return;
    }
    if (_dirty && !await _save()) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
      _sample = null;
    });
    try {
      final identity = ApiService.requestId();
      final text = _testText.text;
      final result = await TtsService.test(widget.roleId, identity, text);
      if (!mounted || generation != _generation) return;
      if (result['status'] != 'ready') {
        throw StateError(TtsService.reasons[result['status']] ?? '合成失败，请手动重试');
      }
      setState(
        () => _sample = Message(
          id: result['request_id'] as String? ?? identity,
          senderId: widget.roleId ?? 'tts-test',
          receiverId: 'me',
          content: result['text'] as String? ?? text,
          timestamp: DateTime.now(),
          type: MessageType.voice,
          audioUrl: result['audio_url'] as String,
          durationMs: result['duration_ms'] as int,
        ),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _number(String key, String title, int min, int max) async {
    var input = '${_draft[key]}';
    String? error;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(title),
          content: TextFormField(
            initialValue: input,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            onChanged: (value) => input = value,
            decoration: InputDecoration(
              helperText: '$min 至 $max',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final value = int.tryParse(input);
                if (value == null || value < min || value > max) {
                  update(() => error = '请输入范围内整数');
                } else {
                  Navigator.pop(context, value);
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (mounted && result != null) {
      setState(() {
        _draft[key] = result;
        _dirty = true;
      });
    }
  }

  Widget _limit(String key, String title, int min, int max) => ListTile(
    title: Text(title),
    trailing: Text('${_draft[key]}'),
    enabled: !_busy && !(_role && _inherit),
    onTap: () => _number(key, title, min, max),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_role ? '角色语音设置' : '语音与豆包 TTS'),
      actions: [
        TextButton(
          onPressed: _busy || _data == null ? null : _save,
          child: const Text('保存'),
        ),
        IconButton(
          tooltip: '重新载入',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_data == null && !_busy)
          TextButton(onPressed: _load, child: const Text('重试')),
        if (_data != null)
          Expanded(
            child: WechatFormList(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('AI 根据情境选择语音。先保存文字，语音失败或额度不足时保留文字。不会自动重试或切换收费供应商。'),
                if (_role)
                  SwitchListTile(
                    key: const ValueKey('tts-inherit'),
                    title: const Text('继承全局语音配置'),
                    value: _inherit,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _inherit = value;
                            _dirty = true;
                          }),
                  ),
                SwitchListTile(
                  key: const ValueKey('tts-enabled'),
                  title: const Text('允许 AI 发送语音'),
                  value: _draft['enabled'] == true,
                  onChanged: _busy || (_role && _inherit)
                      ? null
                      : (value) => setState(() {
                          _draft['enabled'] = value;
                          _dirty = true;
                        }),
                ),
                DropdownButtonFormField<String>(
                  initialValue: 'doubao',
                  decoration: const InputDecoration(labelText: '供应商'),
                  items: const [
                    DropdownMenuItem(
                      value: 'doubao',
                      child: Text('豆包 · HTTP V3'),
                    ),
                  ],
                  onChanged: null,
                ),
                TextField(
                  key: const ValueKey('tts-speaker'),
                  controller: _speaker,
                  enabled: !_busy && !(_role && _inherit),
                  decoration: const InputDecoration(labelText: '音色 ID'),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('resource:${_draft['resource_id']}'),
                  initialValue: _draft['resource_id'] as String,
                  decoration: const InputDecoration(
                    labelText: '资源 ID（须与音色权限对应）',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'seed-tts-2.0',
                      child: Text('seed-tts-2.0'),
                    ),
                    DropdownMenuItem(
                      value: 'seed-icl-2.0',
                      child: Text('seed-icl-2.0'),
                    ),
                  ],
                  onChanged: _busy || (_role && _inherit)
                      ? null
                      : (value) => setState(() {
                          _draft['resource_id'] = value;
                          _dirty = true;
                        }),
                ),
                _limit('speech_rate', '语速（0 为正常）', -50, 100),
                _limit('min_interval_seconds', '语音最小间隔（秒）', 0, 86400),
                _limit('daily_calls', '每天最多合成次数', 0, 1000),
                _limit('daily_characters', '每天最多合成字符', 0, 1000000),
                _limit('max_characters', '单条最多字符', 1, 1000),
                _limit('timeout_seconds', '合成超时（秒）', 2, 60),
                const Text(
                  '全局额度约束全部角色；角色覆盖也不能突破全局额度和间隔。测试、失败与超时均占用额度，字符数不是实际账单。每日按后端自主行为时区结算。',
                ),
                Text(
                  '今日：${(_data!['usage'] as Map)['calls']} 次 / ${(_data!['usage'] as Map)['characters']} 字；全局 ${(_data!['global_usage'] as Map)['calls']} 次',
                ),
                FilledButton(
                  key: const ValueKey('tts-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('保存语音配置'),
                ),
                const Divider(height: 32),
                Text(
                  '豆包 API Key：${(_data!['credentials'] as Map)['ready'] == true ? '已配置' : '未配置'}${_role ? '；角色独立 Key 留空时使用全局 Key' : ''}',
                ),
                const Text(
                  '使用新版豆包语音控制台 API Key，保存在后端配置文件，接口不回显；可下载备份不含密钥。密钥明文存盘，请限制服务器文件权限。',
                ),
                TextField(
                  key: const ValueKey('tts-key'),
                  controller: _key,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enabled: !_busy && !(_role && _inherit),
                  decoration: const InputDecoration(
                    labelText: '新的 API Key（不回填）',
                  ),
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: _busy || (_role && _inherit)
                          ? null
                          : () => _saveKey(),
                      child: const Text('保存密钥'),
                    ),
                    TextButton(
                      onPressed: _busy || (_role && _inherit)
                          ? null
                          : () => _saveKey(clear: true),
                      child: Text(_role ? '清除角色密钥并继承全局' : '清除密钥'),
                    ),
                  ],
                ),
                const Divider(height: 32),
                TextField(
                  controller: _testText,
                  enabled: !_busy,
                  maxLength: 300,
                  decoration: const InputDecoration(labelText: '测试文字（将发送给豆包）'),
                ),
                FilledButton.tonal(
                  key: const ValueKey('tts-test'),
                  onPressed: _busy ? null : _test,
                  child: const Text('生成试听语音（可能收费）'),
                ),
                const Text(
                  '测试使用已保存配置并计入预算。结果不明时刷新只查询原请求；确认失败后再次点击会创建新的测试，可能再次收费。',
                ),
                if (_sample != null) VoiceMessage(message: _sample!),
              ],
            ),
          ),
      ],
    ),
  );
}
