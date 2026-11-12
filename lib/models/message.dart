import 'dart:convert';

/// 消息模型
/// 用于表示聊天中的单条消息
class Message {
  final String id;
  final String senderId;
  final String receiverId;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isRead;
  final String? audioUrl;
  final int? durationMs;

  /// 引用的消息 ID（可为空）
  final String? quotedMessageId;

  /// 引用消息的预览文本
  final String? quotedPreviewText;

  Message({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    this.type = MessageType.text,
    required this.timestamp,
    this.isRead = false,
    this.audioUrl,
    this.durationMs,
    this.quotedMessageId,
    this.quotedPreviewText,
  });

  /// 创建带引用的消息
  factory Message.withQuote({
    required String id,
    required String senderId,
    required String receiverId,
    required String content,
    required Message quotedMessage,
    MessageType type = MessageType.text,
    DateTime? timestamp,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      type: type,
      timestamp: timestamp ?? DateTime.now(),
      quotedMessageId: quotedMessage.id,
      quotedPreviewText: quotedMessage.content.length > 50
          ? '${quotedMessage.content.substring(0, 50)}...'
          : quotedMessage.content,
    );
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      senderId: json['sender_id'] as String,
      receiverId: json['receiver_id'] as String,
      content: json['content'] as String,
      type: MessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MessageType.text,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String).toLocal(),
      isRead: json['is_read'] as bool? ?? false,
      audioUrl: json['audio_url'] as String?,
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      quotedMessageId: json['quoted_message_id'] as String?,
      quotedPreviewText: json['quoted_preview_text'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'content': content,
      'type': type.name,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'is_read': isRead,
      if (audioUrl != null) 'audio_url': audioUrl,
      if (durationMs != null) 'duration_ms': durationMs,
      'quoted_message_id': quotedMessageId,
      'quoted_preview_text': quotedPreviewText,
    };
  }

  /// 序列化为存储字符串（使用 JSON）
  String toStorageString() {
    return jsonEncode(toJson());
  }

  /// 从存储字符串反序列化
  factory Message.fromStorageString(String str) {
    return Message.fromJson(jsonDecode(str) as Map<String, dynamic>);
  }

  /// 复制并修改
  Message copyWith({
    String? id,
    String? senderId,
    String? receiverId,
    String? content,
    MessageType? type,
    DateTime? timestamp,
    bool? isRead,
    String? audioUrl,
    int? durationMs,
    String? quotedMessageId,
    String? quotedPreviewText,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      audioUrl: audioUrl ?? this.audioUrl,
      durationMs: durationMs ?? this.durationMs,
      quotedMessageId: quotedMessageId ?? this.quotedMessageId,
      quotedPreviewText: quotedPreviewText ?? this.quotedPreviewText,
    );
  }

  /// 是否有引用
  bool get hasQuote => quotedMessageId != null;
}

/// 消息类型枚举
enum MessageType {
  text, // 文本消息
  image, // 图片消息
  voice, // 语音消息
  video, // 视频消息
  file, // 文件消息
  sticker, // 表情包消息
}
