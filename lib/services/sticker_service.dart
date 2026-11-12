import 'diagnostics_service.dart';
import 'storage_service.dart';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import '../models/sticker.dart';

/// 表情包管理服务
class StickerService {
  static final Random _random = Random();
  static const String _stickerDirName = 'stickers';

  /// 获取表情包存储目录
  static Future<Directory> getStickerDirectory(String roleId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final stickerDir = Directory('${appDir.path}/${StorageService.scopedDirectory(_stickerDirName)}/$roleId');
    if (!await stickerDir.exists()) {
      await stickerDir.create(recursive: true);
    }
    return stickerDir;
  }

  /// 导入表情包图片
  static Future<Sticker?> importSticker({
    required String roleId,
    required String sourcePath,
    required String emotion,
    String? name,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        DiagnosticsService.event('resources', 'source_file_not_found');
        return null;
      }

      final stickerDir = await getStickerDirectory(roleId);
      final extension = sourcePath.split('.').last;
      final stickerId =
          '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1000)}';
      final targetPath = '${stickerDir.path}/$stickerId.$extension';

      await sourceFile.copy(targetPath);

      return Sticker(
        id: stickerId,
        emotion: emotion,
        imagePath: targetPath,
        name: name,
      );
    } catch (e) {
      DiagnosticsService.event(
        'resources',
        'error_importing_sticker',
        error: e,
      );
      return null;
    }
  }

  /// 删除表情包文件
  static Future<bool> deleteSticker(String imagePath) async {
    try {
      final file = File(imagePath);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      DiagnosticsService.event('resources', 'error_deleting_sticker', error: e);
      return false;
    }
  }

  /// 根据情绪随机选择一个表情包
  static Sticker? pickRandomByEmotion(StickerConfig config, String emotion) {
    final candidates = config.getByEmotion(emotion);
    if (candidates.isEmpty) return null;
    return candidates[_random.nextInt(candidates.length)];
  }

  /// 决定是否发送表情包（基于概率）
  static bool shouldSendSticker(StickerConfig config) {
    if (!config.enabled) return false;
    return _random.nextDouble() < config.sendProbability;
  }

  /// 解析情绪标签并提取内容
  /// 返回 (cleanedText, emotion?)
  static (String, String?) parseEmotionTag(String text) {
    final regex = RegExp(r'\[(\w+)\]\s*');
    final match = regex.firstMatch(text);

    if (match != null) {
      final emotion = match.group(1)!;
      // 验证是否是有效的情绪类型
      if (EmotionTypes.all.contains(emotion)) {
        final cleanedText = text.replaceFirst(regex, '').trim();
        return (cleanedText, emotion);
      }
    }

    return (text, null);
  }

  /// 为表情包消息生成内容标识
  static String createStickerMessageContent(String emotion, String imagePath) {
    return '[STICKER:$emotion:$imagePath]';
  }

  /// 解析表情包消息内容
  /// 返回 (isSticker, emotion?, imagePath?)
  static (bool, String?, String?) parseStickerMessage(String content) {
    final regex = RegExp(r'\[STICKER:(\w+):(.+)\]');
    final match = regex.firstMatch(content);

    if (match != null) {
      return (true, match.group(1), match.group(2));
    }

    return (false, null, null);
  }
}
