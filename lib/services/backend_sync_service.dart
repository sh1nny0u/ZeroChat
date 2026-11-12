import 'dart:async';
import 'package:path_provider/path_provider.dart';
import '../core/message_store.dart';
import '../core/chat_controller.dart';
import '../models/group_chat.dart';
import 'api_service.dart';
import 'backend_http.dart' as http;
import 'chat_list_service.dart';
import 'diagnostics_service.dart';
import 'favorite_service.dart';
import 'group_chat_service.dart';
import 'history_repository.dart';
import 'image_service.dart';
import 'memory_service.dart';
import 'moments_service.dart';
import 'notification_service.dart';
import 'resource_cache_service.dart';
import 'role_service.dart';
import 'session_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';
import 'task_service.dart';
import 'entity_sync_service.dart';
import 'background_delivery_service.dart';

/// This timer only reads saved results; it never triggers a model or task.
class BackendSyncService {
  static bool _behaviorQuiet() {
    final policies = EntitySyncService.instance.entities('behavior_policy');
    final value = policies.isEmpty ? <String, dynamic>{} : policies.first['payload'] as Map;
    if (value['quiet_enabled'] == false) return false;
    final hour = DateTime.now().toUtc().add(Duration(minutes: value['utc_offset_minutes'] as int? ?? 480)).hour;
    final start = value['quiet_start'] as int? ?? 23, end = value['quiet_end'] as int? ?? 7;
    return start == end ? false : start < end ? hour >= start && hour < end : hour >= start || hour < end;
  }
  static Timer? _timer;
  static bool _busy = false;
  static Future<void>? _active;
  static Future<void> quiesce() async {
    stop();
    await _active;
    await RoleService.waitForPendingSaves();
    await EntitySyncService.instance.waitForPending();
    await ChatController.instance.resetSession();
    await MessageStore.instance.resetSession();
  }

  static Future<void> prepare() async {
    await quiesce();
    await HistoryRepository.instance?.db.close();
    final scope = ResourceCacheService.scopeFor(
      SessionService.backend,
      SessionService.instance.identity!,
    );
    await StorageService.activateScope(scope);
    await ImageService.init();
    HistoryRepository.instance = await HistoryRepository.open(scope: scope);
    if (scope == StorageService.legacyScope) {
      await HistoryRepository.instance!.migrateLegacy(
        await getApplicationDocumentsDirectory(),
      );
    }
    await SettingsService.init();
    await EntitySyncService.instance.captureLegacyLocal();
    await RoleService.init();
    await GroupChatService.init();
    await MemoryService.init();
    await TaskService.init();
    await ChatListService.init();
    await FavoriteService.init();
    await MomentsService.init();
    await MessageStore.init();
    // Empty-server migration is explicit in the local scope; never overwrite
    // an already populated server using a stale device snapshot.
    if (StorageService.getString('phase3_config_migrated') != '1') {
      final config = await http.get(
        Uri.parse('${SessionService.backend}/api/settings'),
      );
      if (config.statusCode != 200) throw StateError('配置迁移前检查失败');
      if (!await SettingsService.instance.migrateLegacySettings())
        throw StateError('原配置未迁移，请恢复连接后重试');
      await StorageService.setString('phase3_config_migrated', '1');
    }
    await EntitySyncService.instance.migrateLocal();
    await SettingsService.instance.loadBackendSettings();
    await EntitySyncService.instance.pull();
    if (StorageService.getString('phase3_tasks_migrated') != '1') {
      await TaskService.migrateLocalTasks();
      await StorageService.setString('phase3_tasks_migrated', '1');
    }
    await tick();
  }

  static void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => tick());
    unawaited(tick());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> syncGroup(GroupChat group) async {
    final payload = group.toJson()..remove('sync_version');
    if (!await EntitySyncService.instance.save(
      'group',
      group.id,
      payload,
      baseVersion: group.syncVersion,
    )) {
      throw StateError('群聊设置存在冲突，请到数据同步页处理');
    }
  }

  static Future<void> ensureGroup(GroupChat group) async {
    final uri = Uri.parse(
      '${SessionService.backend}/api/groups/${Uri.encodeComponent(group.id)}',
    );
    final response = await http.get(uri);
    if (response.statusCode == 404) {
      await syncGroup(group);
    } else if (response.statusCode != 200) {
      throw StateError(
        ApiService.responseError(response.statusCode, response.body),
      );
    }
  }

  static Future<void> tick() =>
      _active ??= _tick().whenComplete(() => _active = null);
  static Future<void> _tick() async {
    if (_busy || !SessionService.instance.authenticated) return;
    _busy = true;
    try {
      await EntitySyncService.instance.pull();
      for (final role in RoleService.getAllRoles()) {
        if (!SessionService.instance.authenticated) break;
        final chat = role.id;
        await MessageStore.instance.refreshFromBackend(chat);
        if (!SessionService.instance.authenticated) break;
        final rows = MessageStore.instance.getMessages(chat);
        if (rows.isEmpty) continue;
        final last = rows.last;
        ChatListService.instance.getOrCreateChat(
          id: chat,
          name: role.name,
          avatarUrl: role.avatarUrl,
        );
        final incoming = MessageStore.instance.takeIncoming(chat);
        final notifyFresh = incoming.isNotEmpty && await BackgroundDeliveryService.claim(chat, incoming.map((m) => m.id).toList());
        final changed =
            incoming.isNotEmpty && !MessageStore.instance.isHistoryOpen(chat);
        ChatListService.instance.updateChat(
          chatId: chat,
          lastMessage: last.content,
          lastMessageTime: last.timestamp,
          unreadDelta: changed ? incoming.length : 0,
        );
        if (changed && notifyFresh && !TaskService.isQuietTime() && !_behaviorQuiet()) {
          await NotificationService.instance.showMessageNotification(
            chatId: chat,
            senderName: role.name,
            message: incoming.last.content,
          );
        }
        if (!MessageStore.instance.isHistoryOpen(chat))
          await MessageStore.instance.releaseHistory(chat);
      }
      for (final group in GroupChatService.getAllGroups()) {
        if (!SessionService.instance.authenticated) break;
        await MessageStore.instance.refreshFromBackend(group.id);
        if (!SessionService.instance.authenticated) break;
        final last = MessageStore.instance.getLastMessage(group.id);
        final incoming = MessageStore.instance.takeIncoming(group.id);
        final notifyFresh = incoming.isNotEmpty && await BackgroundDeliveryService.claim(group.id, incoming.map((m) => m.id).toList());
        final changed =
            incoming.isNotEmpty &&
            !MessageStore.instance.isHistoryOpen(group.id);
        if (last != null)
          ChatListService.instance.updateChat(
            chatId: group.id,
            lastMessage: last.content,
            lastMessageTime: last.timestamp,
            unreadDelta: changed ? incoming.length : 0,
          );
        if (changed && notifyFresh && !TaskService.isQuietTime() && !_behaviorQuiet())
          await NotificationService.instance.showMessageNotification(
            chatId: group.id,
            senderName: group.name,
            message: incoming.last.content,
          );
        if (!MessageStore.instance.isHistoryOpen(group.id))
          await MessageStore.instance.releaseHistory(group.id);
      }
      await MomentsService.instance.fetchFromBackend();
      await TaskService.fetchFromBackend();
      await NotificationService.instance.setBadgeCount(
        ChatListService.instance.totalUnreadCount,
      );
    } catch (error) {
      DiagnosticsService.event(
        'sync',
        'background_results_fetch_failed',
        error: error,
      );
    } finally {
      _busy = false;
    }
  }
}
