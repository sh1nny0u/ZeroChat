import 'dart:convert';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'entity_sync_service.dart';
import 'session_service.dart';

class RoleCapabilityService {
  static Future<Map<String, dynamic>> api(String roleId) async {
    final response = await http.get(
      Uri.parse('${SessionService.backend}/api/roles/$roleId/chat-api'),
    );
    if (response.statusCode != 200) {
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> saveApi(String roleId, Map<String, dynamic> data) async {
    final response = await http.put(
      Uri.parse('${SessionService.backend}/api/roles/$roleId/chat-api'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    if (response.statusCode != 200) {
      if (response.statusCode == 409) {
        throw StateError('角色 API 已在其他设备修改，请重新载入后再保存');
      }
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
  }

  static Future<Map<String, dynamic>> export(String roleId, bool attachment) =>
      _shareRequest('/api/roles/$roleId/share/export', {
        'include_attachment': attachment,
      });
  static Future<Map<String, dynamic>> preview(String code) =>
      _shareRequest('/api/share/preview', {'code': code});

  static Future<Map<String, dynamic>> _shareRequest(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!SessionService.instance.authenticated) throw StateError('请先登录后端');
    final response = await http.post(
      Uri.parse('${SessionService.backend}$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      final detail = data['detail'];
      throw StateError(
        detail is String
            ? detail
            : ApiService.responseError(response.statusCode, response.body),
      );
    }
    return data;
  }

  static Future<void> importRole(Map<String, dynamic> decision) async {
    await _shareRequest('/api/share/import', decision);
    await EntitySyncService.instance.pull();
  }
}
