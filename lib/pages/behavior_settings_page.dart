import 'package:flutter/material.dart';
import '../services/behavior_service.dart';
import '../services/entity_sync_service.dart';
import 'memory_management_page.dart';
import '../widgets/wechat_form_list.dart';

class BehaviorSettingsPage extends StatefulWidget {
  final String? roleId;
  const BehaviorSettingsPage({super.key, this.roleId});
  @override
  State<BehaviorSettingsPage> createState() => _BehaviorSettingsPageState();
}

class _BehaviorSettingsPageState extends State<BehaviorSettingsPage> {
  Map<String, dynamic>? _data;
  Map<String, dynamic> _draft = {};
  String? _version, _error;
  bool _loading = true, _saving = false, _dirty = false;
  int _generation = 0;
  bool get _role => widget.roleId != null;

  @override
  void initState() {
    super.initState();
    EntitySyncService.instance.addListener(_synced);
    _load();
  }

  @override
  void didUpdateWidget(covariant BehaviorSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roleId != widget.roleId) {
      _data = null;
      _draft = {};
      _dirty = false;
      _saving = false;
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    EntitySyncService.instance.removeListener(_synced);
    super.dispose();
  }

  void _synced() {
    if (mounted && !_loading && !_saving && !_dirty) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await BehaviorService.load(widget.roleId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = result;
        _draft = Map<String, dynamic>.from(
          result[_role ? 'config' : 'policy'] as Map,
        );
        _version = result[_role ? 'config_version' : 'version'] as String?;
        _dirty = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    final generation = _generation;
    final roleId = widget.roleId;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BehaviorService.save(roleId, Map.of(_draft), _version);
      if (!mounted || generation != _generation) return;
      await _load();
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$e；修改已保留，请手动重试');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _saving = false);
      // Successful reload increments the generation.
      if (mounted && roleId == widget.roleId && _saving) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _toggle(String key, String title, String subtitle) => SwitchListTile(
    key: ValueKey(key),
    title: Text(title),
    subtitle: Text(subtitle),
    value: _draft[key] == true,
    onChanged: _saving
        ? null
        : (value) => setState(() {
            _draft[key] = value;
            _dirty = true;
          }),
  );

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
            onChanged: (value) => input = value,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
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
                  update(() => error = '请输入 $min 至 $max 的整数');
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

  Widget _limit(String key, String label, int min, int max) => ListTile(
    title: Text(label),
    trailing: Text('${_draft[key]}'),
    enabled: !_saving,
    onTap: () => _number(key, label, min, max),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_role ? '生活与自主适应' : '自主行为与预算'),
      actions: [
        TextButton(onPressed: _loading || _saving || !_dirty ? null : _save, child: const Text('保存')),
        IconButton(
          tooltip: '重新载入',
          onPressed: _loading || _saving ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_data == null && !_loading)
          TextButton(onPressed: _load, child: const Text('重试')),
        if (_data != null)
          Expanded(
            child: WechatFormList(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '生活事件在后端内部模拟，不会操作真实应用。学习只参考当前获准使用的经历，不改原始人设或安全/API 配置。正常聊天不受自主预算限制。',
                  ),
                ),
                if (!_role) ...[
                  _toggle('enabled', '启用自主行为', '关闭后暂停生活模拟、自主联系和自动记忆整理'),
                  _toggle('quiet_enabled', '启用安静时段', '跨午夜生效；起止相同表示不设置此时段'),
                  _limit('quiet_start', '安静开始（小时）', 0, 23),
                  _limit('quiet_end', '安静结束（小时）', 0, 23),
                  _limit('utc_offset_minutes', '本地时区（UTC 偏移分钟）', -720, 840),
                  _limit('daily_actions', '每天最多自主动作（全部角色）', 0, 500),
                  _limit('daily_model_calls', '每天最多自主模型调用', 0, 1000),
                  _limit('daily_units', '每天自主用量上限', 0, 10000000),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '用量按请求 UTF-8 字节数 + 最大输出 token 数保守预留，不等于金额。失败和超时也占用预算；设为 0 可暂停收费自主行为。定时提醒由用户创建，不计入自主预算，仍遵守安静时段。',
                    ),
                  ),
                ] else ...[
                  _toggle('life_enabled', '内部生活模拟', '休息、专注、用餐和闲暇状态影响表达'),
                  _toggle(
                    'adaptive_enabled',
                    '从经历自主适应',
                    '兴趣、习惯和关系作为推测；关闭后立即停止使用',
                  ),
                  _toggle('proactive_enabled', '允许主动联系', '还需开启聊天信息中的原有主动消息开关'),
                  _toggle('moments_enabled', '允许自主发朋友圈', '仅在有合适经历时分享'),
                  _toggle('interactions_enabled', '允许朋友圈互动', '点赞和评论均受打扰限额控制'),
                  _toggle(
                    'group_followups_enabled',
                    '允许群内自主续聊',
                    '用户发起的正常群聊回复仍可用',
                  ),
                  _limit('daily_actions', '角色每天最多自主动作', 0, 100),
                  _limit('min_interval_minutes', '自主动作最小间隔（分钟）', 1, 10080),
                  _limit('daily_model_calls', '角色每天最多自主模型调用', 0, 500),
                  ListTile(
                    title: const Text('今日用量'),
                    subtitle: Text(
                      '动作 ${(_data!['usage'] as Map)['role_actions']} · 调用 ${(_data!['usage'] as Map)['role_calls']} · 全局用量 ${(_data!['usage'] as Map)['units']}',
                    ),
                  ),
                  for (final entry in (_data!['reasons'] as Map).entries)
                    ListTile(
                      title: Text(
                        const {
                              'proactive': '主动联系',
                              'moment': '朋友圈',
                              'comment': '评论',
                              'like': '点赞',
                              'group': '群聊续聊',
                            }[entry.key] ??
                            '${entry.key}',
                      ),
                      subtitle: Text('${(entry.value as Map)['message']}'),
                    ),
                  ListTile(
                    title: const Text('当前内部状态'),
                    subtitle: Text(
                      '${((_data!['life'] as Map)['current'] as Map?)?['label'] ?? '生活模拟已关闭'} · ${_data!['local_time']}',
                    ),
                  ),
                  for (final event
                      in ((_data!['life'] as Map)['events'] as List).reversed
                          .take(6))
                    ListTile(
                      title: Text('${(event as Map)['label']}（内部模拟）'),
                      subtitle: Text(
                        '${event['started_at']} · ${event['mood']}',
                      ),
                    ),
                  const ListTile(
                    title: Text('当前学习（推测）'),
                    subtitle: Text('随来源记忆修正、删除和共享权限即时变化'),
                  ),
                  if ((_data!['learning'] as List).isEmpty)
                    const ListTile(title: Text('暂未归纳到可用的兴趣、习惯或关系')),
                  for (final learned in _data!['learning'] as List)
                    ListTile(
                      title: Text('${(learned as Map)['content']}'),
                      subtitle: Text(
                        '${const {'interest': '兴趣', 'habit': '习惯', 'relationship': '关系'}[learned['category']]} · 推测 · 来源 ${learned['source']}',
                      ),
                    ),
                  ListTile(
                    title: const Text('修正来源记忆'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              MemoryManagementPage(roleId: widget.roleId),
                        ),
                      );
                      if (mounted) _load();
                    },
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: _loading || _saving || !_dirty ? null : _save,
                    child: const Text('保存设置'),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
