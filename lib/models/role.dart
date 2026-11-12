import 'dart:convert';
import 'proactive_config.dart';
import 'sticker.dart';

/// 角色模型
/// 用于 AI 角色的人设配置和参数设置
class Role {
  final String? syncVersion;
  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String? avatarUrl;

  // AI 参数
  final double temperature;
  final double topP;
  final double frequencyPenalty;
  final double presencePenalty;
  final int maxContextRounds;
  final bool allowWebSearch;

  // 外挂 JSON 记录内容（只读，注入到聊天上下文）
  final String? attachedJsonContent;

  // 角色专属核心记忆
  final List<String> coreMemory;

  // 核心记忆总结轮数（角色独立）
  final int summaryEveryNRounds;

  // 主动消息配置（角色独立）
  final ProactiveConfig proactiveConfig;

  // 表情包配置（角色独立）
  final StickerConfig stickerConfig;

  final DateTime createdAt;
  final DateTime updatedAt;

  Role({
    this.syncVersion,
    required this.id,
    required this.name,
    this.description = '',
    required this.systemPrompt,
    this.avatarUrl,
    this.temperature = 0.7,
    this.topP = 1.0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.maxContextRounds = 10,
    this.allowWebSearch = true,
    this.attachedJsonContent,
    List<String>? coreMemory,
    this.summaryEveryNRounds = 20,
    ProactiveConfig? proactiveConfig,
    StickerConfig? stickerConfig,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : coreMemory = coreMemory ?? [],
       proactiveConfig = proactiveConfig ?? const ProactiveConfig(),
       stickerConfig = stickerConfig ?? const StickerConfig(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 创建默认角色
  factory Role.defaultRole() {
    return Role(
      id: 'default',
      name: 'AI 助手',
      description: '默认的 AI 助手角色',
      systemPrompt: '你是一个友好、有帮助的 AI 助手。请用中文回答问题。',
    );
  }

  /// 复制并修改
  Role copyWith({
    String? syncVersion,
    String? id,
    String? name,
    String? description,
    String? systemPrompt,
    String? avatarUrl,
    double? temperature,
    double? topP,
    double? frequencyPenalty,
    double? presencePenalty,
    int? maxContextRounds,
    bool? allowWebSearch,
    String? attachedJsonContent,
    List<String>? coreMemory,
    int? summaryEveryNRounds,
    ProactiveConfig? proactiveConfig,
    StickerConfig? stickerConfig,
    DateTime? updatedAt,
  }) {
    return Role(
      syncVersion: syncVersion ?? this.syncVersion,
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      maxContextRounds: maxContextRounds ?? this.maxContextRounds,
      allowWebSearch: allowWebSearch ?? this.allowWebSearch,
      attachedJsonContent: attachedJsonContent ?? this.attachedJsonContent,
      coreMemory: coreMemory ?? this.coreMemory,
      summaryEveryNRounds: summaryEveryNRounds ?? this.summaryEveryNRounds,
      proactiveConfig: proactiveConfig ?? this.proactiveConfig,
      stickerConfig: stickerConfig ?? this.stickerConfig,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// 添加核心记忆
  Role addCoreMemory(String memory) {
    final newMemory = List<String>.from(coreMemory);
    if (!newMemory.contains(memory)) {
      newMemory.add(memory);
    }
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  /// 添加多条核心记忆
  Role addCoreMemories(List<String> memories) {
    final newMemory = List<String>.from(coreMemory);
    for (final memory in memories) {
      if (!newMemory.contains(memory) && memory.isNotEmpty) {
        newMemory.add(memory);
      }
    }
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  /// 清空核心记忆
  Role clearCoreMemory() {
    return copyWith(coreMemory: [], updatedAt: DateTime.now());
  }

  /// 删除单条核心记忆
  Role removeCoreMemory(int index) {
    if (index < 0 || index >= coreMemory.length) return this;
    final newMemory = List<String>.from(coreMemory);
    newMemory.removeAt(index);
    return copyWith(coreMemory: newMemory, updatedAt: DateTime.now());
  }

  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      syncVersion: json['sync_version'] as String?,
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String,
      avatarUrl: json['avatar_url'] as String?,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (json['top_p'] as num?)?.toDouble() ?? 1.0,
      frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      presencePenalty: (json['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      maxContextRounds: json['max_context_rounds'] as int? ?? 10,
      allowWebSearch: json['allow_web_search'] as bool? ?? true,
      attachedJsonContent: json['attached_json_content'] as String?,
      coreMemory: (json['core_memory'] as List<dynamic>?)?.cast<String>() ?? [],
      summaryEveryNRounds: json['summary_every_n_rounds'] as int? ?? 20,
      proactiveConfig: json['proactive_config'] != null
          ? ProactiveConfig.fromJson(
              json['proactive_config'] as Map<String, dynamic>,
            )
          : const ProactiveConfig(),
      stickerConfig: json['sticker_config'] != null
          ? StickerConfig.fromJson(
              json['sticker_config'] as Map<String, dynamic>,
            )
          : const StickerConfig(),
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (syncVersion != null) 'sync_version': syncVersion,
      'id': id,
      'name': name,
      'description': description,
      'system_prompt': systemPrompt,
      'avatar_url': avatarUrl,
      'temperature': temperature,
      'top_p': topP,
      'frequency_penalty': frequencyPenalty,
      'presence_penalty': presencePenalty,
      'max_context_rounds': maxContextRounds,
      'allow_web_search': allowWebSearch,
      'attached_json_content': attachedJsonContent,
      'core_memory': coreMemory,
      'summary_every_n_rounds': summaryEveryNRounds,
      'proactive_config': proactiveConfig.toJson(),
      'sticker_config': stickerConfig.toJson(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static Role fromJsonString(String jsonStr) =>
      Role.fromJson(jsonDecode(jsonStr));
}
