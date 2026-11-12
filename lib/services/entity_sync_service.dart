import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'storage_service.dart';
import 'session_service.dart';
import 'role_service.dart';
import 'group_chat_service.dart';
import 'favorite_service.dart';
import 'memory_service.dart';
import 'settings_service.dart';
import 'chat_list_service.dart';
import '../models/role.dart';
import '../models/group_chat.dart';
import '../models/favorite_collection.dart';

/// Persist proposals before sending; never silently overwrite a conflict.
class EntitySyncService extends ChangeNotifier {
  static final instance = EntitySyncService();
  String? error;
  final Map<String, int> kindRevisions = {};
  int revision(String kind) => kindRevisions[kind] ?? 0;
  bool applying = false;
  Future<void>? _pulling;
  Future<void> _work = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _work.then((_) => action());
    _work = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> waitForPending() async {
    await _work;
    await _pulling;
  }

  static dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {
        for (final key in keys)
          if (key != 'sync_version' && key != 'schema_version')
            key: _canonical(value[key]),
      };
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static bool _same(dynamic left, dynamic right) =>
      jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));
  static Map<String, dynamic> _roleContent(Map<String, dynamic> value) {
    final result =
        Role.fromJson({
            ...value,
            'system_prompt': value['system_prompt'] ?? '',
          }).toJson()
          ..remove('sync_version')
          ..remove('created_at')
          ..remove('updated_at');
    result['avatar_url'] ??= '';
    return result;
  }

  static Map<String, dynamic> _groupContent(Map<String, dynamic> value) =>
      GroupChat.fromJson(value).toJson()
        ..remove('sync_version')
        ..remove('created_at');
  final Map<String, Future<bool>> _queues = {};
  Map<String, dynamic> get _state =>
      StorageService.getJson('sync_entities') ?? {};
  Map<String, dynamic> get proposals =>
      StorageService.getJson('sync_proposals') ?? {};
  String? version(String kind, String id) =>
      (_state['$kind:$id'] as Map?)?['version'] as String?;
  List<Map<String, dynamic>> entities(String kind) => _state.values
      .map((r) => Map<String, dynamic>.from(r as Map))
      .where((r) => r['kind'] == kind && r['deleted'] != true)
      .toList();
  List<Map<String, dynamic>> get conflicts => proposals.values
      .where((v) => (v as Map)['conflict'] == true)
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();

  Future<bool> save(
    String kind,
    String id,
    Map<String, dynamic> payload, {
    String? baseVersion,
    bool deleted = false,
  }) {
    final key = '$kind:$id';
    final previous = _queues[key] ?? Future.value(true);
    final next = previous
        .catchError((_) => false)
        .then(
          (_) => _serial(
            () => _save(
              kind,
              id,
              payload,
              baseVersion: baseVersion,
              deleted: deleted,
            ),
          ),
        );
    _queues[key] = next;
    return next.whenComplete(() {
      if (identical(_queues[key], next)) _queues.remove(key);
    });
  }

  Future<bool> _save(
    String kind,
    String id,
    Map<String, dynamic> payload, {
    String? baseVersion,
    bool deleted = false,
  }) async {
    if (!SessionService.instance.authenticated) throw StateError('请连接后端并登录后保存');
    final key = '$kind:$id';
    final pending = proposals;
    final old = pending[key] as Map?;
    if (old?['conflict'] == true)
      throw StateError('此数据存在修改冲突，请到设置 → 数据同步与备份处理');
    final operation = <String, dynamic>{
      'kind': kind,
      'id': id,
      'payload': payload,
      'deleted': deleted,
      'base_version': baseVersion ?? version(kind, id),
      'operation_id': ApiService.requestId(),
    };
    if (old != null &&
        _same(old['payload'], payload) &&
        old['deleted'] == deleted) {
      operation['operation_id'] = old['operation_id'];
      operation['base_version'] = old['base_version'];
    }
    pending[key] = operation;
    await StorageService.setJson('sync_proposals', pending);
    return _send(key, operation);
  }

  Future<bool> _send(String key, Map<String, dynamic> operation) async {
    try {
      final wire = Map<String, dynamic>.from(operation)
        ..remove('conflict')
        ..remove('current');
      final response = await http.post(
        Uri.parse('${SessionService.backend}/api/sync/entities'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(wire),
      );
      if (response.statusCode != 200)
        throw StateError(
          ApiService.responseError(response.statusCode, response.body),
        );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final pending = proposals;
      if (data['status'] == 'conflict') {
        pending[key] = {...wire, 'conflict': true, 'current': data['current']};
        await StorageService.setJson('sync_proposals', pending);
        error = '其他设备已修改数据，请处理冲突';
        notifyListeners();
        return false;
      }
      final state = _state;
      state[key] = data['entity'];
      await StorageService.setJson('sync_entities', state);
      pending.remove(key);
      await StorageService.setJson('sync_proposals', pending);
      error = null;
      notifyListeners();
      return true;
    } catch (_) {
      error = '同步失败，修改已保留；恢复连接后请手动重试';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> retryPending() async {
    for (final entry in proposals.entries.toList()) {
      final operation = Map<String, dynamic>.from(entry.value as Map);
      if (operation['conflict'] != true)
        await _serial(() => _send(entry.key, operation));
    }
    if (!await SettingsService.instance.syncApiSettingsToBackend())
      throw StateError('设置同步失败，请重新保存设置');
    await pull();
  }

  Future<void> resolve(String key, {required bool useLocal}) async {
    // Refresh before a choice; a third device may have edited the same entity.
    await pull();
    final pending = proposals;
    final proposal = pending[key] as Map?;
    if (proposal == null) return;
    if (useLocal) {
      final fresh =
          {
              ...Map<String, dynamic>.from(proposal),
              'base_version': (proposal['current'] as Map?)?['version'],
              'operation_id': ApiService.requestId(),
            }
            ..remove('conflict')
            ..remove('current');
      pending[key] = fresh;
      await StorageService.setJson('sync_proposals', pending);
      await _serial(() => _send(key, fresh));
    } else {
      pending.remove(key);
      await StorageService.setJson('sync_proposals', pending);
    }
    await apply();
    notifyListeners();
  }

  Future<void> pull() =>
      _pulling ??= _serial(_pull).whenComplete(() => _pulling = null);
  Future<void> _pull() async {
    bool changed = false;
    var cursor = StorageService.getInt('sync_cursor') ?? 0;
    var epoch = StorageService.getString('sync_epoch');
    while (true) {
      final uri = Uri.parse('${SessionService.backend}/api/sync/changes')
          .replace(
            queryParameters: {
              'after': '$cursor',
              'limit': '100',
              if (epoch != null) 'epoch': epoch,
            },
          );
      final response = await http.get(uri);
      if (response.statusCode != 200) throw StateError('同步读取失败，请手动重试');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      changed =
          changed ||
          data['reset'] == true ||
          (data['changes'] as List).isNotEmpty;
      final state = data['reset'] == true ? <String, dynamic>{} : _state;
      if (data['reset'] == true && epoch != null) {
        for (final kind in {
          'memory_entry',
          'memory_policy',
          ...kindRevisions.keys,
        }) {
          kindRevisions[kind] = revision(kind) + 1;
        }
        await StorageService.setInt(
          'history_restore_generation',
          (StorageService.getInt('history_restore_generation') ?? 0) + 1,
        );
      }
      for (final raw in data['changes'] as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final kind = row['kind'] as String;
        kindRevisions[kind] = revision(kind) + 1;
        state['${row['kind']}:${row['id']}'] = row;
      }
      // State first, cursor second: replay is safe after a partial local write.
      await StorageService.setJson('sync_entities', state);
      epoch = data['epoch'] as String;
      cursor = data['cursor'] as int;
      await StorageService.setInt('sync_cursor', cursor);
      await StorageService.setString('sync_epoch', epoch);
      if (data['has_more'] != true) break;
    }
    if (changed) {
      await apply();
      notifyListeners();
    }
  }

  Future<void> apply() async {
    applying = true;
    try {
      final rows = _state.values
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      List<Map<String, dynamic>> of(String kind) => rows
          .where((r) => r['kind'] == kind && r['deleted'] != true)
          .map(
            (r) => {
              ...Map<String, dynamic>.from(r['payload'] as Map),
              'sync_version': r['version'],
            },
          )
          .toList();
      final pending = proposals.keys.toSet();
      await RoleService.applySynced(of('role'), pending);
      await GroupChatService.applySynced(of('group'), pending);
      await FavoriteService.instance.applySynced(of('favorite'), pending);
      await ChatListService.instance.reconcileEntities(
        RoleService.getAllRoles().map((r) => r.toJson()).toList(),
        GroupChatService.getAllGroups().map((g) => g.toJson()).toList(),
      );
      if (!pending.contains('user_memory:global')) {
        final memory = of('user_memory');
        await MemoryService.applySynced(
          memory.isEmpty
              ? []
              : (memory.first['core_memory'] as List).cast<String>(),
        );
      }
      final preferences = of('preferences');
      if (!pending.contains('preferences:global')) {
        await SettingsService.instance.applySynced(
          preferences.isEmpty
              ? {
                  'user_nickname': 'ZeroChat',
                  'user_avatar_url': '',
                  'cover_image_url': '',
                  'chat_background_url': '',
                }
              : preferences.first,
        );
      }
      await SettingsService.instance.loadBackendSettings();
    } finally {
      applying = false;
    }
  }

  Future<void> captureLegacyLocal() async {
    if (StorageService.getJson('phase4_local_original') != null) return;
    final original = {
      'roles': StorageService.getJsonList('roles') ?? [],
      'groups': StorageService.getJsonList('group_chats') ?? [],
      'favorites': StorageService.getJsonList('favorite_collections') ?? [],
      'core_memory':
          StorageService.getStringList(StorageService.keyCoreMemory) ?? [],
      'preferences': {
        for (final key in [
          'user_nickname',
          'user_avatar_url',
          'cover_image_url',
          'chat_background_url',
        ])
          if (StorageService.getString(key) case final value?) key: value,
      },
      'raw': {
        for (final key in ['roles', 'group_chats', 'favorite_collections'])
          key: StorageService.getString(key),
      },
    };
    await StorageService.setJson('phase4_local_original', original);
  }

  Future<void> migrateLocal() async {
    if (StorageService.getBool('phase4_local_migrated') == true) return;
    await captureLegacyLocal();
    final original = StorageService.getJson('phase4_local_original')!;
    final roles = (original['roles'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final groups = (original['groups'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final favorites = List<Map<String, dynamic>>.from(
      original['favorites'] as List,
    );
    final coreMemory = List<String>.from(original['core_memory'] as List);
    final warnings = <String>[];
    await pull();
    for (final role in roles) {
      try {
        _roleContent(role);
      } catch (_) {
        warnings.add('角色记录无法可靠转换，原始副本已保留');
        continue;
      }
      final id = role['id'] as String;
      final remote = _state['role:$id'] as Map?;
      final payload = remote?['payload'] as Map?;
      if (remote == null) {
        final wire = Map<String, dynamic>.from(role)..remove('sync_version');
        await save('role', id, wire);
      } else if (remote['deleted'] == true ||
          !_same(
            _roleContent(Map<String, dynamic>.from(payload ?? {})),
            _roleContent(role),
          )) {
        final wire = Map<String, dynamic>.from(role)..remove('sync_version');
        final pending = proposals;
        pending['role:$id'] = {
          'kind': 'role',
          'id': id,
          'payload': wire,
          'deleted': false,
          'base_version': null,
          'operation_id': ApiService.requestId(),
          'conflict': true,
          'current': remote,
        };
        await StorageService.setJson('sync_proposals', pending);
      }
    }
    for (final group in groups) {
      try {
        _groupContent(group);
      } catch (_) {
        warnings.add('群聊记录无法可靠转换，原始副本已保留');
        continue;
      }
      final id = group['id'] as String;
      if (version('group', id) == null) {
        await save('group', id, group);
      } else if ((_state['group:$id'] as Map)['deleted'] == true ||
          !_same(
            _groupContent(
              Map<String, dynamic>.from(
                (_state['group:$id'] as Map)['payload'] as Map,
              ),
            ),
            _groupContent(group),
          )) {
        await _retainMigrationConflict('group', id, group);
      }
    }
    for (final row in favorites) {
      try {
        FavoriteCollection.fromJson(row);
      } catch (_) {
        warnings.add('收藏记录无法可靠转换，原始副本已保留');
        continue;
      }
      final id = row['id'] as String;
      if (version('favorite', id) == null) {
        await save('favorite', id, row);
      } else if (!_same((_state['favorite:$id'] as Map)['payload'], row)) {
        await _retainMigrationConflict('favorite', id, row);
      }
    }
    if (coreMemory.isNotEmpty && version('user_memory', 'global') == null) {
      await save('user_memory', 'global', {'core_memory': coreMemory});
    } else if (coreMemory.isNotEmpty &&
        jsonEncode(
              ((_state['user_memory:global'] as Map?)?['payload']
                  as Map?)?['core_memory'],
            ) !=
            jsonEncode(coreMemory)) {
      await _retainMigrationConflict('user_memory', 'global', {
        'core_memory': coreMemory,
      });
    }
    final preferences = Map<String, dynamic>.from(
      original['preferences'] as Map? ?? {},
    );
    if (version('preferences', 'global') == null && preferences.isNotEmpty) {
      final portable = <String, dynamic>{};
      for (final entry in preferences.entries) {
        final value = entry.value;
        if (entry.key == 'user_nickname' ||
            value == '' ||
            (value is String &&
                (value.startsWith('/api/') ||
                    value.startsWith('http://') ||
                    value.startsWith('https://')))) {
          portable[entry.key] = value;
        } else {
          warnings.add('本机图片路径无法跨设备使用，请在显示设置重新选择；原始路径已保留');
        }
      }
      if (portable.isNotEmpty) await save('preferences', 'global', portable);
    }
    await StorageService.setJson('phase4_client_report', {
      'status': conflicts.isNotEmpty
          ? 'complete_with_conflicts'
          : warnings.isNotEmpty
          ? 'complete_with_warnings'
          : 'complete',
      'roles': roles.length,
      'groups': groups.length,
      'favorites': favorites.length,
      'originals_retained': true,
      'conflicts': conflicts.length,
      'warnings': warnings,
    });
    await StorageService.setBool('phase4_local_migrated', true);
  }

  Future<void> _retainMigrationConflict(
    String kind,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final pending = proposals;
    final key = '$kind:$id';
    pending[key] = {
      'kind': kind,
      'id': id,
      'payload': payload,
      'deleted': false,
      'base_version': null,
      'operation_id': ApiService.requestId(),
      'conflict': true,
      'current': _state[key],
    };
    await StorageService.setJson('sync_proposals', pending);
  }
}
