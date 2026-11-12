import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'backend_http.dart' as http;
import 'session_service.dart';
import 'api_service.dart';

class BackupService {
  static Future<Map<String, dynamic>> request(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('${SessionService.backend}/api/$path');
    final response = method == 'GET' ? await http.get(uri) : await http.post(uri,
      headers: {'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
    if (response.statusCode != 200) throw StateError(ApiService.responseError(response.statusCode, response.body));
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  static Future<bool> download(String id) async {
    final response = await http.get(Uri.parse('${SessionService.backend}/api/backups/${Uri.encodeComponent(id)}/download'));
    if (response.statusCode != 200) throw StateError('备份下载失败，请手动重试');
    final path = await FilePicker.platform.saveFile(dialogTitle: '保存私密备份', fileName: 'zerochat-$id.zip',
      type: FileType.custom, allowedExtensions: ['zip'], bytes: Uint8List.fromList(response.bodyBytes));
    return path != null;
  }

  static Future<String?> upload() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > 256 * 1024 * 1024) throw StateError('备份超过 256 MiB 限制');
    final request = http.MultipartRequest('POST', Uri.parse('${SessionService.backend}/api/backups/import'));
    if (file.path != null) {
      request.files.add(await http.MultipartFile.fromPath('file', file.path!, filename: 'backup.zip'));
    } else if (file.bytes != null) {
      request.files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: 'backup.zip'));
    } else { throw StateError('无法读取所选备份'); }
    final response = await http.upload(request);
    if (response.statusCode != 200) throw StateError('备份上传或校验失败，原数据未改动');
    return (jsonDecode(response.body) as Map)['id'] as String;
  }
}
