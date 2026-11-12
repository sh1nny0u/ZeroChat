import 'dart:convert';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'entity_sync_service.dart';
import 'session_service.dart';

class BehaviorService {
  static Future<Map<String, dynamic>> load(String? roleId) async {
    final path = roleId == null
        ? 'policy'
        : 'roles/${Uri.encodeComponent(roleId)}';
    final response = await http.get(
      Uri.parse('${SessionService.backend}/api/behavior/$path'),
    );
    if (response.statusCode != 200) {
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  static Future<void> save(
    String? roleId,
    Map<String, dynamic> value,
    String? version,
  ) async {
    final applied = await EntitySyncService.instance.save(
      roleId == null ? 'behavior_policy' : 'behavior_config',
      roleId ?? 'global',
      value,
      baseVersion: version,
    );
    if (!applied) {
      throw StateError('其他设备已修改，请到设置 → 数据同步与备份处理冲突');
    }
  }
}
