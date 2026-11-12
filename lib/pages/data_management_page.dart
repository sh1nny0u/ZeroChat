import 'memory_management_page.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/backup_service.dart';
import '../services/entity_sync_service.dart';
import '../services/backend_sync_service.dart';
import '../services/history_repository.dart';
import '../core/message_store.dart';
import '../services/storage_service.dart';
import '../widgets/wechat_form_list.dart';

class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});
  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  final sync = EntitySyncService.instance;
  bool busy = false;
  String? message;
  Map<String, dynamic>? report;
  List<Map<String, dynamic>> backups = [];

  @override
  void initState() {
    super.initState();
    sync.addListener(_changed);
    _run(_load);
  }

  @override
  void dispose() {
    sync.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    report = await BackupService.request('GET', 'migration/report');
    final response = await BackupService.request('GET', 'backups');
    backups = (response['backups'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (error) {
      message = '操作未完成：$error；请确认连接后手动重试';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复业务数据'),
        content: const Text(
          '将覆盖服务器的角色、单聊和群聊记录、收藏、记忆、朋友圈、任务、素材及普通设置。'
          '当前数据会先自动备份并保留原目录；管理员账号、设备会话和当前供应商密钥保持不变。'
          '所有设备随后重新同步；恢复期间请暂停聊天和编辑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复并覆盖业务数据'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await BackendSyncService.quiesce();
    try {
      final response = await BackupService.request('POST', 'backups/restore', {
        'backup_id': id,
        'confirm': '恢复并覆盖业务数据',
      });
      // Reset cached server rows; retained local pending rows are never discarded.
      await HistoryRepository.instance?.db.delete(
        'messages',
        where: 'pending=0',
      );
      await MessageStore.init();
      await sync.pull();
      await BackendSyncService.tick();
      message = '恢复完成，恢复前保护备份：${response['safety_backup_id']}';
      await _load();
    } finally {
      BackendSyncService.start();
    }
  }

  Future<void> _resolve(Map<String, dynamic> conflict) async {
    final key = '${conflict['kind']}:${conflict['id']}';
    final remote = conflict['current'] as Map?;
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('比较修改冲突'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(key),
              const Text('服务器当前版本'),
              SelectableText(
                const JsonEncoder.withIndent(
                  '  ',
                ).convert(remote?['payload'] ?? {}),
              ),
              const Divider(),
              const Text('本机保留的修改'),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(conflict['payload']),
              ),
              const Text('采用本机修改前仍会检查最新版本；双方历史版本在服务器保留。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后处理'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('采用服务器'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('采用本机修改'),
          ),
        ],
      ),
    );
    if (choice != null) await sync.resolve(key, useLocal: choice);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据同步与备份')),
    body: WechatFormList(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectableText(message!),
          ),
        Text(sync.error ?? '服务器统一保存数据；自动刷新每 10 秒读取一次。'),
        if (report?['credentials_v9'] case final credentials?)
          Text(
            '供应商来源升级：${(credentials['confirmation_required'] as List? ?? []).isEmpty ? '已绑定原来源' : '部分来源无法确认，请到 AI 接口设置重新填写'}；升级前保护备份保留在服务器。',
          ),
        Text('待处理修改 ${sync.proposals.length} 项，冲突 ${sync.conflicts.length} 项'),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  await sync.retryPending();
                  await BackendSyncService.tick();
                  message = '同步完成';
                }),
          icon: const Icon(Icons.sync),
          label: const Text('同步并重试未完成修改'),
        ),
        for (final conflict in sync.conflicts)
          ListTile(
            leading: const Icon(Icons.warning_amber),
            title: Text('${conflict['kind']} / ${conflict['id']}'),
            subtitle: const Text('已保留两版，点击查看并选择'),
            onTap: busy ? null : () => _run(() => _resolve(conflict)),
          ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('记忆管理'),
          subtitle: const Text('统一管理核心、短期、情景和角色知识'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const MemoryManagementPage()),
          ),
        ),
        const Divider(),
        const Text('历史迁移报告', style: TextStyle(fontSize: 18)),
        if (report != null)
          SelectableText(
            key: const ValueKey('migration-report'),
            '状态：${report!['status']}\n数据格式：${report!['schema_version']}\n'
            '历史会话：${report!['histories'] ?? 0}\n原始数据保留：${report!['originals_retained'] == true ? '是' : '待检查'}',
          ),
        if (report?['memory_v6'] case final memory?)
          Text('混合记忆迁移：${memory['entries']} 条；原文件保留，索引可重建'),
        for (final warning
            in (report?['memory_v6'] as Map?)?['warnings'] as List? ?? [])
          Text('${warning['path']}：${warning['reason']}'),
        if (StorageService.getJson('phase4_client_report') case final local?)
          SelectableText(
            '本机迁移：${local['status']}；角色 ${local['roles']}，群聊 ${local['groups']}，收藏 ${local['favorites']}。原始副本已保留。',
          ),
        for (final warning
            in StorageService.getJson('phase4_client_report')?['warnings']
                    as List? ??
                [])
          Text('$warning'),
        for (final warning in report?['warnings'] as List? ?? [])
          Text('${warning['kind']} / ${warning['id']}：${warning['reason']}'),
        TextButton(
          onPressed: busy
              ? null
              : () => _run(() async {
                  report = await BackupService.request('POST', 'migration/run');
                }),
          child: const Text('检查迁移报告（重复执行不重复导入）'),
        ),
        const Divider(),
        const Text('服务器备份', style: TextStyle(fontSize: 18)),
        const Text(
          '可下载备份包含私密聊天和人设，默认排除供应商密钥、管理员和会话凭证。'
          '同机备份不能替代异地备份，请下载到私人位置。备份大小上限 256 MiB。',
        ),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  await BackupService.request('POST', 'backups');
                  await _load();
                  message = '备份已创建并校验';
                }),
          icon: const Icon(Icons.backup),
          label: const Text('创建完整业务备份'),
        ),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  final id = await BackupService.upload();
                  if (id != null) await _restore(id);
                }),
          icon: const Icon(Icons.upload_file),
          label: const Text('选择备份文件并恢复'),
        ),
        for (final backup in backups)
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5), width: .5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${backup['created_at']}\n${((backup['size'] as num) / 1024).toStringAsFixed(1)} KiB',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _run(() async {
                                if (await BackupService.download(
                                  backup['id'] as String,
                                ))
                                  message = '备份已下载，请妥善保管';
                              }),
                        child: const Text('下载'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () =>
                                  _run(() => _restore(backup['id'] as String)),
                        child: const Text('恢复此备份'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
