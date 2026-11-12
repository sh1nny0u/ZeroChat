/// 群聊模型
class GroupChat {
  final String? syncVersion;
  final String id;
  final String name;
  final String? avatarUrl;
  final List<String> memberIds;
  final String ownerId;
  final DateTime createdAt;

  // 防刷屏设置
  final int cooldownSeconds;
  final int maxRepliesPerMinute;

  // AI 行为设置
  final double aiReplyProbability;
  final bool allowAiToAiInteraction;
  final int maxConsecutiveSpeaks;

  // 群聊专属核心记忆
  final List<String> coreMemory;

  // 核心记忆总结轮数
  final int summaryEveryNRounds;

  GroupChat({
    this.syncVersion,
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.memberIds,
    required this.ownerId,
    DateTime? createdAt,
    this.cooldownSeconds = 5,
    this.maxRepliesPerMinute = 10,
    this.aiReplyProbability = 0.6,
    this.allowAiToAiInteraction = true,
    this.maxConsecutiveSpeaks = 2,
    List<String>? coreMemory,
    this.summaryEveryNRounds = 20,
  }) : coreMemory = coreMemory ?? [],
       createdAt = createdAt ?? DateTime.now();

  GroupChat copyWith({
    String? id,
    String? name,
    String? avatarUrl,
    List<String>? memberIds,
    String? ownerId,
    int? cooldownSeconds,
    int? maxRepliesPerMinute,
    double? aiReplyProbability,
    bool? allowAiToAiInteraction,
    int? maxConsecutiveSpeaks,
    List<String>? coreMemory,
    int? summaryEveryNRounds,
  }) {
    return GroupChat(
      syncVersion: syncVersion,
      id: id ?? this.id,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      memberIds: memberIds ?? this.memberIds,
      ownerId: ownerId ?? this.ownerId,
      createdAt: createdAt,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      maxRepliesPerMinute: maxRepliesPerMinute ?? this.maxRepliesPerMinute,
      aiReplyProbability: aiReplyProbability ?? this.aiReplyProbability,
      allowAiToAiInteraction:
          allowAiToAiInteraction ?? this.allowAiToAiInteraction,
      maxConsecutiveSpeaks: maxConsecutiveSpeaks ?? this.maxConsecutiveSpeaks,
      coreMemory: coreMemory ?? this.coreMemory,
      summaryEveryNRounds: summaryEveryNRounds ?? this.summaryEveryNRounds,
    );
  }

  /// 添加核心记忆
  GroupChat addCoreMemory(String memory) {
    final newMemory = List<String>.from(coreMemory);
    if (!newMemory.contains(memory)) {
      newMemory.add(memory);
    }
    return copyWith(coreMemory: newMemory);
  }

  /// 添加多条核心记忆
  GroupChat addCoreMemories(List<String> memories) {
    final newMemory = List<String>.from(coreMemory);
    for (final memory in memories) {
      if (!newMemory.contains(memory) && memory.isNotEmpty) {
        newMemory.add(memory);
      }
    }
    return copyWith(coreMemory: newMemory);
  }

  /// 清空核心记忆
  GroupChat clearCoreMemory() {
    return copyWith(coreMemory: []);
  }

  /// 删除单条核心记忆
  GroupChat removeCoreMemory(int index) {
    if (index < 0 || index >= coreMemory.length) return this;
    final newMemory = List<String>.from(coreMemory);
    newMemory.removeAt(index);
    return copyWith(coreMemory: newMemory);
  }

  Map<String, dynamic> toJson() {
    return {
      if (syncVersion != null) 'sync_version': syncVersion,
      'id': id,
      'name': name,
      'avatar_url': avatarUrl,
      'member_ids': memberIds,
      'owner_id': ownerId,
      'created_at': createdAt.toIso8601String(),
      'cooldown_seconds': cooldownSeconds,
      'max_replies_per_minute': maxRepliesPerMinute,
      'ai_reply_probability': aiReplyProbability,
      'allow_ai_to_ai_interaction': allowAiToAiInteraction,
      'max_consecutive_speaks': maxConsecutiveSpeaks,
      'core_memory': coreMemory,
      'summary_every_n_rounds': summaryEveryNRounds,
    };
  }

  factory GroupChat.fromJson(Map<String, dynamic> json) {
    return GroupChat(
      syncVersion: json['sync_version'] as String?,
      id: json['id'] as String,
      name: json['name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      memberIds: (json['member_ids'] as List<dynamic>).cast<String>(),
      ownerId: json['owner_id'] as String? ?? 'user',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      cooldownSeconds: json['cooldown_seconds'] as int? ?? 5,
      maxRepliesPerMinute: json['max_replies_per_minute'] as int? ?? 10,
      aiReplyProbability:
          (json['ai_reply_probability'] as num?)?.toDouble() ?? 0.6,
      allowAiToAiInteraction:
          json['allow_ai_to_ai_interaction'] as bool? ?? true,
      maxConsecutiveSpeaks: json['max_consecutive_speaks'] as int? ?? 2,
      coreMemory: (json['core_memory'] as List<dynamic>?)?.cast<String>() ?? [],
      summaryEveryNRounds: json['summary_every_n_rounds'] as int? ?? 20,
    );
  }
}
