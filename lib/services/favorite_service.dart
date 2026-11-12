import 'diagnostics_service.dart';
import 'package:flutter/foundation.dart';
import '../models/favorite_collection.dart';
import '../models/message.dart';
import 'storage_service.dart';
import 'entity_sync_service.dart';
import 'session_service.dart';
import 'api_service.dart';

/// 收藏服务
/// 管理收藏合集的增删查改和标签操作
class FavoriteService extends ChangeNotifier {
  Future<void> applySynced(List<Map<String, dynamic>> rows, Set<String> pending) async {
    final keep = _collections.where((c) => pending.contains('favorite:${c.id}')).toList();
    _collections = rows.where((r) => !pending.contains('favorite:${r['id']}')).map(FavoriteCollection.fromJson).toList()..addAll(keep);
    _collections.sort((a,b) => b.createdAt.compareTo(a.createdAt));
    await StorageService.setJsonList(_storageKey, _collections.map((c) => c.toJson()).toList());
    notifyListeners();
  }
  static final FavoriteService _instance = FavoriteService._internal();
  factory FavoriteService() => _instance;
  FavoriteService._internal();

  static FavoriteService get instance => _instance;

  static const String _storageKey = 'favorite_collections';

  List<FavoriteCollection> _collections = [];

  List<FavoriteCollection> get collections => List.unmodifiable(_collections);

  /// 获取所有已使用的标签
  Set<String> get allTags {
    final tags = <String>{};
    for (final collection in _collections) {
      tags.addAll(collection.tags);
    }
    return tags;
  }

  /// 初始化
  static Future<void> init() async {
    await instance._loadCollections();
    DiagnosticsService.event('chat', 'loaded');
  }

  /// 加载收藏
  Future<void> _loadCollections() async {
    _collections = [];
    final jsonList = StorageService.getJsonList(_storageKey);
    if (jsonList != null) {
      for (final json in jsonList) {
        try { _collections.add(FavoriteCollection.fromJson(json)); }
        catch (error) { DiagnosticsService.event('migration', 'favorite_original_retained', error: error); }
      }
      // 按收藏时间倒序
      _collections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  /// 保存收藏
  Future<void> _saveCollections() async {
    final jsonList = _collections.map((c) => c.toJson()).toList();
    await StorageService.setJsonList(_storageKey, jsonList);
  }
  Future<void> _sync(FavoriteCollection value) async {
    if (SessionService.instance.authenticated && !await EntitySyncService.instance.save('favorite', value.id, value.toJson())) {
      throw StateError('收藏已在其他设备修改，请到数据同步页处理');
    }
  }

  /// 创建收藏合集
  Future<FavoriteCollection> createCollection({
    required String chatId,
    required String chatName,
    required String userName,
    required String roleName,
    required List<Message> messages,
    required String Function(String senderId) getSenderName,
  }) async {
    // 按时间排序消息
    final sortedMessages = List<Message>.from(messages)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // 创建快照
    final snapshots = sortedMessages.map((m) {
      final senderName = m.senderId == 'me'
          ? userName
          : getSenderName(m.senderId);
      return MessageSnapshot.fromMessage(m, senderName: senderName);
    }).toList();

    final collection = FavoriteCollection(
      id: ApiService.requestId(),
      chatId: chatId,
      chatName: chatName,
      userName: userName,
      roleName: roleName,
      createdAt: DateTime.now(),
      messages: snapshots,
    );

    _collections.insert(0, collection);
    await _saveCollections();
    await _sync(collection);
    notifyListeners();

    DiagnosticsService.event('chat', 'created_collection_with');
    return collection;
  }

  /// 删除收藏合集
  Future<void> deleteCollection(String collectionId) async {
    if (SessionService.instance.authenticated && !await EntitySyncService.instance.save('favorite', collectionId, {}, deleted: true)) {
      throw StateError('收藏删除冲突，请到数据同步页处理');
    }
    _collections.removeWhere((c) => c.id == collectionId);
    await _saveCollections();
    notifyListeners();

    DiagnosticsService.event('chat', 'deleted_collection');
  }

  /// 获取指定合集
  FavoriteCollection? getCollection(String collectionId) {
    return _collections.where((c) => c.id == collectionId).firstOrNull;
  }

  /// 按标签筛选
  List<FavoriteCollection> filterByTags(List<String> tags) {
    if (tags.isEmpty) return collections;
    return _collections.where((c) {
      for (final tag in tags) {
        if (c.tags.contains(tag)) return true;
      }
      return false;
    }).toList();
  }

  /// 按聊天筛选
  List<FavoriteCollection> filterByChat(String chatId) {
    return _collections.where((c) => c.chatId == chatId).toList();
  }

  /// 添加标签
  Future<void> addTag(String collectionId, String tag) async {
    final index = _collections.indexWhere((c) => c.id == collectionId);
    if (index == -1) return;

    _collections[index] = _collections[index].addTag(tag);
    await _saveCollections();
    await _sync(_collections[index]);
    notifyListeners();
  }

  /// 移除标签
  Future<void> removeTag(String collectionId, String tag) async {
    final index = _collections.indexWhere((c) => c.id == collectionId);
    if (index == -1) return;

    _collections[index] = _collections[index].removeTag(tag);
    await _saveCollections();
    await _sync(_collections[index]);
    notifyListeners();
  }

  /// 清空所有收藏
  Future<void> clearAll() async {
    for (final id in _collections.map((c) => c.id).toList()) { await deleteCollection(id); }
    _collections.clear();
    await _saveCollections();
    notifyListeners();
  }
}
