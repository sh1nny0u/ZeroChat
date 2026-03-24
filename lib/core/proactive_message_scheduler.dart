import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../models/proactive_config.dart';
import '../services/role_service.dart';
import '../services/api_service.dart';
import '../services/task_service.dart';
import '../services/chat_list_service.dart';
import 'message_store.dart';
import 'segment_sender.dart';

/// 主动消息调度器
/// 负责按角色管理主动消息倒计时、触发和发送
class ProactiveMessageScheduler {
  static final ProactiveMessageScheduler _instance =
      ProactiveMessageScheduler._internal();
  factory ProactiveMessageScheduler() => _instance;
  ProactiveMessageScheduler._internal();

  static ProactiveMessageScheduler get instance => _instance;

  final Random _random = Random();

  /// 角色定时器（roleId -> Timer）
  final Map<String, Timer> _roleTimers = {};

  /// 主动消息发送回调（用于通知 UI）
  void Function(String chatId)? onMessageSent;

  /// 初始化调度器
  Future<void> init() async {
    debugPrint('ProactiveMessageScheduler: Initializing...');
    await _checkAndCompensate();
    _scheduleAllRoles();
    debugPrint('ProactiveMessageScheduler: Initialized');
  }

  /// 冷启动补偿：检查所有已过期的主动消息并立即触发
  Future<void> _checkAndCompensate() async {
    final roles = RoleService.getAllRoles();
    final now = DateTime.now();

    for (final role in roles) {
      final config = role.proactiveConfig;
      if (!config.enabled) continue;

      final nextTrigger = config.nextTriggerTime;
      if (nextTrigger != null && nextTrigger.isBefore(now)) {
        debugPrint(
          'ProactiveMessageScheduler: Cold-start compensation for ${role.name} (scheduled: $nextTrigger)',
        );
        // 使用原计划触发时间作为消息时间戳
        await _triggerProactiveMessage(role.id, scheduledTime: nextTrigger);
      }
    }
  }

  /// 为所有启用主动消息的角色调度
  void _scheduleAllRoles() {
    final roles = RoleService.getAllRoles();
    for (final role in roles) {
      if (role.proactiveConfig.enabled) {
        scheduleForRole(role.id);
      }
    }
  }

  /// 为指定角色调度主动消息
  void scheduleForRole(String roleId) {
    cancelForRole(roleId);

    final role = RoleService.getRoleById(roleId);
    if (role == null) return;

    final config = role.proactiveConfig;
    if (!config.enabled) return;

    DateTime nextTrigger;
    if (config.nextTriggerTime != null &&
        config.nextTriggerTime!.isAfter(DateTime.now())) {
      nextTrigger = config.nextTriggerTime!;
    } else {
      nextTrigger = _generateNextTriggerTime(config);
      _saveNextTriggerTime(roleId, nextTrigger);
    }

    final delay = nextTrigger.difference(DateTime.now());
    if (delay.isNegative) {
      _triggerProactiveMessage(roleId, scheduledTime: nextTrigger);
      return;
    }

    debugPrint(
      'ProactiveMessageScheduler: Scheduled ${role.name} in ${delay.inMinutes} minutes',
    );

    _roleTimers[roleId] = Timer(delay, () {
      _triggerProactiveMessage(roleId, scheduledTime: nextTrigger);
    });
  }

  /// 取消指定角色的调度
  void cancelForRole(String roleId) {
    _roleTimers[roleId]?.cancel();
    _roleTimers.remove(roleId);
  }

  /// 取消所有调度
  void cancelAll() {
    for (final timer in _roleTimers.values) {
      timer.cancel();
    }
    _roleTimers.clear();
  }

  /// 生成下次触发时间
  DateTime _generateNextTriggerTime(ProactiveConfig config) {
    final minMs = (config.minCountdownHours * 60 * 60 * 1000).toInt();
    final maxMs = (config.maxCountdownHours * 60 * 60 * 1000).toInt();
    final randomMs = minMs + _random.nextInt(maxMs - minMs);
    return DateTime.now().add(Duration(milliseconds: randomMs));
  }

  /// 保存下次触发时间
  Future<void> _saveNextTriggerTime(String roleId, DateTime triggerTime) async {
    final role = RoleService.getRoleById(roleId);
    if (role == null) return;

    final updatedRole = role.copyWith(
      proactiveConfig: role.proactiveConfig.copyWith(
        nextTriggerTime: triggerTime,
      ),
    );
    await RoleService.updateRole(updatedRole);
  }

  /// 触发主动消息
  Future<void> _triggerProactiveMessage(String roleId, {DateTime? scheduledTime}) async {
    final role = RoleService.getRoleById(roleId);
    if (role == null) return;

    // 检查全局安静时间
    if (TaskService.isQuietTime()) {
      debugPrint('ProactiveMessageScheduler: Skipped due to quiet time');
      // 稍后重试
      Future.delayed(const Duration(minutes: 30), () {
        if (!TaskService.isQuietTime()) {
          _triggerProactiveMessage(roleId);
        } else {
          scheduleForRole(roleId);
        }
      });
      return;
    }

    debugPrint('ProactiveMessageScheduler: Triggering for ${role.name}');

    // 实际消息时间：使用计划触发时间或当前时间
    final messageTime = scheduledTime ?? DateTime.now();

    try {
      final triggerPrompt = role.proactiveConfig.triggerPrompt.isNotEmpty
          ? role.proactiveConfig.triggerPrompt
          : '请你模拟角色，给用户发一条主动消息。要求自然、符合人设。';

      // 优先通过后端生成（走后端记忆、参数）
      var response = await ApiService.callBackendAI(
        roleId: roleId,
        eventType: 'proactive',
        content: triggerPrompt,
      );

      // 后端不可用时回退到前端直连（携带历史和记忆）
      if (!response.success && response.error?.contains('不可用') == true) {
        debugPrint('ProactiveMessageScheduler: Backend unavailable, fallback');
        final recentMessages = MessageStore.instance.getRecentRounds(roleId, 10);
        final history = MessageStore.toApiHistory(recentMessages);
        response = await ApiService.sendChatMessageWithRole(
          message: triggerPrompt,
          role: role,
          history: history,
          coreMemory: role.coreMemory,
        );
      }

      if (response.success && response.content != null) {
        await _sendAsRoleMessage(roleId, role, response.content!, messageTime: messageTime);
        debugPrint('ProactiveMessageScheduler: Message sent for ${role.name}');
      }
    } catch (e) {
      debugPrint('ProactiveMessageScheduler: Error: $e');
    }

    // 清除触发时间并调度下一次
    final updatedRole = RoleService.getRoleById(roleId);
    if (updatedRole != null) {
      await RoleService.updateRole(
        updatedRole.copyWith(
          proactiveConfig: updatedRole.proactiveConfig.clearNextTriggerTime(),
        ),
      );
    }

    final latestRole = RoleService.getRoleById(roleId);
    if (latestRole != null && latestRole.proactiveConfig.enabled) {
      scheduleForRole(roleId);
    }
  }

  /// 以角色身份发送消息
  Future<void> _sendAsRoleMessage(
    String chatId,
    Role role,
    String content, {
    DateTime? messageTime,
  }) async {
    final segments = SegmentSender.splitMessage(content);
    final baseTime = messageTime ?? DateTime.now();

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];

      if (i > 0) {
        await Future.delayed(
          Duration(milliseconds: SegmentSender.getRandomDelay()),
        );
      }

      // 使用基准时间 + 偏移，保证消息顺序正确
      final msgTime = baseTime.add(Duration(seconds: i));

      final message = Message(
        id: '${baseTime.millisecondsSinceEpoch}_proactive_$i',
        senderId: role.id,
        receiverId: 'me',
        content: segment,
        timestamp: msgTime,
      );

      await MessageStore.instance.addMessage(chatId, message);
    }

    // 更新未读计数
    if (segments.isNotEmpty) {
      MessageStore.instance.incrementUnread(chatId, count: segments.length);
      ChatListService.instance.incrementUnread(chatId, count: segments.length);
    }

    onMessageSent?.call(chatId);
  }

  /// 角色配置更新时调用（重新随机倒计时）
  void onRoleConfigChanged(String roleId) {
    final role = RoleService.getRoleById(roleId);
    if (role == null) {
      cancelForRole(roleId);
      return;
    }

    if (role.proactiveConfig.enabled) {
      // 清除现有触发时间，强制重新随机
      RoleService.updateRole(
        role.copyWith(
          proactiveConfig: role.proactiveConfig.clearNextTriggerTime(),
        ),
      ).then((_) => scheduleForRole(roleId));
    } else {
      cancelForRole(roleId);
    }
  }
}
