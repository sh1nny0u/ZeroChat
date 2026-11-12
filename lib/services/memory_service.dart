import 'backend_http.dart' as http;
import 'diagnostics_service.dart';
import 'dart:convert';
import '../models/message.dart';
import 'storage_service.dart';
import 'settings_service.dart';
import 'role_service.dart';
import 'entity_sync_service.dart';
import 'session_service.dart';

/// 记忆服务
/// 管理短期记忆和核心记忆
class MemoryService {
  static Future<void> applySynced(List<String> memory) async {
    _coreMemory = List.of(memory);
    await _saveCoreMemory();
  }
  /// 短期记忆：按会话ID存储的对话历史
  static final Map<String, List<Message>> _shortTermMemory = {};

  /// 核心记忆：重要的长期记忆
  static List<String> _coreMemory = [];

  /// 短期记忆的最大条数（每个会话）
  static int maxShortTermSize = 100;

  /// 初始化记忆服务
  static Future<void> init() async {
    _coreMemory = [];
    _shortTermMemory.clear();
    await _loadCoreMemory();
    DiagnosticsService.event('memory', 'memoryservice_initialized_with');
  }

  // ========== 核心记忆持久化 ==========

  /// 加载核心记忆
  static Future<void> _loadCoreMemory() async {
    final list = StorageService.getStringList(StorageService.keyCoreMemory);
    if (list != null) {
      _coreMemory = List.from(list);
    }
  }

  /// 保存核心记忆
  static Future<void> _saveCoreMemory() async {
    await StorageService.setStringList(
      StorageService.keyCoreMemory,
      _coreMemory,
    );
  }

  // ========== 短期记忆管理 ==========

  /// 添加消息到指定会话的短期记忆
  static void addToShortTermMemory(String chatId, Message message) {
    _shortTermMemory[chatId] ??= [];
    _shortTermMemory[chatId]!.add(message);

    // 超出限制时移除最旧的消息
    while (_shortTermMemory[chatId]!.length > maxShortTermSize) {
      _shortTermMemory[chatId]!.removeAt(0);
    }
  }

  /// 获取指定会话的短期记忆
  static List<Message> getShortTermMemory(String chatId) {
    return List.unmodifiable(_shortTermMemory[chatId] ?? []);
  }

  /// 获取指定会话最近 N 条消息
  static List<Message> getRecentMessages(String chatId, int count) {
    final messages = _shortTermMemory[chatId] ?? [];
    final start = messages.length > count ? messages.length - count : 0;
    return messages.sublist(start);
  }

  /// 获取指定会话最近 N 轮对话（一轮 = 用户消息 + AI回复）
  static List<Message> getRecentRounds(String chatId, int rounds) {
    final messages = _shortTermMemory[chatId] ?? [];
    // 每轮2条消息
    final messageCount = rounds * 2;
    final start = messages.length > messageCount
        ? messages.length - messageCount
        : 0;
    return messages.sublist(start);
  }

  /// 将消息列表转换为 API 历史格式
  static List<Map<String, String>> toApiHistory(List<Message> messages) {
    return messages.map((m) {
      return {
        'role': m.senderId == 'me' ? 'user' : 'assistant',
        'content': m.content,
      };
    }).toList();
  }

  /// 清空指定会话的短期记忆
  static void clearShortTermMemory(String chatId) {
    _shortTermMemory[chatId]?.clear();
  }

  /// 清空所有会话的短期记忆
  static void clearAllShortTermMemory() {
    _shortTermMemory.clear();
  }

  // ========== 核心记忆管理 ==========

  /// 添加核心记忆
  static Future<void> addToCoreMemory(String memory) async {
    if (memory.trim().isNotEmpty && !_coreMemory.contains(memory)) {
      _coreMemory.add(memory);
      await _saveCoreMemory();
      DiagnosticsService.event('memory', 'legacy_event');
      // 同步到后端
      await _syncCoreMemoryToBackend();
    }
  }

  /// 获取核心记忆
  static List<String> getCoreMemory() {
    return List.unmodifiable(_coreMemory);
  }

  /// 移除核心记忆
  static Future<void> removeFromCoreMemory(String memory) async {
    _coreMemory.remove(memory);
    await _saveCoreMemory();
    await _syncCoreMemoryToBackend();
  }

  /// 清空核心记忆
  static Future<void> clearCoreMemory() async {
    _coreMemory.clear();
    await _saveCoreMemory();
    // 同步到后端
    await _syncCoreMemoryToBackend();
  }

  // ========== 工具方法 ==========

  /// 清空所有记忆
  static Future<void> clearAllMemory() async {
    _shortTermMemory.clear();
    _coreMemory.clear();
    await _saveCoreMemory();
  }

  /// 获取会话数量
  static int get chatCount => _shortTermMemory.length;

  /// 获取核心记忆数量
  static int get coreMemoryCount => _coreMemory.length;

  /// 检查是否应该自动总结核心记忆（每20轮）
  static bool shouldAutoSummarize(String chatId) {
    final messages = _shortTermMemory[chatId] ?? [];
    // 每 40 条消息（20轮对话）触发一次
    return messages.isNotEmpty && messages.length % 40 == 0;
  }

  /// 获取用于AI总结的近期对话
  static String getRecentChatForSummary(String chatId, {int rounds = 20}) {
    final messages = getRecentRounds(chatId, rounds);
    if (messages.isEmpty) return '';

    final buffer = StringBuffer();
    for (final msg in messages) {
      final sender = msg.senderId == 'me' ? '用户' : 'AI';
      buffer.writeln('$sender: ${msg.content}');
    }
    return buffer.toString();
  }

  /// 从AI总结结果中添加记忆（替换式：用AI总结替换现有核心记忆）
  static Future<void> addSummaryToCoreMemory(String summary) async {
    // 清空现有核心记忆，用新的AI总结替换
    _coreMemory.clear();
    final lines = summary.split('\n').where((line) => line.trim().isNotEmpty);
    for (final line in lines) {
      // 清理行首的标记符号
      final cleaned = line.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim();
      if (cleaned.isNotEmpty && cleaned.length > 3) {
        _coreMemory.add(cleaned);
      }
    }
    await _saveCoreMemory();
    // 同步到后端
    await _syncCoreMemoryToBackend();
  }

  /// 同步核心记忆到后端
  static Future<void> _syncCoreMemoryToBackend() async {
    if (SessionService.instance.authenticated) {
      if (!await EntitySyncService.instance.save('user_memory', 'global', {'core_memory': _coreMemory})) {
        throw StateError('核心记忆存在冲突，请到数据同步页处理');
      }
      return;
    }
    try {
      final backendUrl = SettingsService.instance.backendUrl;
      final roleId = RoleService.getCurrentRole().id;
      final coreMemoryStr = _coreMemory.join('；');

      final uri = Uri.parse('$backendUrl/api/roles/$roleId/memory');
      final response = await http.put(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'core_memory': coreMemoryStr}));
      if (response.statusCode == 200) {
        DiagnosticsService.event(
          'memory',
          'core_memory_synced_to_backend_for_role',
          roleId: roleId,
        );
      } else {
        DiagnosticsService.event('memory', 'backend_sync_failed_with_status');
      }
    } catch (e) {
      DiagnosticsService.event('memory', 'backend_sync_error', error: e);
    }
  }

  /// 从用户输入中提取要记住的内容（已弃用，核心记忆改为AI自动总结）
  @Deprecated('Use autoSummarizeCoreMemory instead')
  static String extractMemoryContent(String message) {
    // 尝试提取关键信息
    final patterns = [
      RegExp(r'记住(.+)'),
      RegExp(r'记得(.+)'),
      RegExp(r'我(喜欢|讨厌|爱|是|叫)(.+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(message);
      if (match != null) {
        return match.group(match.groupCount) ?? message;
      }
    }

    return message;
  }
}
