/// 意图类型枚举
enum IntentType {
  normalChat, // 普通聊天
  setMemory, // 设定记忆："记住我喜欢猫"
  setReminder, // 设定提醒："10分钟后提醒我喝水"
  setQuietTime, // 设定安静时间："晚上11点到早上7点不要打扰我"
  clearMemory, // 清除记忆："忘记我说过的话"
}

/// 意图识别结果
class IntentResult {
  final IntentType type;
  final String? extractedContent;
  final Duration? duration;
  final int? startHour;
  final int? endHour;
  final double confidence;

  IntentResult({
    required this.type,
    this.extractedContent,
    this.duration,
    this.startHour,
    this.endHour,
    this.confidence = 1.0,
  });

  @override
  String toString() {
    return 'IntentResult(type: $type, content: $extractedContent, confidence: $confidence)';
  }
}

/// 意图识别由后端聊天事件执行；旧入口仅保留接口兼容。
class IntentService {
  static bool useAiIntent = false;
  static void configure({
    required String apiUrl,
    required String apiKey,
    String model = 'gpt-3.5-turbo',
    bool useAi = false,
  }) {
    useAiIntent = useAi;
  }

  static Future<IntentResult> detectIntent(String message) async =>
      IntentResult(type: IntentType.normalChat);
}
