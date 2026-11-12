/// 主动消息配置模型
/// 用于配置 AI 角色的主动消息触发行为（角色独立）
class ProactiveConfig {
  /// 是否启用主动消息
  final bool enabled;

  /// 自定义触发提示词（发送给 AI 让它生成主动消息）
  final String triggerPrompt;

  /// 最小倒计时（小时）- UI 层使用
  final double minCountdownHours;

  /// 最大倒计时（小时）- UI 层使用
  final double maxCountdownHours;

  /// 下次触发时间（时间戳，持久化用）
  final DateTime? nextTriggerTime;

  const ProactiveConfig({
    this.enabled = false,
    this.triggerPrompt = '请你模拟角色，给用户发消息，想知道用户在做什么',
    this.minCountdownHours = 1.0,
    this.maxCountdownHours = 4.0,
    this.nextTriggerTime,
  });

  /// 默认配置
  factory ProactiveConfig.defaultConfig() => const ProactiveConfig();

  /// 从 JSON 创建
  factory ProactiveConfig.fromJson(Map<String, dynamic> json) {
    return ProactiveConfig(
      enabled: json['enabled'] as bool? ?? false,
      triggerPrompt:
          json['trigger_prompt'] as String? ?? '请你模拟角色，给用户发消息，想知道用户在做什么',
      minCountdownHours:
          (json['min_countdown_hours'] as num?)?.toDouble() ??
          (json['min_interval_minutes'] is num ? (json['min_interval_minutes'] as num) / 60 : 1.0),
      maxCountdownHours:
          (json['max_countdown_hours'] as num?)?.toDouble() ??
          (json['max_interval_minutes'] is num ? (json['max_interval_minutes'] as num) / 60 : 4.0),
      nextTriggerTime: json['next_trigger_time'] != null
          ? DateTime.parse(json['next_trigger_time'] as String)
          : null,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_countdown_hours': minCountdownHours,
      'max_countdown_hours': maxCountdownHours,
      'next_trigger_time': nextTriggerTime?.toIso8601String(),
    };
  }

  /// 复制并修改
  ProactiveConfig copyWith({
    bool? enabled,
    String? triggerPrompt,
    double? minCountdownHours,
    double? maxCountdownHours,
    DateTime? nextTriggerTime,
  }) {
    return ProactiveConfig(
      enabled: enabled ?? this.enabled,
      triggerPrompt: triggerPrompt ?? this.triggerPrompt,
      minCountdownHours: minCountdownHours ?? this.minCountdownHours,
      maxCountdownHours: maxCountdownHours ?? this.maxCountdownHours,
      nextTriggerTime: nextTriggerTime ?? this.nextTriggerTime,
    );
  }

  /// 清除下次触发时间（强制重新随机）
  ProactiveConfig clearNextTriggerTime() {
    return ProactiveConfig(
      enabled: enabled,
      triggerPrompt: triggerPrompt,
      minCountdownHours: minCountdownHours,
      maxCountdownHours: maxCountdownHours,
      nextTriggerTime: null,
    );
  }
}
