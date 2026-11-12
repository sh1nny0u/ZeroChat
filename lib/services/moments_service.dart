import 'backend_http.dart' as http;
import 'diagnostics_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/moment_post.dart';
import 'storage_service.dart';
import 'settings_service.dart';
import 'api_service.dart';
import 'package:crypto/crypto.dart';

/// 朋友圈服务
/// 管理朋友圈动态的增删查改
class MomentsService extends ChangeNotifier {
  static final MomentsService _instance = MomentsService._internal();
  factory MomentsService() => _instance;
  MomentsService._internal();

  static MomentsService get instance => _instance;

  static const String _storageKey = 'moments_posts';

  List<MomentPost> _posts = [];
  Future<String> _operation(String payload) async {
    final key = sha256.convert(utf8.encode(payload)).toString();
    final values = Map<String, String>.from(StorageService.getJson('pending_moment_operations') ?? {});
    if (!values.containsKey(key)) {
      values[key] = ApiService.requestId();
      await StorageService.setJson('pending_moment_operations', values);
    }
    return values[key]!;
  }

  Future<void> _done(String payload) async {
    final values = Map<String, String>.from(StorageService.getJson('pending_moment_operations') ?? {});
    values.remove(sha256.convert(utf8.encode(payload)).toString());
    await StorageService.setJson('pending_moment_operations', values);
  }

  /// 获取所有动态（按时间倒序）
  List<MomentPost> get posts => List.unmodifiable(_posts);

  /// 未读数量（预留）
  int _unreadCount = 0;
  int get unreadCount => _unreadCount;

  /// 初始化
  static Future<void> init() async {
    await instance._loadPosts();
    DiagnosticsService.event('behavior', 'loaded');
  }

  /// 加载动态
  Future<void> _loadPosts() async {
    _posts = [];
    final jsonList = StorageService.getJsonList(_storageKey);
    if (jsonList != null) {
      _posts = jsonList.map((json) => MomentPost.fromJson(json)).toList();
      // 按时间倒序
      _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  /// 保存动态
  Future<void> _savePosts() async {
    final jsonList = _posts.map((p) => p.toJson()).toList();
    await StorageService.setJsonList(_storageKey, jsonList);
  }

  /// 发布动态（用户）
  Future<MomentPost> publishPost({
    required String content,
    List<String> imageUrls = const [],
    String? stickerPath,
  }) async {
    final type = stickerPath != null
        ? MomentType.textWithSticker
        : imageUrls.isNotEmpty
        ? MomentType.textWithImages
        : MomentType.text;

    final payload = jsonEncode(['post', content, imageUrls, stickerPath]);
    final post = MomentPost(
      id: await _operation(payload),
      authorId: 'me',
      authorName: '我',
      content: content,
      imageUrls: imageUrls,
      stickerPath: stickerPath,
      createdAt: DateTime.now(),
      type: type,
    );

    if (!await publishToBackend(post)) throw StateError('动态未发布，请恢复后端连接后手动重试，内容已保留');
    _posts.removeWhere((p) => p.id == post.id);
    _posts.insert(0, post);
    await _savePosts();
    notifyListeners();

    // 自动同步到后端
    await _done(payload);
    DiagnosticsService.event('behavior', 'published_user_post');
    return post;
  }

  /// 发布动态（AI 角色）- 预留入口
  Future<MomentPost> publishAIPost({
    required String roleId,
    required String roleName,
    String? roleAvatarUrl,
    required String content,
    String? stickerPath,
  }) async {
    final type = stickerPath != null
        ? MomentType.textWithSticker
        : MomentType.text;

    final post = MomentPost(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      authorId: roleId,
      authorName: roleName,
      authorAvatarUrl: roleAvatarUrl,
      content: content,
      stickerPath: stickerPath,
      createdAt: DateTime.now(),
      type: type,
    );

    _posts.insert(0, post);
    _unreadCount++;
    await _savePosts();
    notifyListeners();

    // 自动同步到后端
    await publishToBackend(post);
    DiagnosticsService.event('behavior', 'published_ai_post_from');
    return post;
  }

  /// 删除动态
  Future<void> deletePost(String postId) async {
    if (!await _httpDelete('$_backendUrl/api/moments/$postId')) throw StateError('删除失败，请手动重试');
    _posts.removeWhere((p) => p.id == postId);
    await _savePosts();
    notifyListeners();

    DiagnosticsService.event('behavior', 'deleted_post');
  }

  /// 点赞/取消点赞
  Future<void> toggleLike(String postId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final isLiking = !post.isLikedByMe;
    if (isLiking) {
      if (await _httpPost('$_backendUrl/api/moments/$postId/like?user_id=me&user_name=我', {}) == null) throw StateError('点赞失败，请手动重试');
    } else {
      if (!await _httpDelete('$_backendUrl/api/moments/$postId/like/me')) throw StateError('取消点赞失败，请手动重试');
    }
    if (post.isLikedByMe) {
      _posts[index] = post.removeLike('me');
    } else {
      _posts[index] = post.addLike('me');
    }

    await _savePosts();
    notifyListeners();

  }

  /// AI 点赞
  Future<void> aiLike(String postId, String roleId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    if (!post.likedBy.contains(roleId)) {
      _posts[index] = post.addLike(roleId);
      // 如果是用户的帖子被点赞，增加未读
      if (post.authorId == 'me') {
        _unreadCount++;
      }
      await _savePosts();
      notifyListeners();
    }
  }

  /// 添加评论
  Future<void> addComment(
    String postId, {
    required String authorId,
    required String authorName,
    required String content,
    String? replyToId,
    String? replyToName,
  }) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final payload = jsonEncode(['comment', postId, authorId, content, replyToId]);
    final id = await _operation(payload);
    final response = await _httpPost('$_backendUrl/api/moments/$postId/comment', {
      'id': id, 'author_id': authorId, 'author_name': authorName, 'content': content,
      'reply_to_id': replyToId, 'reply_to_name': replyToName,
    });
    if (response == null) throw StateError('评论未提交，请恢复后端连接后重试，输入已保留');
    final comment = MomentComment(
      id: id,
      authorId: authorId,
      authorName: authorName,
      content: content,
      createdAt: DateTime.now(),
      replyToId: replyToId,
      replyToName: replyToName,
    );

    final post = _posts[index];
    if (!post.comments.any((c) => c.id == id)) _posts[index] = post.addComment(comment);
    // 如果是用户的帖子被评论，或被回复，增加未读
    if (post.authorId == 'me' || replyToId == 'me') {
      _unreadCount++;
    }
    await _savePosts();

    await _done(payload);

    notifyListeners();
  }

  /// 清除未读
  void clearUnread() {
    _unreadCount = 0;
    notifyListeners();
  }

  /// 获取指定用户/角色的动态
  List<MomentPost> getPostsByAuthor(String authorId) {
    return _posts.where((p) => p.authorId == authorId).toList();
  }

  /// 清空所有动态
  Future<void> clearAll() async {
    _posts.clear();
    _unreadCount = 0;
    await _savePosts();
    notifyListeners();
  }

  // ========== 后端同步 ==========

  /// 获取后端 URL
  String get _backendUrl => SettingsService.instance.backendUrl;

  /// 从后端获取朋友圈列表
  Future<bool> fetchFromBackend() async {
    try {
      final response = await _httpGet('$_backendUrl/api/moments');
      if (response != null && response['moments'] != null) {
        final List<dynamic> momentsJson = response['moments'];
        for (final json in momentsJson) {
          try {
            final normalized = Map<String, dynamic>.from(json as Map);
            normalized['liked_by'] = (json['liked_by'] as List? ?? []).map((item) => item is Map ? item['id'].toString() : item.toString()).toList();
            final post = MomentPost.fromJson(normalized);
            final existingIndex = _posts.indexWhere((p) => p.id == post.id);
            if (existingIndex == -1) { _posts.add(post); }
            else { _posts[existingIndex] = post; }
          } catch (e) {
            DiagnosticsService.event(
              'behavior',
              'error_parsing_backend_moment',
              error: e,
            );
          }
        }
        // 按时间倒序
        _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        await _savePosts();
        notifyListeners();
        DiagnosticsService.event('behavior', 'synced');
        return true;
      }
    } catch (e) {
      DiagnosticsService.event('behavior', 'backend_fetch_failed', error: e);
    }
    return false;
  }

  /// 发布动态到后端
  Future<bool> publishToBackend(MomentPost post) async {
    try {
      final response = await _httpPost('$_backendUrl/api/moments', {
        'id': post.id,
        'author_id': post.authorId,
        'author_name': post.authorName,
        'content': post.content,
        'image_urls': post.imageUrls,
      });
      return response != null;
    } catch (e) {
      DiagnosticsService.event(
        'behavior',
        'publish_to_backend_failed',
        error: e,
      );
      return false;
    }
  }

  /// HTTP GET
  Future<Map<String, dynamic>?> _httpGet(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final body = response.body;
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      DiagnosticsService.event('behavior', 'legacy_event', error: e);
    }
    return null;
  }

  /// HTTP POST
  Future<Map<String, dynamic>?> _httpPost(
    String url,
    Map<String, dynamic> data,
  ) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(data));
      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = response.body;
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      DiagnosticsService.event('behavior', 'legacy_event', error: e);
    }
    return null;
  }

  /// HTTP DELETE
  Future<bool> _httpDelete(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.delete(uri);
      return response.statusCode == 200;
    } catch (e) {
      DiagnosticsService.event('behavior', 'legacy_event', error: e);
    }
    return false;
  }
}
