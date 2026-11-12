import 'session_service.dart';
import 'entity_sync_service.dart';
import 'backend_http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/role.dart';
import '../models/proactive_config.dart';
import 'storage_service.dart';
import 'memory_service.dart';
import 'settings_service.dart';
import 'diagnostics_service.dart';
import 'api_service.dart';

/// 角色管理服务
/// 管理 AI 角色的创建、切换和持久化
class RoleChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class RoleService {
  static final changes = RoleChanges();
  static Future<void> applySynced(List<Map<String, dynamic>> rows, Set<String> pending) async {
    final keep = _roles.where((r) => pending.contains('role:${r.id}')).toList();
    _roles.clear();
    for (final row in rows) {
      if (pending.contains('role:${row['id']}')) continue;
      final config = Map<String, dynamic>.from(row['proactive_config'] as Map? ?? {});
      if (config['min_interval_minutes'] != null) config['min_countdown_hours'] = (config['min_interval_minutes'] as num) / 60;
      if (config['max_interval_minutes'] != null) config['max_countdown_hours'] = (config['max_interval_minutes'] as num) / 60;
      _roles.add(Role.fromJson({...row, 'system_prompt': row['system_prompt'] ?? '', 'proactive_config': config}));
    }
    _roles.addAll(keep);
    await _saveRoles();
    changes.changed();
  }
  static final List<Role> _roles = [];
  static String _currentRoleId = 'default';
  static final Map<String, int> _revisions = {};
  static final Map<String, Future<bool>> _syncQueues = {};
  static final Map<String, int> _pendingSaves = {};
  static Future<void> waitForPendingSaves() async {
    await Future.wait(_syncQueues.values.toList());
  }

  /// 初始化角色服务
  static Future<void> init() async {
    await _loadRoles();
    // 如果本地无角色，从后端获取
    if (_roles.isEmpty && SessionService.instance.authenticated) {
      debugPrint('RoleService: No local roles, fetching from backend...');
      await fetchFromBackend();
    }
    DiagnosticsService.event('sync', 'roleservice_initialized_with');
  }

  /// 加载角色列表
  static Future<void> _loadRoles() async {
    _roles.clear();
    final jsonList = StorageService.getJsonList(StorageService.keyRoles);
    if (jsonList != null) {
      _roles.clear();
      for (final json in jsonList) {
        try {
          _roles.add(Role.fromJson(json));
        } catch (e) {
          DiagnosticsService.event('sync', 'legacy_event', error: e);
        }
      }
    }
    _currentRoleId =
        StorageService.getString(StorageService.keyCurrentRoleId) ?? 'default';
  }

  /// 保存角色列表
  static Future<void> _saveRoles() async {
    final jsonList = _roles.map((r) => r.toJson()).toList();
    await StorageService.setJsonList(StorageService.keyRoles, jsonList);
    await StorageService.setString(
      StorageService.keyCurrentRoleId,
      _currentRoleId,
    );
  }

  /// 获取所有角色
  static List<Role> getAllRoles() {
    return List.unmodifiable(_roles);
  }

  /// 获取当前角色
  static Role getCurrentRole() {
    return _roles.firstWhere(
      (r) => r.id == _currentRoleId,
      orElse: () => _roles.isNotEmpty ? _roles.first : Role.defaultRole(),
    );
  }

  /// 获取当前角色 ID
  static String get currentRoleId => _currentRoleId;

  /// 切换当前角色
  static Future<void> setCurrentRole(String roleId) async {
    if (_roles.any((r) => r.id == roleId)) {
      _currentRoleId = roleId;
      await StorageService.setString(StorageService.keyCurrentRoleId, roleId);
      DiagnosticsService.event('sync', 'legacy_event', roleId: roleId);
    }
  }

  /// 根据 ID 获取角色
  static Role? getRoleById(String id) {
    try {
      return _roles.firstWhere((r) => r.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 添加角色
  static Future<void> addRole(Role role) async {
    if (SessionService.instance.authenticated) {
      if (!await syncRoleToBackend(role)) throw StateError('角色未保存，请处理同步冲突或手动重试');
    }
    // 检查 ID 是否重复
    _roles.removeWhere((r) => r.id == role.id);
    _roles.add(role);
    if (SessionService.instance.authenticated) {
      _roles[_roles.length - 1] = role.copyWith(syncVersion: EntitySyncService.instance.version('role', role.id));
    }
    await _saveRoles();
    // 自动同步到后端（失败不影响本地）
    try {
      if (SessionService.instance.authenticated) return;
      await syncRoleToBackend(role);
      DiagnosticsService.event('sync', 'legacy_event');
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
    }
  }

  /// 更新角色
  static Future<void> updateRole(Role role) async {
    DiagnosticsService.event('settings', 'role_save_started', roleId: role.id);
    final index = _roles.indexWhere((r) => r.id == role.id);
    if (index == -1) throw StateError('角色不存在，无法保存');
    _revisions[role.id] = (_revisions[role.id] ?? 0) + 1;
    final key = '$_backendUrl/${role.id}';
    _pendingSaves[key] = (_pendingSaves[key] ?? 0) + 1;
    try {
      _roles[index] = role;
      await _saveRoles();
      if (!await syncRoleToBackend(role)) throw StateError('角色设置未保存到后端，请恢复连接后手动重试');
    } finally {
      final remaining = _pendingSaves[key]! - 1;
      if (remaining == 0) {
        _pendingSaves.remove(key);
      } else {
        _pendingSaves[key] = remaining;
      }
    }
  }

  /// 删除角色
  static Future<void> deleteRole(String roleId) async {
    if (roleId == 'default') {
      debugPrint('Cannot delete default role');
      return;
    }
    if (SessionService.instance.authenticated && !await EntitySyncService.instance.save('role', roleId, {},
        baseVersion: getRoleById(roleId)?.syncVersion, deleted: true)) {
      throw StateError('删除存在冲突，请到数据同步页处理');
    }
    _roles.removeWhere((r) => r.id == roleId);
    // 如果删除的是当前角色，切换到默认角色
    if (_currentRoleId == roleId) {
      _currentRoleId = 'default';
    }
    // 同时清除该角色的短期记忆
    MemoryService.clearShortTermMemory(roleId);
    await _saveRoles();
    // 自动从后端删除（失败不影响本地已删除状态）
    try {
      if (!SessionService.instance.authenticated) await _httpDelete('$_backendUrl/api/roles/$roleId');
      DiagnosticsService.event('sync', 'legacy_event', roleId: roleId);
    } catch (e) {
      DiagnosticsService.event(
        'sync',
        'legacy_event',
        error: e,
        roleId: roleId,
      );
    }
  }

  /// 创建新角色
  static Future<Role> createRole({
    required String name,
    required String systemPrompt,
    String description = '',
    double temperature = 0.7,
    double topP = 1.0,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int maxContextRounds = 10,
  }) async {
    final draft = StorageService.getJson('new_role_request');
    final requestId = draft?['name'] == name && draft?['prompt'] == systemPrompt
        ? draft!['id'] as String : ApiService.requestId();
    await StorageService.setJson('new_role_request', {'id': requestId, 'name': name, 'prompt': systemPrompt});
    final role = Role(
      id: requestId,
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      temperature: temperature,
      topP: topP,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      maxContextRounds: maxContextRounds,
    );
    await addRole(role);
    await StorageService.remove('new_role_request');
    return role;
  }

  /// 获取角色数量
  static int get roleCount => _roles.length;

  // ========== 后端同步 ==========

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 从后端获取角色列表
  static Future<bool> fetchFromBackend() async {
    final generation = SessionService.instance.generation;
    final revisions = Map<String, int>.of(_revisions);
    final backendUrl = _backendUrl;
    final pendingAtStart = {..._syncQueues.keys, ..._pendingSaves.keys};
    try {
      final response = await _httpGet('$backendUrl/api/roles');
      if (backendUrl != _backendUrl || generation != SessionService.instance.generation) return false;
      if (response != null && response['roles'] != null) {
        final List<dynamic> rolesJson = response['roles'];
        for (final json in rolesJson) {
          try {
            // 解析 core_memory
            List<String> coreMemory = [];
            if (json['core_memory'] != null) {
              coreMemory = (json['core_memory'] as List).cast<String>();
            }

            // 转换后端格式到本地 Role 格式
            final backendRole = Role(
              syncVersion: json['sync_version'] as String?,
              id: json['id'] ?? '',
              name: json['name'] ?? '',
              description: json['description'] ?? '',
              systemPrompt: json['system_prompt'] ?? '',
              avatarUrl: json['avatar_url'] ?? '',
              temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
              topP: (json['top_p'] as num?)?.toDouble() ?? 1.0,
              frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
              presencePenalty: (json['presence_penalty'] as num?)?.toDouble() ?? 0.0,
              maxContextRounds: json['max_context_rounds'] as int? ?? 10,
              summaryEveryNRounds: json['summary_every_n_rounds'] as int? ?? 20,
              allowWebSearch: json['allow_web_search'] as bool? ?? true,
              attachedJsonContent: json['attached_json_content'] as String?,
              coreMemory: coreMemory,
              proactiveConfig: ProactiveConfig(
                enabled: json['proactive_config']?['enabled'] == true,
                triggerPrompt: json['proactive_config']?['trigger_prompt'] as String? ?? '',
                minCountdownHours: ((json['proactive_config']?['min_interval_minutes'] as num?) ?? 60) / 60,
                maxCountdownHours: ((json['proactive_config']?['max_interval_minutes'] as num?) ?? 240) / 60),
            );

            // 更新或添加角色（保留本地专有字段）
            final existingIndex = _roles.indexWhere(
              (r) => r.id == backendRole.id,
            );
            if (existingIndex != -1) {
              final key = '$backendUrl/${backendRole.id}';
              if (pendingAtStart.contains(key) ||
                  _syncQueues.containsKey(key) ||
                  _pendingSaves.containsKey(key)) {
                continue;
              }
              if ((_revisions[backendRole.id] ?? 0) !=
                  (revisions[backendRole.id] ?? 0)) {
                continue;
              }
              final existing = _roles[existingIndex];
              // 合并：用后端的基础信息（名称、描述、头像、系统提示词、核心记忆），
              // 保留本地的所有AI参数和高级配置
              _roles[existingIndex] = existing.copyWith(
                syncVersion: backendRole.syncVersion,
                name: backendRole.name,
                description: backendRole.description,
                systemPrompt: backendRole.systemPrompt,
                avatarUrl: backendRole.avatarUrl,
                coreMemory: backendRole.coreMemory,
                temperature: backendRole.temperature, topP: backendRole.topP,
                frequencyPenalty: backendRole.frequencyPenalty, presencePenalty: backendRole.presencePenalty,
                maxContextRounds: backendRole.maxContextRounds, allowWebSearch: backendRole.allowWebSearch,
                summaryEveryNRounds: backendRole.summaryEveryNRounds,
                attachedJsonContent: backendRole.attachedJsonContent,
                proactiveConfig: backendRole.proactiveConfig,
              );
            } else {
              _roles.add(backendRole);
            }
          } catch (e) {
            DiagnosticsService.event(
              'sync',
              'error_parsing_backend_role',
              error: e,
            );
          }
        }
        await _saveRoles();
        DiagnosticsService.event('sync', 'synced');
        return true;
      }
    } catch (e) {
      DiagnosticsService.event('sync', 'backend_fetch_failed', error: e);
    }
    return false;
  }

  /// 同步单个角色到后端
  static Future<bool> syncRoleToBackend(Role role) async {
    final backendUrl = _backendUrl;
    final key = '$backendUrl/${role.id}';
    final previous = _syncQueues[key] ?? Future.value(true);
    final pending = previous.catchError((_) => false).then((_) => _syncRoleToBackend(role, backendUrl));
    _syncQueues[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_syncQueues[key], pending)) _syncQueues.remove(key);
    }
  }

  static Future<bool> _syncRoleToBackend(Role role, String backendUrl) async {
    if (SessionService.instance.authenticated) {
      final payload = role.toJson()..remove('sync_version');
      payload['proactive_config'] = {
        'enabled': role.proactiveConfig.enabled, 'trigger_prompt': role.proactiveConfig.triggerPrompt,
        'min_interval_minutes': (role.proactiveConfig.minCountdownHours * 60).round(),
        'max_interval_minutes': (role.proactiveConfig.maxCountdownHours * 60).round(),
        'quiet_hours_start': SettingsService.instance.quietStartHour, 'quiet_hours_end': SettingsService.instance.quietEndHour,
      };
      final result = await EntitySyncService.instance.save('role', role.id, payload, baseVersion: role.syncVersion);
      if (result) {
        final index = _roles.indexWhere((r) => r.id == role.id);
        if (index >= 0) _roles[index] = _roles[index].copyWith(syncVersion: EntitySyncService.instance.version('role', role.id));
        await _saveRoles();
      }
      return result;
    }
    try {
      final response = await _httpPost('$backendUrl/api/roles', {
        'id': role.id,
        'name': role.name,
        'description': role.description,
        'system_prompt': role.systemPrompt,
        'avatar_url': role.avatarUrl,
        'persona': role.description,
        'core_memory': role.coreMemory,
        // AI 参数
        'temperature': role.temperature,
        'top_p': role.topP,
        'frequency_penalty': role.frequencyPenalty,
        'presence_penalty': role.presencePenalty,
        'max_context_rounds': role.maxContextRounds,
        'summary_every_n_rounds': role.summaryEveryNRounds,
        'allow_web_search': role.allowWebSearch,
        'attached_json_content': role.attachedJsonContent,
        'proactive_config': {
          'enabled': role.proactiveConfig.enabled,
          'trigger_prompt': role.proactiveConfig.triggerPrompt,
          'min_interval_minutes': (role.proactiveConfig.minCountdownHours * 60).round(),
          'max_interval_minutes': (role.proactiveConfig.maxCountdownHours * 60).round(),
          'quiet_hours_start': SettingsService.instance.quietStartHour,
          'quiet_hours_end': SettingsService.instance.quietEndHour,
        },
      });
      return response != null;
    } catch (e) {
      DiagnosticsService.event('sync', 'sync_to_backend_failed', error: e);
      return false;
    }
  }

  /// 同步所有角色到后端
  static Future<void> syncAllToBackend() async {
    for (final role in _roles) {
      if (!await syncRoleToBackend(role)) throw StateError('原角色未迁移到后端，请手动重试');
    }
    DiagnosticsService.event('sync', 'synced');
  }

  /// HTTP GET
  static Future<Map<String, dynamic>?> _httpGet(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri);
      DiagnosticsService.event(
        'sync',
        'role_http_get',
        status: response.statusCode,
        requestId: response.headers['x-request-id'],
      );
      if (response.statusCode == 200) {
        final body = response.body;
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
    }
    return null;
  }

  /// HTTP POST
  static Future<Map<String, dynamic>?> _httpPost(
    String url,
    Map<String, dynamic> data,
  ) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(data));
      DiagnosticsService.event(
        'sync',
        'role_http_post',
        status: response.statusCode,
        requestId: response.headers['x-request-id'],
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = response.body;
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
    }
    return null;
  }

  /// HTTP DELETE
  static Future<bool> _httpDelete(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.delete(uri);
      return response.statusCode == 200;
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
    }
    return false;
  }
}
