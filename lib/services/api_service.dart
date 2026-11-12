import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'backend_http.dart' as http;
import 'session_service.dart';
import '../models/role.dart';

/// Every model request goes through the authenticated backend.
class ApiService {
  static int maxContextRounds = 10;
  static String get _backendUrl => SessionService.backend;
  static String requestId() => List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  static String get currentModel => '后端配置';
  static bool get isConfigured => SessionService.instance.authenticated;
  static void configure({required String baseUrl, required String apiKey, String model = '', int maxRounds = 10}) { maxContextRounds = maxRounds; }
  static void setApiKey(String key) {}
  static void setBaseUrl(String url) {}
  static void setModel(String model) {}

  static String responseError(int status, String body) {
    if (status == 401) return '登录已失效，请重新登录';
    if (status == 409) return '请求已受理，请刷新聊天记录确认结果；不会重复调用供应商';
    if (status == 429) return '请求过于频繁，请稍后手动重试';
    try {
      final data = jsonDecode(body) as Map;
      final value = data['detail'] ?? data['error'];
      if (value is String) return value;
    } catch (_) {}
    return '后端请求失败（$status），请手动重试';
  }

  static Future<Map<String, dynamic>> request(String path, Map<String, dynamic> body) async {
    if (!SessionService.instance.authenticated) throw StateError('请先登录后端');
    final response = await http.post(Uri.parse('$_backendUrl$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (response.statusCode != 200) throw StateError(responseError(response.statusCode, response.body));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> requestDelete(String path) async {
    final response = await http.delete(Uri.parse('$_backendUrl$path'));
    if (response.statusCode != 200) throw StateError(responseError(response.statusCode, response.body));
  }

  static Future<ApiResponse> callBackendAI({required String roleId, required String eventType, String content = '', Map<String, dynamic>? context, String? operationId, String? quoteId, String? quoteContent}) async {
    try {
      final data = await request('/api/ai/event', {'request_id': operationId ?? requestId(), 'role_id': roleId, 'event_type': eventType, 'content': content, 'context': context ?? {}, 'quote_id': quoteId, 'quote_content': quoteContent});
      if (data['success'] == true) return ApiResponse._(success: true, content: data['content'] as String?, metadata: Map<String, dynamic>.from(data['metadata'] ?? {}));
      return ApiResponse.error(data['error'] as String? ?? '供应商处理失败，请检查后端配置后手动重试');
    } catch (error) { return ApiResponse.error('请求失败：$error。请检查连接，刷新记录后手动重试'); }
  }

  static Future<ApiResponse> sendChatViaBackend({required String roleId, required String message, String? operationId, String? quoteId, String? quoteContent}) => callBackendAI(roleId: roleId, eventType: 'chat', content: message, operationId: operationId, quoteId: quoteId, quoteContent: quoteContent);

  static Future<ApiResponse> sendChatMessageWithRole({required String message, required Role role, List<Map<String, String>>? history, List<String>? coreMemory, bool isGroup = false}) => callBackendAI(roleId: role.id, eventType: 'chat', content: message);

  static Future<ApiResponse> sendChatMessage({required String message, String? systemPrompt, List<Map<String, String>>? history, List<String>? coreMemory}) async {
    try {
      final data = await request('/api/ai/completion', {'request_id': requestId(), 'message': message, 'system_prompt': systemPrompt ?? ''});
      return data['success'] == true ? ApiResponse.success(data['content'] as String) : ApiResponse.error(data['error'] as String? ?? '供应商调用失败');
    } catch (error) { return ApiResponse.error('后端连接失败：$error'); }
  }
  static Future<ApiResponse> quickChat(String message) => sendChatMessage(message: message);

  static Future<bool> isBackendAvailable() async {
    try { return (await http.get(Uri.parse('$_backendUrl/api/health')).timeout(const Duration(seconds: 5))).statusCode == 200; }
    catch (_) { return false; }
  }

  static Future<Map<String, dynamic>> chatWithImage({required String imagePath, required String roleId, required String chatId, required String operationId}) async {
    if (await File(imagePath).length() > 9 * 1024 * 1024) throw StateError('图片超过 9 MiB，请选择较小的图片');
    final image = base64Encode(await File(imagePath).readAsBytes());
    return request('/api/chat/vision', {'request_id': operationId, 'image_base64': image, 'role_id': roleId, 'chat_id': chatId,
      'mime_type': imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg',
      'user_prompt': '用户发送了一张图片，请以角色身份自然回应。'});
  }

}

class ApiResponse {
  final bool success;
  final String? content;
  final String? error;
  final Map<String, dynamic> metadata;
  ApiResponse._({required this.success, this.content, this.error, this.metadata = const {}});
  factory ApiResponse.success(String content) => ApiResponse._(success: true, content: content);
  factory ApiResponse.error(String error) => ApiResponse._(success: false, error: error);
}
