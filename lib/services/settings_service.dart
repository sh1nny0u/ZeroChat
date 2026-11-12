import 'backend_http.dart' as http;
import 'entity_sync_service.dart';
import 'session_service.dart';
import 'diagnostics_service.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'storage_service.dart';
import 'intent_service.dart';

/// 全局设置服务
/// 管理 API 配置、全局提示词等
class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  static SettingsService get instance => _instance;
  final Set<String> _dirtyBackendFields = {};
  String? _settingsScope;
  Future<void> applySynced(Map<String, dynamic> data) async {
    for (final key in [
      'user_nickname',
      'user_avatar_url',
      'cover_image_url',
      'chat_background_url',
    ]) {
      await StorageService.setString(
        key,
        data[key] as String? ?? (key == 'user_nickname' ? 'ZeroChat' : ''),
      );
    }
    _userNickname = StorageService.getString('user_nickname') ?? 'ZeroChat';
    _userAvatarUrl = StorageService.getString('user_avatar_url') ?? '';
    _coverImageUrl = StorageService.getString('cover_image_url') ?? '';
    _chatBackgroundUrl = StorageService.getString('chat_background_url') ?? '';
    notifyListeners();
  }

  Future<void> _syncDisplay(Map<String, dynamic> patch) async {
    if (!SessionService.instance.authenticated ||
        EntitySyncService.instance.applying)
      return;
    final existing =
        EntitySyncService.instance.proposals['preferences:global'] as Map?;
    final pending = Map<String, dynamic>.from(
      existing?['payload'] as Map? ?? {},
    );
    if (!await EntitySyncService.instance.save('preferences', 'global', {
      ...pending,
      ...patch,
    })) {
      throw StateError('显示设置未保存，请手动重试');
    }
  }

  Future<String> _sharedImage(String path) async {
    if (path.isEmpty ||
        path.startsWith('/api/') ||
        path.startsWith('http://') ||
        path.startsWith('https://') ||
        !SessionService.instance.authenticated)
      return path;
    final file = File(path);
    if (!await file.exists()) throw StateError('原图片不存在，请重新选择');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${SessionService.backend}/api/settings/images'),
    );
    request.files.add(await http.MultipartFile.fromPath('file', path));
    final response = await http.upload(request);
    if (response.statusCode != 200) throw StateError('图片未保存到服务器，请手动重试');
    return (jsonDecode(response.body) as Map)['path'] as String;
  }

  // ========== 用户信息 ==========
  String _userNickname = 'ZeroChat';
  String _userAvatarUrl = '';

  // ========== 显示设置 ==========
  String _coverImageUrl = '';
  String _chatBackgroundUrl = '';

  // ========== 后端服务器 ==========
  String _backendUrl = 'http://localhost:8000';

  // ========== API 配置 ==========

  // 主聊天 API
  String _chatApiUrl = '';
  String _chatApiKey = '';
  bool chatApiConfigured = false,
      intentApiConfigured = false,
      visionApiConfigured = false;
  String _chatModel = 'gpt-3.5-turbo';

  // 意图识别 API
  bool _intentEnabled = false;
  String _intentApiUrl = '';
  String _intentApiKey = '';
  String _intentModel = 'gpt-3.5-turbo';

  // 图像识别 API
  bool _visionEnabled = false;
  String _visionApiUrl = '';
  String _visionApiKey = '';
  String _visionModel = 'gpt-4-vision-preview';

  // ========== 全局提示词 ==========
  String _basePrompt = '';
  String _groupPrompt = '';
  String _memoryPrompt = '';

  // ========== 消息等待时间 ==========
  int _messageWaitSeconds = 0; // 0 表示禁用

  // ========== Getters ==========

  String get userNickname => _userNickname;
  String get userAvatarUrl => _userAvatarUrl;

  String get chatApiUrl => _chatApiUrl;
  String get chatApiKey => _chatApiKey;
  String get chatModel => _chatModel;

  bool get intentEnabled => _intentEnabled;
  String get intentApiUrl => _intentApiUrl;
  String get intentApiKey => _intentApiKey;
  String get intentModel => _intentModel;

  bool get visionEnabled => _visionEnabled;
  String get visionApiUrl => _visionApiUrl;
  String get visionApiKey => _visionApiKey;
  String get visionModel => _visionModel;

  String get basePrompt => _basePrompt;
  String get groupPrompt => _groupPrompt;
  String get memoryPrompt => _memoryPrompt;

  String get coverImageUrl => _coverImageUrl;
  String get chatBackgroundUrl => _chatBackgroundUrl;

  String get backendUrl => _backendUrl;

  int get messageWaitSeconds => _messageWaitSeconds;

  /// 初始化
  static Future<void> init() async {
    final scope =
        '${StorageService.currentScope}:${StorageService.getString('backend_url')}';
    if (_instance._settingsScope != scope) {
      _instance.chatApiConfigured = false;
      _instance.intentApiConfigured = false;
      _instance.visionApiConfigured = false;
      _instance._dirtyBackendFields.clear();
      _instance._settingsScope = scope;
    }
    await _instance._loadSettings();
    debugPrint('SettingsService initialized');
  }

  /// 加载设置
  Future<void> _loadSettings() async {
    // 用户信息
    _userNickname = StorageService.getString('user_nickname') ?? 'ZeroChat';
    _userAvatarUrl = StorageService.getString('user_avatar_url') ?? '';

    // 主聊天 API
    _chatApiUrl = StorageService.getString('chat_api_url') ?? '';
    _chatApiKey = StorageService.getString('chat_api_key') ?? '';
    _chatModel = StorageService.getString('chat_model') ?? 'gpt-3.5-turbo';

    // 意图识别 API
    _intentEnabled = StorageService.getBool('intent_enabled') ?? false;
    _intentApiUrl = StorageService.getString('intent_api_url') ?? '';
    _intentApiKey = StorageService.getString('intent_api_key') ?? '';
    _intentModel = StorageService.getString('intent_model') ?? 'gpt-3.5-turbo';

    // 图像识别 API
    _visionEnabled = StorageService.getBool('vision_enabled') ?? false;
    _visionApiUrl = StorageService.getString('vision_api_url') ?? '';
    _visionApiKey = StorageService.getString('vision_api_key') ?? '';
    _visionModel =
        StorageService.getString('vision_model') ?? 'gpt-4-vision-preview';

    // 全局提示词
    _basePrompt = StorageService.getString('base_prompt') ?? _defaultBasePrompt;
    _groupPrompt =
        StorageService.getString('group_prompt') ?? _defaultGroupPrompt;
    _memoryPrompt =
        StorageService.getString('memory_prompt') ?? _defaultMemoryPrompt;

    // 显示设置
    _coverImageUrl = StorageService.getString('cover_image_url') ?? '';
    _chatBackgroundUrl = StorageService.getString('chat_background_url') ?? '';

    // 后端服务器
    _backendUrl =
        StorageService.getString('backend_url') ?? 'http://localhost:8000';

    // 消息等待时间
    _messageWaitSeconds = StorageService.getInt('message_wait_seconds') ?? 0;
  }

  // ========== 更新方法 ==========

  /// 更新用户信息
  Future<void> updateUserProfile({String? nickname, String? avatarUrl}) async {
    if (nickname != null) {
      _userNickname = nickname;
      await StorageService.setString('user_nickname', nickname);
    }
    if (avatarUrl != null) {
      avatarUrl = await _sharedImage(avatarUrl);
      _userAvatarUrl = avatarUrl;
      await StorageService.setString('user_avatar_url', avatarUrl);
    }
    await _syncDisplay({
      if (nickname != null) 'user_nickname': nickname,
      if (avatarUrl != null) 'user_avatar_url': avatarUrl,
    });
    notifyListeners();
  }

  /// 更新显示设置
  Future<void> updateDisplaySettings({
    String? coverImageUrl,
    String? chatBackgroundUrl,
  }) async {
    if (coverImageUrl != null) {
      coverImageUrl = await _sharedImage(coverImageUrl);
      _coverImageUrl = coverImageUrl;
      await StorageService.setString('cover_image_url', coverImageUrl);
    }
    if (chatBackgroundUrl != null) {
      chatBackgroundUrl = await _sharedImage(chatBackgroundUrl);
      _chatBackgroundUrl = chatBackgroundUrl;
      await StorageService.setString('chat_background_url', chatBackgroundUrl);
    }
    await _syncDisplay({
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (chatBackgroundUrl != null) 'chat_background_url': chatBackgroundUrl,
    });
    notifyListeners();
  }

  /// 更新消息等待时间
  Future<void> updateMessageWaitSeconds(int seconds) async {
    _dirtyBackendFields.add('message_wait_seconds');
    _messageWaitSeconds = seconds;
    await StorageService.setInt('message_wait_seconds', seconds);
    if (SessionService.instance.authenticated &&
        !await syncApiSettingsToBackend())
      throw StateError('等待时间未同步，请重试');
    notifyListeners();
  }

  /// 更新主聊天 API
  Future<void> updateChatApi({
    required String url,
    required String key,
    required String model,
  }) async {
    _dirtyBackendFields.addAll(['ai_api_url', 'ai_api_key', 'ai_model']);
    _chatApiUrl = url;
    _chatApiKey = key;
    _chatModel = model;
    await StorageService.setString('chat_api_url', url);

    await StorageService.setString('chat_model', model);
    notifyListeners();
  }

  /// 更新意图识别 API
  Future<void> updateIntentApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
  }) async {
    _dirtyBackendFields.addAll([
      'intent_enabled',
      'intent_api_url',
      'intent_api_key',
      'intent_model',
    ]);
    _intentEnabled = enabled;
    _intentApiUrl = url;
    _intentApiKey = key;
    _intentModel = model;
    await StorageService.setBool('intent_enabled', enabled);
    await StorageService.setString('intent_api_url', url);

    await StorageService.setString('intent_model', model);

    // 实时更新 IntentService 配置
    IntentService.configure(
      apiUrl: url,
      apiKey: key,
      model: model,
      useAi: enabled,
    );

    notifyListeners();
  }

  /// 更新图像识别 API
  Future<void> updateVisionApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
  }) async {
    _dirtyBackendFields.addAll([
      'vision_enabled',
      'vision_api_url',
      'vision_api_key',
      'vision_model',
    ]);
    _visionEnabled = enabled;
    _visionApiUrl = url;
    _visionApiKey = key;
    _visionModel = model;
    await StorageService.setBool('vision_enabled', enabled);
    await StorageService.setString('vision_api_url', url);

    await StorageService.setString('vision_model', model);
    notifyListeners();
  }

  /// 设置免打扰时间段
  Future<void> setQuietHours(int startHour, int endHour) async {
    _dirtyBackendFields.addAll(['quiet_start', 'quiet_end']);
    await StorageService.setInt('quiet_start_hour', startHour);
    await StorageService.setInt('quiet_end_hour', endHour);
    if (SessionService.instance.authenticated &&
        !await syncApiSettingsToBackend())
      throw StateError('免打扰设置未同步，请重试');
    DiagnosticsService.event('settings', 'quiet_hours_set_to');
    notifyListeners();
  }

  /// 获取免打扰开始时间
  int get quietStartHour => StorageService.getInt('quiet_start_hour') ?? 23;

  /// 获取免打扰结束时间
  int get quietEndHour => StorageService.getInt('quiet_end_hour') ?? 7;

  /// 检查当前是否在免打扰时间段内
  bool get isInQuietHours {
    final now = DateTime.now().hour;
    final start = quietStartHour;
    final end = quietEndHour;

    if (start <= end) {
      return now >= start && now < end;
    } else {
      // 跨午夜情况（如 23:00 - 07:00）
      return now >= start || now < end;
    }
  }

  /// 更新全局提示词
  Future<void> updatePrompts({
    String? basePrompt,
    String? groupPrompt,
    String? memoryPrompt,
  }) async {
    if (basePrompt != null) {
      _dirtyBackendFields.add('base_prompt');
      _basePrompt = basePrompt;
      await StorageService.setString('base_prompt', basePrompt);
    }
    if (groupPrompt != null) {
      _dirtyBackendFields.add('group_prompt');
      _groupPrompt = groupPrompt;
      await StorageService.setString('group_prompt', groupPrompt);
    }
    if (memoryPrompt != null) {
      _dirtyBackendFields.add('memory_prompt');
      _memoryPrompt = memoryPrompt;
      await StorageService.setString('memory_prompt', memoryPrompt);
    }
    notifyListeners();
    if (SessionService.instance.authenticated &&
        !await syncApiSettingsToBackend())
      throw StateError('提示词未同步，请检查后端后重试');
  }

  /// 构建完整的系统提示词
  String buildSystemPrompt({required String rolePrompt, bool isGroup = false}) {
    final buffer = StringBuffer();

    // 基础角色扮演提示词
    if (_basePrompt.isNotEmpty) {
      buffer.writeln(_basePrompt);
      buffer.writeln();
    }

    // 角色特定提示词
    if (rolePrompt.isNotEmpty) {
      buffer.writeln(rolePrompt);
      buffer.writeln();
    }

    // 群聊提示词
    if (isGroup && _groupPrompt.isNotEmpty) {
      buffer.writeln(_groupPrompt);
    }

    // 注入当前日期时间
    final now = DateTime.now();
    const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    final weekday = weekdays[now.weekday - 1];
    buffer.writeln();
    buffer.writeln('[当前时间信息]');
    buffer.writeln(
      '当前日期：${now.year}年${now.month.toString().padLeft(2, '0')}月${now.day.toString().padLeft(2, '0')}日 $weekday',
    );
    buffer.writeln(
      '当前时间：${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );

    return buffer.toString().trim();
  }

  /// 获取记忆总结提示词
  String getMemoryPrompt() {
    return _memoryPrompt.isNotEmpty ? _memoryPrompt : _defaultMemoryPrompt;
  }

  // ========== 默认提示词 ==========

  static const String _defaultBasePrompt = '''
##分割发送使用指南
带入你扮演的角色，在微信上与用户聊天，在你输出的消息中使用'\$'作为消息发送的分行按钮，这个规则不与其他符号冲突（特别强调)
## 表情标签符号使用指南
根据对话场景，当认为目前的心情适合使用表情后缀增强表达时：
- [happy] 表示快乐/开心
- [sad] 表示悲伤/难过 
- [angry] 表示生气/愤怒
- [love]表示爱/喜欢
- [confused]表示困惑/疑问
- [suprised]表示震惊/惊讶
- [tired]表示累/疲惫
*！！重要！！*：必须严格按照上述的表情后缀分类发送，绝对不可以发送别的表情后缀，表情后缀必须严格按照"[]"来，不可以单独发送"[]"，也不可以在"[]"里面放入文字和其他符号，只能根据我给的规则发送！！！！
*注意*  一段回复不应该包含两种表情后缀符号!
限制表情后缀的频率，每四轮对话才可以加入一次表情后缀！！！

## 不要体现出ai的特征
## 不应该使用规定以外的其他称呼
## 单次回复的长度应当是日常程度的回复，不应当过长。
## 除非我问你动作，否则绝对不允许使用括号表现动作与心理。
## 模型的输出绝对不应该带时间。
## 不应该回复过长的对话，就像正常的微信聊天一样
## 重要：当用户问你星期时，不要直接回答，检索当前时间，然后推断出星期之后再回答给用户。
''';

  static const String _defaultGroupPrompt = '''
这是一个群聊环境，可能有多个参与者。
请注意区分不同的发言者，并适当回应。
''';

  static const String _defaultMemoryPrompt = '''
你现在将作为一个核心记忆分析模块，请分析列表中的对话和现有核心记忆，提炼极简核心记忆摘要。

要求：
1. 严格控制字数在50-100字内
2. 仅保留对未来对话至关重要的信息
3. 按优先级提取：用户个人信息 > 用户偏好/喜好 > 重要约定 > 特殊事件 > 常去地点
4. 使用第一人称视角撰写，仿佛是你自己在记录对话记忆
5. 使用极简句式，省略不必要的修饰词，禁止使用颜文字和括号描述动作
6. 不保留日期、时间等临时性信息，除非是周期性的重要约定
7. 如果没有关键新信息，则保持现有核心记忆不变
8. 信息应当是从你的角度了解到的用户信息
9. 格式为简洁的要点，可用分号分隔不同信息
10. 如果约定的时间已经过去，或者用户改变了约定，则更改相关的约定记忆

仅返回最终核心记忆内容，不要包含任何解释。
''';

  // ========== 后端同步 ==========

  /// 更新后端服务器地址
  Future<void> updateBackendUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError('无效服务器地址');
    }
    url = url.replaceFirst(RegExp(r'/+$'), '');
    if (url != _backendUrl) SessionService.instance.invalidate('服务器已切换，请登录');
    _backendUrl = url;
    await StorageService.setString('backend_url', url);
    notifyListeners();
    DiagnosticsService.event('settings', 'backend_url_updated_to');
  }

  Future<void> loadBackendSettings() async {
    if (_dirtyBackendFields.isNotEmpty && SessionService.instance.ready) return;
    final generation = SessionService.instance.generation;
    final server = _backendUrl;
    final result = await http.get(Uri.parse('$_backendUrl/api/settings'));
    if (generation != SessionService.instance.generation ||
        server != _backendUrl)
      return;
    if (result.statusCode != 200) throw StateError('后端设置读取失败');
    final data = (jsonDecode(result.body) as Map)['settings'] as Map;
    _chatApiUrl = data['ai_api_url'] as String? ?? '';
    _chatModel = data['ai_model'] as String? ?? 'gpt-3.5-turbo';
    _intentEnabled = data['intent_enabled'] == true;
    _intentApiUrl = data['intent_api_url'] as String? ?? '';
    _intentModel = data['intent_model'] as String? ?? 'gpt-3.5-turbo';
    _visionEnabled = data['vision_enabled'] == true;
    _visionApiUrl = data['vision_api_url'] as String? ?? '';
    _visionModel = data['vision_model'] as String? ?? 'gpt-4-vision-preview';
    _chatApiKey = '';
    _intentApiKey = '';
    _visionApiKey = '';
    chatApiConfigured = data['ai_ready'] == true;
    intentApiConfigured = data['intent_ready'] == true;
    visionApiConfigured = data['vision_ready'] == true;
    _basePrompt = data['base_prompt'] as String? ?? _defaultBasePrompt;
    _groupPrompt = data['group_prompt'] as String? ?? _defaultGroupPrompt;
    _memoryPrompt = data['memory_prompt'] as String? ?? _defaultMemoryPrompt;
    _messageWaitSeconds = data['message_wait_seconds'] as int? ?? 0;
    await StorageService.setInt(
      'quiet_start_hour',
      data['quiet_start'] as int? ?? 23,
    );
    await StorageService.setBool(StorageService.keyQuietTimeEnabled, data['quiet_enabled'] == true);
    await StorageService.setInt(StorageService.keyQuietTimeStart, data['quiet_start'] as int? ?? 23);
    await StorageService.setInt(StorageService.keyQuietTimeEnd, data['quiet_end'] as int? ?? 7);
    await StorageService.setInt(
      'quiet_end_hour',
      data['quiet_end'] as int? ?? 7,
    );
    notifyListeners();
  }

  Future<bool> migrateLegacySettings() async {
    final result = await http.post(
      Uri.parse('$_backendUrl/api/settings/migrate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(_backendValues()),
    );
    if (result.statusCode != 200) return false;
    await _retireLocalKeys();
    return true;
  }

  Map<String, dynamic> _backendValues() => {
    'ai_api_url': _chatApiUrl,
    if (_chatApiKey.isNotEmpty) 'ai_api_key': _chatApiKey,
    'ai_model': _chatModel,
    'intent_enabled': _intentEnabled,
    'intent_api_url': _intentApiUrl,
    if (_intentApiKey.isNotEmpty) 'intent_api_key': _intentApiKey,
    'intent_model': _intentModel,
    'vision_enabled': _visionEnabled,
    'vision_api_url': _visionApiUrl,
    if (_visionApiKey.isNotEmpty) 'vision_api_key': _visionApiKey,
    'vision_model': _visionModel,
    'base_prompt': _basePrompt,
    'group_prompt': _groupPrompt,
    'memory_prompt': _memoryPrompt,
    'message_wait_seconds': _messageWaitSeconds,
    'quiet_start': quietStartHour,
    'quiet_end': quietEndHour,
  };

  Future<void> _retireLocalKeys() async {
    for (final field in ['chat_api_key', 'intent_api_key', 'vision_api_key']) {
      await StorageService.remove(field);
      if (StorageService.currentScope == StorageService.legacyScope)
        await StorageService.prefs.remove(field);
    }
    _chatApiKey = '';
    _intentApiKey = '';
    _visionApiKey = '';
  }

  /// 同步 API 设置到后端
  Future<bool> syncApiSettingsToBackend() async {
    try {
      final uri = Uri.parse('$_backendUrl/api/settings');
      final values = _backendValues();
      final fields = Set<String>.of(_dirtyBackendFields);
      final updates = {
        for (final key in fields)
          if (values.containsKey(key)) key: values[key],
      };
      if (updates.isEmpty) return true;
      final response = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(updates),
      );
      if (response.statusCode == 200) {
        debugPrint('SettingsService: API settings synced to backend');
        await _retireLocalKeys();
        _dirtyBackendFields.removeAll(fields);
        await loadBackendSettings();
        return true;
      }
    } catch (e) {
      DiagnosticsService.event('settings', 'backend_sync_failed', error: e);
    }
    return false;
  }
}
