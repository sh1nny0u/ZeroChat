import 'backend_http.dart' as http;
import 'api_service.dart';
import 'session_service.dart';
import 'diagnostics_service.dart';
import 'dart:convert';
import 'storage_service.dart';
import 'settings_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 定时任务类型
enum TaskType {
  reminder, // 用户创建的提醒
  proactive, // 主动消息（由系统调度）
}

/// 定时任务模型
class ScheduledTask {
  final String id;
  final String chatId;
  final String roleId; // 所属角色
  final String message; // 提醒内容
  final String? aiPrompt; // AI 生成消息的提示词
  final DateTime triggerTime;
  final TaskType type;
  final bool isRecurring;
  final String? recurringPattern;
  bool isCompleted;
  final String? lastStatus;

  ScheduledTask({
    required this.id,
    required this.chatId,
    required this.roleId,
    required this.message,
    this.aiPrompt,
    required this.triggerTime,
    this.type = TaskType.reminder,
    this.isRecurring = false,
    this.recurringPattern,
    this.isCompleted = false,
    this.lastStatus,
  });

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    return ScheduledTask(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      roleId: json['role_id'] as String? ?? json['chat_id'] as String,
      message: json['message'] as String,
      aiPrompt: json['ai_prompt'] as String?,
      triggerTime: DateTime.parse(json['trigger_time'] as String),
      type: TaskType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => TaskType.reminder,
      ),
      isRecurring: json['is_recurring'] as bool? ?? false,
      recurringPattern: json['recurring_pattern'] as String?,
      isCompleted: json['is_completed'] as bool? ?? false,
      lastStatus: json['last_status'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chat_id': chatId,
      'role_id': roleId,
      'message': message,
      'ai_prompt': aiPrompt,
      'trigger_time': triggerTime.toIso8601String(),
      'type': type.name,
      'is_recurring': isRecurring,
      'recurring_pattern': recurringPattern,
      'is_completed': isCompleted,
      'last_status': lastStatus,
    };
  }
}

/// 定时任务服务
/// 管理定时提醒，支持 AI 风格消息发送
class TaskService {
  static final changes = ValueNotifier<int>(0);
  static final List<ScheduledTask> _tasks = [];

  // 安静时间设置（复用 ProactiveConfig 的逻辑，但保留全局设置作为备用）
  static bool _quietTimeEnabled = false;
  static int _quietTimeStart = 23;
  static int _quietTimeEnd = 7;

  // 安静时间内待发送的任务队列

  /// 初始化任务服务
  static Future<void> init() async {
    await _loadTasks();
    await _loadQuietTime();

    DiagnosticsService.event('behavior', 'taskservice_initialized_with');
  }

  // ========== 安静时间管理 ==========

  static Future<void> _loadQuietTime() async {
    _quietTimeEnabled =
        StorageService.getBool(StorageService.keyQuietTimeEnabled) ?? false;
    _quietTimeStart =
        StorageService.getInt(StorageService.keyQuietTimeStart) ?? 23;
    _quietTimeEnd = StorageService.getInt(StorageService.keyQuietTimeEnd) ?? 7;
  }

  static Future<void> setQuietTime({
    required bool enabled,
    int startHour = 23,
    int endHour = 7,
  }) async {
    final response = await http.put(
      Uri.parse('${SessionService.backend}/api/settings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'quiet_enabled': enabled,
        'quiet_start': startHour,
        'quiet_end': endHour,
      }),
    );
    if (response.statusCode != 200) throw StateError('安静时段未保存到后端，请重试');
    _quietTimeEnabled = enabled;
    _quietTimeStart = startHour;
    _quietTimeEnd = endHour;
    await StorageService.setBool(StorageService.keyQuietTimeEnabled, enabled);
    await StorageService.setInt(StorageService.keyQuietTimeStart, startHour);
    await StorageService.setInt(StorageService.keyQuietTimeEnd, endHour);
    DiagnosticsService.event('behavior', 'legacy_event');
  }

  static bool isQuietTime() {
    if (!(StorageService.getBool(StorageService.keyQuietTimeEnabled) ?? _quietTimeEnabled)) return false;
    final now = DateTime.now();
    final hour = now.hour;

    final start = StorageService.getInt(StorageService.keyQuietTimeStart) ?? _quietTimeStart;
    final end = StorageService.getInt(StorageService.keyQuietTimeEnd) ?? _quietTimeEnd;
    if (start <= end) {
      return hour >= start && hour < end;
    } else {
      return hour >= start || hour < end;
    }
  }

  static Map<String, dynamic> getQuietTimeSettings() {
    return {
      'enabled': _quietTimeEnabled,
      'start_hour': _quietTimeStart,
      'end_hour': _quietTimeEnd,
    };
  }

  // ========== 任务管理 ==========

  static Future<void> _loadTasks() async {
    _tasks.clear();
    final jsonList = StorageService.getJsonList(
      StorageService.keyScheduledTasks,
    );
    if (jsonList != null) {
      _tasks.clear();
      for (final json in jsonList) {
        try {
          final task = ScheduledTask.fromJson(json);
          if (!task.isCompleted) {
            _tasks.add(task);
          }
        } catch (e) {
          DiagnosticsService.event('behavior', 'legacy_event', error: e);
        }
      }
    }
  }

  static Future<void> _saveTasks() async {
    final jsonList = _tasks.map((t) => t.toJson()).toList();
    await StorageService.setJsonList(
      StorageService.keyScheduledTasks,
      jsonList,
    );
    changes.value++;
  }

  // ========== 公开 API ==========

  /// 添加提醒任务（结构化创建）
  static Future<ScheduledTask> addReminder({
    required String chatId,
    required String roleId,
    required String message,
    required DateTime triggerTime,
    String? aiPrompt,
  }) async {
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              chatId,
              roleId,
              message,
              triggerTime.toIso8601String(),
              aiPrompt,
            ]),
          ),
        )
        .toString();
    final pending = Map<String, String>.from(
      StorageService.getJson('pending_task_creates') ?? {},
    );
    final identity = pending[key] ?? ApiService.requestId();
    pending[key] = identity;
    await StorageService.setJson('pending_task_creates', pending);
    final task = ScheduledTask(
      id: identity,
      chatId: chatId,
      roleId: roleId,
      message: message,
      aiPrompt: aiPrompt,
      triggerTime: triggerTime,
      type: TaskType.reminder,
    );

    if (!await _syncTaskToBackend(task))
      throw StateError('任务未创建：请检查登录和后端连接后手动重试');
    if (!_tasks.any((t) => t.id == identity)) _tasks.add(task);
    await _saveTasks();
    pending.remove(key);
    await StorageService.setJson('pending_task_creates', pending);

    // 自动同步到后端

    DiagnosticsService.event('behavior', 'reminder_added_for');
    return task;
  }

  /// 解析简单时间表达式（可选备用）
  static DateTime? parseSimpleTime(String text) {
    final now = DateTime.now();

    // 匹配 "X小时后" 或 "X分钟后"
    final hourMatch = RegExp(r'(\d+)\s*小时后').firstMatch(text);
    if (hourMatch != null) {
      final hours = int.parse(hourMatch.group(1)!);
      return now.add(Duration(hours: hours));
    }

    final minuteMatch = RegExp(r'(\d+)\s*分钟后').firstMatch(text);
    if (minuteMatch != null) {
      final minutes = int.parse(minuteMatch.group(1)!);
      return now.add(Duration(minutes: minutes));
    }

    // 匹配 "HH:MM" 格式
    final timeMatch = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (timeMatch != null) {
      final hour = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2)!);
      var target = DateTime(now.year, now.month, now.day, hour, minute);
      if (target.isBefore(now)) {
        target = target.add(const Duration(days: 1));
      }
      return target;
    }

    return null;
  }

  /// 取消任务
  static Future<void> cancelTask(String taskId) async {
    await ApiService.requestDelete('/api/tasks/$taskId');
    _tasks.removeWhere((t) => t.id == taskId);
    await _saveTasks();
  }

  /// 取消所有任务
  static Future<void> cancelAllTasks() async {
    for (final task in List<ScheduledTask>.from(_tasks)) {
      await ApiService.requestDelete('/api/tasks/${task.id}');
    }
    _tasks.clear();
    await _saveTasks();
  }

  /// 获取所有活跃任务
  static List<ScheduledTask> getActiveTasks() {
    return _tasks.where((t) => !t.isCompleted).toList();
  }

  /// 获取指定聊天的任务
  static List<ScheduledTask> getTasksForChat(String chatId) {
    return _tasks
        .where(
          (t) =>
              t.chatId == chatId &&
              (!t.isCompleted ||
                  ['failed', 'uncertain'].contains(t.lastStatus)),
        )
        .toList();
  }

  static Future<void> retryTask(String taskId) async {
    await ApiService.request('/api/tasks/$taskId/retry', {});
    await fetchFromBackend();
  }

  // ========== 后端同步 ==========

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 同步任务到后端
  static Future<bool> _syncTaskToBackend(ScheduledTask task) async {
    try {
      final uri = Uri.parse('$_backendUrl/api/tasks');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id': task.id,
          'chat_id': task.chatId,
          'role_id': task.roleId,
          'trigger_time': task.triggerTime.toIso8601String(),
          'message': task.message,
          'ai_prompt': task.aiPrompt,
          'enabled': !task.isCompleted,
        }),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      DiagnosticsService.event('behavior', 'backend_sync_failed', error: e);
      return false;
    }
  }

  static Future<void> migrateLocalTasks() async {
    for (final task in List<ScheduledTask>.from(_tasks)) {
      if (!task.isCompleted && !await _syncTaskToBackend(task))
        throw StateError('原定时任务未迁移，请恢复连接后重新登录');
    }
  }

  /// 从后端拉取任务
  static Future<bool> fetchFromBackend() async {
    final generation = SessionService.instance.generation;
    try {
      final uri = Uri.parse('$_backendUrl/api/tasks');
      final response = await http.get(uri);
      if (generation != SessionService.instance.generation) return false;
      if (response.statusCode == 200) {
        final body = response.body;
        final data = jsonDecode(body);
        if (data['tasks'] != null) {
          _tasks.clear();
          for (final row in data['tasks'] as List) {
            _tasks.add(
              ScheduledTask.fromJson({
                ...Map<String, dynamic>.from(row as Map),
                'is_completed': row['enabled'] == false,
              }),
            );
          }
          await _saveTasks();
          DiagnosticsService.event('behavior', 'fetched');
          return true;
        }
      }
    } catch (e) {
      DiagnosticsService.event(
        'behavior',
        'fetch_from_backend_failed',
        error: e,
      );
    }
    return false;
  }
}
