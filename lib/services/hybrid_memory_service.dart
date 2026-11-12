import 'dart:convert';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'entity_sync_service.dart';
import 'session_service.dart';

class HybridMemoryService {
  static Future<Map<String, dynamic>> list({
    String? scope,
    String? ownerId,
    String? category,
    String? status,
    String query = '',
    int offset = 0,
    int limit = 50,
  }) async {
    if (limit > 100) {
      final rows = <dynamic>[];
      Map<String, dynamic>? latest;
      while (rows.length < limit) {
        latest = await list(scope: scope, ownerId: ownerId, category: category, status: status,
          query: query, offset: offset + rows.length, limit: (limit - rows.length).clamp(1, 100));
        final batch = latest['entries'] as List;
        rows.addAll(batch);
        if (latest['has_more'] != true || batch.isEmpty) break;
      }
      return {...latest!, 'entries': rows};
    }
    final uri = Uri.parse('${SessionService.backend}/api/memory/entries')
        .replace(
          queryParameters: {
            'scope': ?scope,
            'owner_id': ?ownerId,
            'category': ?category,
            'status': ?status,
            'q': query,
            'offset': '$offset',
            'limit': '$limit',
          },
        );
    return _decode(await http.get(uri));
  }

  static Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> save(Map<String, dynamic> entry, String? version) async {
    final payload = Map<String, dynamic>.from(entry)
      ..remove('sync_version')
      ..remove('score')
      ..remove('vector_score');
    if (!await EntitySyncService.instance.save(
      'memory_entry',
      payload['id'] as String,
      payload,
      baseVersion: version,
    )) {
      throw StateError('此记忆已在其他设备修改，请到数据同步与备份比较冲突');
    }
  }

  static Future<void> delete(Map<String, dynamic> entry) async {
    if (!await EntitySyncService.instance.save(
      'memory_entry',
      entry['id'] as String,
      {},
      baseVersion: entry['sync_version'] as String?,
      deleted: true,
    )) {
      throw StateError('删除遇到版本冲突，请到数据同步与备份处理');
    }
  }

  static Future<void> sharing(bool value, String? version) async {
    if (!await EntitySyncService.instance.save('memory_policy', 'global', {
      'share_user_facts': value,
    }, baseVersion: version)) {
      throw StateError('共享设置已在其他设备修改，请重新载入');
    }
  }

  static Future<Map<String, dynamic>> status() async => _decode(
    await http.get(Uri.parse('${SessionService.backend}/api/memory/status')),
  );

  static Future<void> rebuild() async {
    _decode(
      await http.post(
        Uri.parse('${SessionService.backend}/api/memory/rebuild'),
      ),
    );
  }

  static Future<void> confirm(Map<String, dynamic> entry) async {
    if ((entry['conflict_of'] as String? ?? '').isNotEmpty) {
      final response = await http.post(
        Uri.parse(
          '${SessionService.backend}/api/memory/entries/${entry['id']}/confirm',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'base_version': entry['sync_version'],
          'operation_id': ApiService.requestId(),
        }),
      );
      _decode(response);
    } else {
      await save({
        ...entry,
        'status': 'confirmed',
      }, entry['sync_version'] as String?);
    }
  }
}
