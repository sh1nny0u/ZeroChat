import 'diagnostics_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储服务
/// 使用 SharedPreferences 持久化数据
class StorageService {
  static SharedPreferences? _prefs;

  /// 初始化存储服务
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    debugPrint('StorageService initialized');
  }

  /// 获取 SharedPreferences 实例
  static SharedPreferences get prefs {
    if (_prefs == null) {
      throw Exception('StorageService not initialized. Call init() first.');
    }
    return _prefs!;
  }

  static String? _scope;
  static String? get currentScope => _scope;
  static String scopedDirectory(String name) => _scope == null || _scope == legacyScope ? name : 'accounts/$_scope/$name';
  static Map<String, Object> exportPreferences() {
    final result = <String, Object>{};
    final prefix = _scope == null ? '' : 'account_${_scope}_';
    for (final key in (prefs.getKeys().toList()..sort())) {
      if (key == 'backend_url' || (_scope == null ? !key.startsWith('account_') && key != 'legacy_account_scope' : key.startsWith(prefix))) {
        final name = key == 'backend_url' ? key : key.substring(prefix.length);
        if (name.contains('api_key') || name.contains('token') || name.contains('api_config')) continue;
        final value = prefs.get(key);
        if (value != null) result[name] = value;
      }
    }
    return result;
  }
  static String _key(String key) => key == 'backend_url' || _scope == null ? key : 'account_${_scope}_$key';
  static String? get legacyScope => prefs.getString('legacy_account_scope');
  static Future<void> activateScope(String scope) async {
    if (legacyScope == null) {
      // Preserve original keys, and bind their copy to only the first account.
      for (final key in prefs.getKeys().where((key) => !key.startsWith('account_') && key != 'backend_url' && key != 'legacy_account_scope').toList()) {
        final value = prefs.get(key);
        final target = 'account_${scope}_$key';
        if (value is String) await prefs.setString(target, value);
        if (value is int) await prefs.setInt(target, value);
        if (value is bool) await prefs.setBool(target, value);
        if (value is double) await prefs.setDouble(target, value);
        if (value is List<String>) await prefs.setStringList(target, value);
      }
      await prefs.setString('legacy_account_scope', scope);
    }
    _scope = scope;
  }

  // ========== 通用方法 ==========

  static Future<bool> setString(String key, String value) async {
    return await prefs.setString(_key(key), value);
  }

  static String? getString(String key) {
    return prefs.getString(_key(key));
  }

  static Future<bool> setStringList(String key, List<String> value) async {
    return await prefs.setStringList(_key(key), value);
  }

  static List<String>? getStringList(String key) {
    return prefs.getStringList(_key(key));
  }

  static Future<bool> setInt(String key, int value) async {
    return await prefs.setInt(_key(key), value);
  }

  static int? getInt(String key) {
    return prefs.getInt(_key(key));
  }

  static Future<bool> setBool(String key, bool value) async {
    return await prefs.setBool(_key(key), value);
  }

  static bool? getBool(String key) {
    return prefs.getBool(_key(key));
  }

  static Future<bool> remove(String key) async {
    return await prefs.remove(_key(key));
  }

  // ========== JSON 对象存储 ==========

  static Future<bool> setJson(String key, Map<String, dynamic> json) async {
    return await setString(key, jsonEncode(json));
  }

  static Map<String, dynamic>? getJson(String key) {
    final str = getString(key);
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
      return null;
    }
  }

  static Future<bool> setJsonList(
    String key,
    List<Map<String, dynamic>> list,
  ) async {
    return await setString(key, jsonEncode(list));
  }

  static List<Map<String, dynamic>>? getJsonList(String key) {
    final str = getString(key);
    if (str == null) return null;
    try {
      final list = jsonDecode(str) as List;
      return list.map((e) => e as Map<String, dynamic>).toList();
    } catch (e) {
      DiagnosticsService.event('sync', 'legacy_event', error: e);
      return null;
    }
  }

  // ========== 存储键定义 ==========

  static const String keyRoles = 'roles';
  static const String keyCurrentRoleId = 'current_role_id';
  static const String keyCoreMemory = 'core_memory';
  static const String keyQuietTimeStart = 'quiet_time_start';
  static const String keyQuietTimeEnd = 'quiet_time_end';
  static const String keyQuietTimeEnabled = 'quiet_time_enabled';
  static const String keyScheduledTasks = 'scheduled_tasks';
  static const String keyChatApiConfig = 'chat_api_config';
  static const String keyIntentApiConfig = 'intent_api_config';
}
