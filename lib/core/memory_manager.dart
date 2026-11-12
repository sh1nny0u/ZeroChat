import '../services/diagnostics_service.dart';
import '../services/api_service.dart';
import '../services/role_service.dart';
import 'message_store.dart';

/// 记忆管理器
/// 负责核心记忆的自动总结与更新
class MemoryManager {
  /// 触发总结的消息间隔（可配置）
  static int summarizeInterval = 40; // 默认 20 轮对话

  /// 总结的历史消息轮数
  static int summarizeRounds = 20;

  /// 设置总结轮数
  static void setSummarizeEveryNRounds(int rounds) {
    if (rounds > 0) {
      summarizeRounds = rounds;
      summarizeInterval = rounds * 2;
      DiagnosticsService.event('memory', 'set_summarize_every');
    }
  }

  /// 检查是否需要自动总结核心记忆
  static bool shouldAutoSummarize(String chatId) {
    final messageCount = MessageStore.instance.getMessageCount(chatId);
    final shouldSummarize =
        messageCount > 0 && messageCount % summarizeInterval == 0;
    DiagnosticsService.event('memory', 'check_summarize_for', chatId: chatId);
    return shouldSummarize;
  }

  /// Automatic summaries are owned by the backend chat event pipeline.
  static Future<void> triggerSummarizeIfNeeded(String chatId) async {}

  static Future<void> manualSummarize(String chatId) async {
    final result = await ApiService.callBackendAI(
      roleId: chatId,
      eventType: 'memory',
    );
    if (!result.success) throw StateError(result.error ?? '记忆整理失败');
  }

  /// 获取用于 AI 请求的核心记忆（从角色获取）
  static List<String> getCoreMemoryForRequest() {
    final role = RoleService.getCurrentRole();
    return role.coreMemory;
  }

  /// 获取指定角色的核心记忆
  static List<String> getRoleCoreMemory(String roleId) {
    final role = RoleService.getRoleById(roleId);
    return role?.coreMemory ?? [];
  }
}
