import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/entity_sync_service.dart';
import '../services/group_chat_service.dart';
import '../services/hybrid_memory_service.dart';
import '../services/role_service.dart';

class MemoryManagementPage extends StatefulWidget {
  final String? roleId;
  final String? groupId;
  const MemoryManagementPage({super.key, this.roleId, this.groupId});
  @override
  State<MemoryManagementPage> createState() => _MemoryManagementPageState();
}

class _MemoryManagementPageState extends State<MemoryManagementPage> {
  final _query = TextEditingController();
  List<Map<String, dynamic>> _entries = [];
  String? _scope, _owner, _category, _status, _error, _policyVersion;
  bool _loading = true, _busy = false, _more = false, _sharing = true;
  int _generation = 0;
  Map<String, dynamic>? _engine;
  int _revision = -1;
  final _scroll = ScrollController();
  static const scopes = {
    'global': '用户全局',
    'role': '角色私有',
    'direct': '单聊',
    'group': '群聊',
  };
  static const categories = {
    'core': '核心记忆',
    'short_term': '短期记忆',
    'episodic': '情景记忆',
    'knowledge': '角色知识',
  };
  static const states = {
    'confirmed': '已确认',
    'pending': '待验证',
    'superseded': '已取代',
  };

  @override
  void initState() {
    super.initState();
    _scope = widget.groupId != null ? 'group' : null;
    _owner = widget.groupId ?? widget.roleId;
    EntitySyncService.instance.addListener(_synced);
    _load();
    HybridMemoryService.status()
        .then((value) {
          if (mounted) setState(() => _engine = value);
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    EntitySyncService.instance.removeListener(_synced);
    _generation++;
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _synced() {
    final revision =
        EntitySyncService.instance.revision('memory_entry') +
        EntitySyncService.instance.revision('memory_policy');
    if (mounted && !_busy && !_loading && revision != _revision) {
      _revision = revision;
      _load();
    }
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await HybridMemoryService.list(
        scope: _scope,
        ownerId: _scope == 'global' ? null : _owner,
        category: _category,
        status: _status,
        query: _query.text,
        offset: append ? _entries.length : 0,
        limit: append || _entries.length < 50 ? 50 : _entries.length,
      );
      if (!mounted || generation != _generation) return;
      final rows = (data['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _entries = append ? [..._entries, ...rows] : rows;
        _more = data['has_more'] == true;
        _sharing = (data['policy'] as Map)['share_user_facts'] == true;
        _policyVersion = data['policy_version'] as String?;
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _action(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e；修改已保留，请手动重试或到数据同步页处理');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<DropdownMenuItem<String>> _items(Map<String, String> values) => values
      .entries
      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
      .toList();

  String _ownerLabel(Map<String, dynamic> entry) {
    if (entry['scope'] == 'global') return '所有角色';
    final id = entry['owner_id'] as String? ?? '';
    return RoleService.getRoleById(id)?.name ??
        GroupChatService.getGroup(id)?.name ??
        '来源会话';
  }

  Widget _filter(
    String label,
    String? value,
    Map<String, String> choices,
    ValueChanged<String?> changed,
  ) => DropdownButtonFormField<String>(
    initialValue: value ?? '',
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      contentPadding: const EdgeInsets.all(12),
    ),
    items: [
      DropdownMenuItem(value: '', child: Text('全部$label')),
      ..._items(choices),
    ],
    onChanged: _busy ? null : (v) => changed(v == '' ? null : v),
  );

  Widget _entryTile(Map<String, dynamic> entry) => Container(
    key: ValueKey('memory:${entry['id']}'),
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.all(16),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFE5E5E5), width: .5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry['content'] as String,
          style: const TextStyle(fontSize: 16, height: 1.5),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final label in [
              categories[entry['category']],
              states[entry['status']],
              entry['kind'] == 'fact' ? '事实' : '推测',
              if (entry['sensitive'] == true) '私密',
            ])
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: const Color(0xFFF2F2F2),
                child: Text(
                  label ?? '未分类',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF666666),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${scopes[entry['scope']]} · ${_ownerLabel(entry)}',
          style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
        ),
        Text(
          '来源：${entry['source']} · 置信度 ${((entry['confidence'] as num) * 100).round()}%'
          '${entry['shared'] == true ? ' · 允许共享' : ''}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF888888),
            height: 1.5,
          ),
        ),
        if ((entry['conflict_of'] as String? ?? '').isNotEmpty)
          const Text(
            '与已有事实冲突，确认将取代旧条目',
            style: TextStyle(color: Colors.orange),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (entry['status'] == 'pending')
              TextButton(
                onPressed: _busy ? null : () => _confirm(entry),
                child: const Text('验证确认'),
              ),
            IconButton(
              tooltip: '修正记忆',
              onPressed: _busy ? null : () => _edit(entry),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除记忆',
              onPressed: _busy ? null : () => _delete(entry),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFEDEDED),
    appBar: AppBar(
      title: const Text('记忆管理'),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _edit(),
          child: const Text('新增'),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          enabled: !_busy,
          onSelected: (action) {
            if (action == 'reload') _load();
            if (action == 'rebuild') _action(HybridMemoryService.rebuild);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'reload', child: Text('重新载入')),
            PopupMenuItem(value: 'rebuild', child: Text('重建本地索引')),
          ],
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: () => _load(),
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.psychology_outlined,
                      color: Color(0xFF07C160),
                    ),
                    title: const Text('本地记忆'),
                    subtitle: Text(
                      _engine == null
                          ? '正在读取检索状态'
                          : _engine!['vector_available'] == true
                          ? 'CPU 向量 + 全文检索'
                          : '全文检索 · 本地向量模型尚未就绪',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('共享通用用户事实'),
                    subtitle: const Text('关闭后仅来源会话可使用'),
                    value: _sharing,
                    onChanged: _busy || _loading
                        ? null
                        : (value) => _action(
                            () => HybridMemoryService.sharing(
                              value,
                              _policyVersion,
                            ),
                          ),
                  ),
                  ExpansionTile(
                    title: const Text('记忆隐私说明'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: const [
                      Text(
                        '记忆存储和检索在后端本地完成。选中的记忆及用于总结的对话可能发送给当前角色选定的 AI 供应商。私密内容仅限来源会话；自动总结待验证后才参与召回。',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.only(top: 10),
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _query,
                    decoration: InputDecoration(
                      labelText: '搜索记忆内容',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: '搜索',
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: () => _load(),
                      ),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, size) {
                      final width = size.maxWidth < 420
                          ? size.maxWidth
                          : (size.maxWidth - 20) / 3;
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          SizedBox(
                            width: width,
                            child: _filter('范围', _scope, scopes, (v) {
                              setState(() {
                                _scope = v;
                                _owner = v == 'group'
                                    ? widget.groupId
                                    : widget.roleId;
                              });
                              _load();
                            }),
                          ),
                          SizedBox(
                            width: width,
                            child: _filter('分类', _category, categories, (v) {
                              setState(() => _category = v);
                              _load();
                            }),
                          ),
                          SizedBox(
                            width: width,
                            child: _filter('状态', _status, states, (v) {
                              setState(() => _status = v);
                              _load();
                            }),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_loading || _busy)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (_error != null)
            SliverToBoxAdapter(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => _load(),
                          child: const Text('重新载入'),
                        ),
                        TextButton(
                          onPressed: () =>
                              _action(EntitySyncService.instance.retryPending),
                          child: const Text('重试未提交修改'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _entryTile(_entries[index]),
              childCount: _entries.length,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: _more
                    ? TextButton(
                        onPressed: _loading ? null : () => _load(append: true),
                        child: const Text('加载更多'),
                      )
                    : Text(_entries.isEmpty ? '暂无记忆' : '已加载全部'),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      ),
    ),
  );

  Future<void> _delete(Map<String, dynamic> entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除此记忆？'),
        content: const Text('删除后立即退出召回并同步删除标记。原始对话、旧版本和已有备份仍保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _action(() => HybridMemoryService.delete(entry));
    }
  }

  Future<void> _confirm(Map<String, dynamic> entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认已核实此记忆？'),
        content: Text(
          '推测来源：${entry['source']}\n${(entry['conflict_of'] as String? ?? '').isNotEmpty ? '已有冲突事实将保留为已取代版本，不再召回。' : '确认后允许在指定范围召回。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('已核实'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _action(() => HybridMemoryService.confirm(entry));
    }
  }

  Future<void> _edit([Map<String, dynamic>? original]) async {
    final content = TextEditingController(
      text: original?['content'] as String? ?? '',
    );
    final source = TextEditingController(
      text: original?['source'] as String? ?? '用户手动录入',
    );
    final factKey = TextEditingController(
      text: original?['fact_key'] as String? ?? '',
    );
    var scope =
        original?['scope'] as String? ??
        _scope ??
        (widget.roleId == null ? 'global' : 'role');
    var owner = original?['owner_id'] as String? ?? _owner ?? '';
    var category = original?['category'] as String? ?? 'core';
    var kind = original?['kind'] as String? ?? 'fact';
    var sensitive = original?['sensitive'] == true;
    var shared = original?['shared'] == true;
    var confidence = (original?['confidence'] as num?)?.toDouble() ?? 1;
    var origin =
        original?['origin_chat'] as String? ??
        widget.groupId ??
        widget.roleId ??
        '';
    String? validation;
    final conversations = <String, String>{
      for (final r in RoleService.getAllRoles()) r.id: r.name,
      for (final g in GroupChatService.getAllGroups()) g.id: g.name,
    };
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, local) {
          final owners = scope == 'group'
              ? {for (final g in GroupChatService.getAllGroups()) g.id: g.name}
              : {for (final r in RoleService.getAllRoles()) r.id: r.name};
          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            title: Text(original == null ? '新增记忆' : '修正记忆'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: content,
                      maxLines: 4,
                      maxLength: 4000,
                      decoration: const InputDecoration(labelText: '记忆内容'),
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: scope,
                      items: _items(scopes),
                      decoration: const InputDecoration(labelText: '范围'),
                      onChanged: (v) => local(() {
                        scope = v!;
                        owner = '';
                      }),
                    ),
                    if (scope != 'global')
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        key: ValueKey(scope),
                        initialValue: owners.containsKey(owner) ? owner : null,
                        items: _items(owners),
                        decoration: const InputDecoration(labelText: '归属角色或群聊'),
                        onChanged: (v) => local(() => owner = v!),
                      ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: category,
                      items: _items(categories),
                      decoration: const InputDecoration(labelText: '分类'),
                      onChanged: (v) => local(() => category = v!),
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: kind,
                      items: _items({'fact': '事实', 'inference': '推测（新增时待验证）'}),
                      onChanged: (v) => local(() => kind = v!),
                    ),
                    TextField(
                      controller: source,
                      maxLength: 500,
                      decoration: const InputDecoration(labelText: '来源'),
                    ),
                    TextField(
                      controller: factKey,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: '事实标识',
                        helperText: '可选，如 user.city；相同标识用于发现事实冲突。',
                        helperMaxLines: 5,
                      ),
                    ),
                    Text('置信度 ${(confidence * 100).round()}%'),
                    Slider(
                      value: confidence,
                      onChanged: (v) => local(() => confidence = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('私密 / 敏感'),
                      value: sensitive,
                      onChanged: (v) => local(() {
                        sensitive = v;
                        if (v) shared = false;
                      }),
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: conversations.containsKey(origin)
                          ? origin
                          : '',
                      items: [
                        const DropdownMenuItem(value: '', child: Text('无来源会话')),
                        ..._items(conversations),
                      ],
                      decoration: const InputDecoration(
                        labelText: '来源会话（私密内容必选）',
                      ),
                      onChanged: (v) => origin = v!,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许共享'),
                      subtitle: const Text('全局事实可跨角色；群聊可供成员单聊引用；角色私有始终不跨角色'),
                      value: shared,
                      onChanged: sensitive
                          ? null
                          : (v) => local(() => shared = v),
                    ),
                    if (validation != null)
                      Text(
                        validation!,
                        style: const TextStyle(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  if (content.text.trim().isEmpty ||
                      (scope != 'global' && !owners.containsKey(owner)) ||
                      (sensitive && origin.isEmpty)) {
                    local(() => validation = '请填写内容、有效归属和私密记忆的来源会话');
                    return;
                  }
                  final now = DateTime.now().toUtc().toIso8601String();
                  Navigator.pop(dialogContext, <String, dynamic>{
                    ...?(original),
                    'id': original?['id'] ?? ApiService.requestId(),
                    'content': content.text.trim(),
                    'scope': scope,
                    'owner_id': scope == 'global' ? '' : owner,
                    'origin_chat': origin,
                    'category': category,
                    'kind': kind,
                    'source': source.text,
                    'fact_key': factKey.text.trim(),
                    'confidence': confidence,
                    'sensitive': sensitive,
                    'shared': shared,
                    'status':
                        original?['status'] ??
                        (kind == 'fact' ? 'confirmed' : 'pending'),
                    'created_at': original?['created_at'] ?? now,
                    'updated_at': now,
                  });
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    // Keep controllers alive until the dialog's closing animation completes.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    content.dispose();
    source.dispose();
    factKey.dispose();
    if (result != null && mounted) {
      await _action(
        () => HybridMemoryService.save(
          result,
          original?['sync_version'] as String?,
        ),
      );
    }
  }
}
