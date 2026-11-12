import 'history_repository.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_service.dart';

/// Read-only export. Restoration is validated in an isolated server directory.
class DataExportService {
  static Future<Map<String, dynamic>> buildExport(Directory documents) async {
    await HistoryRepository.instance?.exportSnapshot(documents);
    final documentRoot = await documents.resolveSymbolicLinks();
    final preferences = StorageService.exportPreferences();
    final files = <Map<String, Object>>[];
    final sourceState = <String, String>{};
    var totalBytes = 0;
    // These are the persistent directories owned by the current client.
    // Network cache is reproducible and deliberately not exported.
    for (final name in ['images', 'stickers', 'history_exports', 'history_backups']) {
      final directory = Directory('${documents.path}/${StorageService.scopedDirectory(name)}');
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) {
          throw const FileSystemException('不支持导出符号链接');
        }
        if (entity is File) {
          final resolved = await entity.resolveSymbolicLinks();
          if (!resolved.startsWith('$documentRoot${Platform.pathSeparator}')) {
            throw const FileSystemException('导出文件超出应用目录');
          }
          final before = await entity.stat();
          totalBytes += before.size;
          if (totalBytes > 128 * 1024 * 1024) {
            throw const FileSystemException('导出超过 128 MiB，请使用设备级私密备份');
          }
          final content = await entity.readAsBytes();
          final after = await entity.stat();
          if (before.size != after.size || before.modified != after.modified) {
            throw const FileSystemException('导出时文件发生变化，请稍后重试');
          }
          sourceState[entity.path] =
              '${after.size}:${after.modified.toIso8601String()}';
          files.add({
            'path': entity.path
                .substring(documents.path.length + 1)
                .replaceAll('\\', '/'),
            'size': content.length,
            'base64': base64Encode(content),
          });
        }
      }
    }
    final currentPreferences = StorageService.exportPreferences();
    if (jsonEncode(currentPreferences) != jsonEncode(preferences)) {
      throw const FileSystemException('导出期间设置或聊天已变化，请稍后重试');
    }
    final currentState = <String, String>{};
    for (final name in ['images', 'stickers', 'history_exports', 'history_backups']) {
      final directory = Directory('${documents.path}/${StorageService.scopedDirectory(name)}');
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) throw const FileSystemException('导出目录发生变化');
        if (entity is File) {
          final stat = await entity.stat();
          currentState[entity.path] =
              '${stat.size}:${stat.modified.toIso8601String()}';
        }
      }
    }
    if (sourceState.length != currentState.length ||
        sourceState.entries.any(
          (entry) => currentState[entry.key] != entry.value,
        )) {
      throw const FileSystemException('导出期间素材已变化，请稍后重试');
    }
    return {
      'format': 'zerochat-client-export',
      'version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'complete': true,
      'contains_credentials': false,
      'preferences': preferences,
      'files': files,
      'excluded': ['network_cache', 'external_files_outside_app_documents'],
    };
  }

  static Future<bool> exportToFile() async {
    final documents = await getApplicationDocumentsDirectory();
    final data = await buildExport(documents);
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: '保存私密数据备份',
      fileName: 'zerochat-client-$timestamp.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
    return saved != null;
  }
}
