import 'diagnostics_service.dart';
import '../models/group_chat.dart';
import 'storage_service.dart';
import 'backend_sync_service.dart';
import 'entity_sync_service.dart';
import 'api_service.dart';

/// 群聊服务
/// 管理群聊创建、成员、防刷屏等
class GroupChatService {
  static Future<void> applySynced(List<Map<String, dynamic>> rows, Set<String> pending) async {
    final keep = _groups.where((g) => pending.contains('group:${g.id}')).toList();
    _groups.clear();
    _groups.addAll(rows.where((r) => !pending.contains('group:${r['id']}')).map(GroupChat.fromJson));
    _groups.addAll(keep);
    await _saveGroups();
  }
  static final List<GroupChat> _groups = [];

  /// 初始化
  static Future<void> init() async {
    await _loadGroups();
    DiagnosticsService.event('chat', 'groupchatservice_initialized_with');
  }

  /// 加载群聊列表
  static Future<void> _loadGroups() async {
    _groups.clear();
    final jsonList = StorageService.getJsonList('group_chats');
    if (jsonList != null) {
      _groups.clear();
      for (final json in jsonList) {
        try {
          _groups.add(GroupChat.fromJson(json));
        } catch (e) {
          DiagnosticsService.event('chat', 'legacy_event', error: e);
        }
      }
    }
  }

  /// 保存群聊列表
  static Future<void> _saveGroups() async {
    final jsonList = _groups.map((g) => g.toJson()).toList();
    await StorageService.setJsonList('group_chats', jsonList);
  }

  /// 创建群聊
  static Future<GroupChat> createGroup({
    required String name,
    required List<String> memberIds,
    int cooldownSeconds = 5,
    int maxRepliesPerMinute = 10,
  }) async {
    final group = GroupChat(
      id: 'group_${ApiService.requestId()}',
      name: name,
      memberIds: memberIds,
      ownerId: 'user',
      cooldownSeconds: cooldownSeconds,
      maxRepliesPerMinute: maxRepliesPerMinute,
    );

    await BackendSyncService.syncGroup(group);
    _groups.add(GroupChat.fromJson({...group.toJson(), 'sync_version': EntitySyncService.instance.version('group', group.id)}));
    await _saveGroups();
    return group;
  }

  /// 获取群聊
  static GroupChat? getGroup(String groupId) {
    return _groups.where((g) => g.id == groupId).firstOrNull;
  }

  /// 获取所有群聊
  static List<GroupChat> getAllGroups() {
    return List.unmodifiable(_groups);
  }

  /// 更新群聊
  static Future<void> updateGroup(GroupChat group) async {
    final index = _groups.indexWhere((g) => g.id == group.id);
    if (index != -1) {
      await BackendSyncService.syncGroup(group);
      _groups[index] = GroupChat.fromJson({...group.toJson(), 'sync_version': EntitySyncService.instance.version('group', group.id)});
      await _saveGroups();
    }
  }

  /// 删除群聊
  static Future<void> deleteGroup(String groupId) async {
    if (!await EntitySyncService.instance.save('group', groupId, {}, deleted: true)) throw StateError('群聊删除存在冲突');
    _groups.removeWhere((g) => g.id == groupId);
    await _saveGroups();
  }

  /// 添加成员
  static Future<void> addMember(String groupId, String memberId) async {
    final group = getGroup(groupId);
    if (group != null && !group.memberIds.contains(memberId)) {
      final updated = group.copyWith(memberIds: [...group.memberIds, memberId]);
      await updateGroup(updated);
    }
  }

  /// 移除成员
  static Future<void> removeMember(String groupId, String memberId) async {
    final group = getGroup(groupId);
    if (group != null) {
      final updated = group.copyWith(
        memberIds: group.memberIds.where((id) => id != memberId).toList(),
      );
      await updateGroup(updated);
    }
  }

  /// 修改群名
  static Future<void> renameGroup(String groupId, String newName) async {
    final group = getGroup(groupId);
    if (group != null) {
      final updated = group.copyWith(name: newName);
      await updateGroup(updated);
    }
  }

}
