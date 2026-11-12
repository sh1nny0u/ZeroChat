import 'dart:convert';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'entity_sync_service.dart';
import 'session_service.dart';
import 'storage_service.dart';

class TtsService {
  static final Set<String> _active = {};
  static String path(String? roleId) =>
      '/api/tts/${roleId == null ? 'global' : 'roles/${Uri.encodeComponent(roleId)}'}';
  static const reasons = {
    'disabled': '语音已关闭，保留文字',
    'not_configured': '请先保存豆包 API Key',
    'too_long': '文字超出单条语音长度限制，保留文字',
    'budget': '今日语音额度不足，保留文字',
    'frequency': '语音间隔未到，请稍后手动试听',
    'duplicate': '此请求已受理，请刷新确认',
    'timeout': '合成超时，已保留文字，不会自动重试',
    'provider_failed': '豆包合成失败，请检查音色、资源和凭证，文字已保留',
  };
  static Future<Map<String, dynamic>> _decode(http.Response response) async {
    if (response.statusCode != 200) {
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  static Future<Map<String, dynamic>> load(String? roleId) async => _decode(
    await http.get(Uri.parse('${SessionService.backend}${path(roleId)}')),
  );

  static Future<void> save(
    String? roleId,
    Map<String, dynamic> value,
    String? version,
  ) async {
    if (!await EntitySyncService.instance.save(
      roleId == null ? 'tts_policy' : 'tts_config',
      roleId ?? 'global',
      value,
      baseVersion: version,
    )) {
      throw StateError('其他设备已修改，请到数据同步与备份处理冲突');
    }
  }

  static Future<void> credential(
    String? roleId,
    String key,
    String? revision,
  ) async {
    await _decode(
      await http.put(
        Uri.parse('${SessionService.backend}${path(roleId)}/credentials'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'api_key': key, 'revision': revision}),
      ),
    );
  }

  static Future<Map<String, dynamic>> test(
    String? roleId,
    String requestId,
    String text,
  ) async {
    final scope = '${StorageService.currentScope}:${roleId ?? 'global'}';
    if (!_active.add(scope)) throw StateError('试听正在处理中，请等待并刷新原请求');
    try {
      return await _test(roleId, requestId, text);
    } finally {
      _active.remove(scope);
    }
  }

  static Future<Map<String, dynamic>> _test(
    String? roleId,
    String requestId,
    String text,
  ) async {
    final key = 'tts_pending_${roleId ?? 'global'}';
    final previous = StorageService.getJson(key);
    if (previous != null) {
      final result = await resultFor(previous['id'] as String);
      if (result['status'] == 'ready') {
        await StorageService.remove(key);
        return {
          ...result,
          'request_id': previous['id'],
          'text': previous['text'],
        };
      }
      if (result['state'] != 'missing' && result['state'] != 'failed') {
        throw StateError('上次合成结果未确认，已保留请求编号；请刷新查询，不会重新生成');
      }
      await StorageService.remove(key);
      throw StateError('上次试听未完成，已确认状态；如需新一次收费试听，请再次点击生成');
    }
    await StorageService.setJson(key, {'id': requestId, 'text': text});
    final result = await _decode(
      await http.post(
        Uri.parse('${SessionService.backend}${path(roleId)}/test'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'request_id': requestId, 'text': text}),
      ),
    );
    await StorageService.remove(key);
    return {...result, 'request_id': requestId, 'text': text};
  }

  static Future<Map<String, dynamic>> resultFor(String id) async => _decode(
    await http.get(
      Uri.parse('${SessionService.backend}/api/tts/test-results/$id'),
    ),
  );
}
