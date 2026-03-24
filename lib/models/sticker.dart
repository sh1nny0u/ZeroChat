/// 单个表情包
class Sticker {
  final String id;
  final String
  emotion; // happy, sad, angry, shy, love, confused, sleepy, surprised, tired
  final String imagePath; // 本地文件路径或网络 URL
  final String? name; // 可选名称

  const Sticker({
    required this.id,
    required this.emotion,
    required this.imagePath,
    this.name,
  });

  factory Sticker.fromJson(Map<String, dynamic> json) {
    return Sticker(
      id: json['id'] as String,
      emotion: json['emotion'] as String,
      imagePath: json['image_path'] as String,
      name: json['name'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'emotion': emotion,
      'image_path': imagePath,
      'name': name,
    };
  }

  Sticker copyWith({
    String? id,
    String? emotion,
    String? imagePath,
    String? name,
  }) {
    return Sticker(
      id: id ?? this.id,
      emotion: emotion ?? this.emotion,
      imagePath: imagePath ?? this.imagePath,
      name: name ?? this.name,
    );
  }
}

/// 表情包配置（角色独立）
class StickerConfig {
  /// 是否启用表情包
  final bool enabled;

  /// 表情包发送概率（0.0-1.0）
  final double sendProbability;

  /// 角色拥有的表情包列表
  final List<Sticker> stickers;

  const StickerConfig({
    this.enabled = false,
    this.sendProbability = 0.3,
    this.stickers = const [],
  });

  /// 默认配置
  factory StickerConfig.defaultConfig() => const StickerConfig();

  /// 按情绪获取表情包
  List<Sticker> getByEmotion(String emotion) {
    return stickers.where((s) => s.emotion == emotion).toList();
  }

  /// 获取所有情绪类型
  Set<String> get emotions => stickers.map((s) => s.emotion).toSet();

  factory StickerConfig.fromJson(Map<String, dynamic> json) {
    return StickerConfig(
      enabled: json['enabled'] as bool? ?? false,
      sendProbability: (json['send_probability'] as num?)?.toDouble() ?? 0.3,
      stickers:
          (json['stickers'] as List<dynamic>?)
              ?.map((s) => Sticker.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'send_probability': sendProbability,
      'stickers': stickers.map((s) => s.toJson()).toList(),
    };
  }

  StickerConfig copyWith({
    bool? enabled,
    double? sendProbability,
    List<Sticker>? stickers,
  }) {
    return StickerConfig(
      enabled: enabled ?? this.enabled,
      sendProbability: sendProbability ?? this.sendProbability,
      stickers: stickers ?? this.stickers,
    );
  }

  /// 添加表情包
  StickerConfig addSticker(Sticker sticker) {
    final newList = List<Sticker>.from(stickers)..add(sticker);
    return copyWith(stickers: newList);
  }

  /// 移除表情包
  StickerConfig removeSticker(String stickerId) {
    final newList = stickers.where((s) => s.id != stickerId).toList();
    return copyWith(stickers: newList);
  }
}

/// 支持的情绪类型
class EmotionTypes {
  static const String happy = 'happy';
  static const String sad = 'sad';
  static const String angry = 'angry';
  static const String shy = 'shy';
  static const String love = 'love';
  static const String confused = 'confused';
  static const String sleepy = 'sleepy';
  static const String neutral = 'neutral';
  static const String surprised = 'surprised';
  static const String excited = 'excited';
  static const String tired = 'tired';

  static const List<String> all = [
    happy,
    sad,
    angry,
    shy,
    love,
    confused,
    sleepy,
    neutral,
    surprised,
    excited,
    tired,
  ];

  static String getDisplayName(String emotion) {
    switch (emotion) {
      case happy:
        return '开心';
      case sad:
        return '难过';
      case angry:
        return '生气';
      case shy:
        return '害羞';
      case love:
        return '喜欢';
      case confused:
        return '困惑';
      case sleepy:
        return '困了';
      case neutral:
        return '平静';
      case surprised:
        return '惊讶';
      case tired:
        return '疲惫';
      default:
        return emotion;
    }
  }
}
