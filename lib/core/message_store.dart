import '../services/session_service.dart';
import '../services/storage_service.dart';
import '../services/group_chat_service.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../services/backend_http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../services/history_repository.dart';
import '../services/settings_service.dart';
import '../services/role_service.dart';
import '../services/diagnostics_service.dart';

class MessageStore extends ChangeNotifier {
  static final MessageStore _instance = MessageStore._internal();
  factory MessageStore() => _instance;
  MessageStore._internal();
  static MessageStore get instance => _instance;
  static const pageSize = 50;
  bool _initialized = false;
  final Map<String, List<Message>> _messages = {};
  final Map<String, Message> _outgoing = {};

  bool isOutgoing(String chat, String id) => _outgoing[chat]?.id == id;

  void showOutgoing(String chat, Message message) {
    _outgoing[chat] = message;
    _notifyMessageUpdate(chat);
  }

  void clearOutgoing(String chat) {
    if (_outgoing.remove(chat) != null) _notifyMessageUpdate(chat);
  }

  final Map<String, int> _counts = {};
  final Map<String, int> _remoteTotals = {};
  final Map<String, bool> _hasMore = {};
  final Map<String, String> _errors = {};
  final Map<String, Future<void>> _loading = {};
  final Map<String, Future<void>> _syncing = {};
  final Map<String, Future<void>> _releasing = {};
  final Map<String, int> _unreadCounts = {};
  final Set<String> _loaded = {};
  final Set<String> _openHistories = {};
  final Map<String, List<Message>> _incoming = {};
  List<Message> takeIncoming(String chat) => _incoming.remove(chat) ?? [];
  void setHistoryOpen(String chat, bool open) {
    if (open) {
      _openHistories.add(chat);
    } else {
      _openHistories.remove(chat);
    }
  }

  bool isHistoryOpen(String chat) => _openHistories.contains(chat);
  final Map<String, StreamController<List<Message>>> _streamControllers = {};
  HistoryRepository get _repository => HistoryRepository.instance!;

  static Future<void> init() async {
    if (_instance._initialized) return;
    if (HistoryRepository.instance == null) {
      HistoryRepository.instance = await HistoryRepository.open();
      await HistoryRepository.instance!.migrateLegacy(
        await getApplicationDocumentsDirectory(),
      );
    }
    // Chat list previews read one indexed row, never complete histories.
    for (final chat in await _instance._repository.chats()) {
      _instance._messages[chat] = (await _instance._repository.page(
        chat,
        limit: 1,
      )).messages;
      _instance._counts[chat] = await _instance._repository.count(chat);
    }
    _instance._initialized = true;
  }

  Future<void> ensureLoaded(String chatId) {
    final releasing = _releasing[chatId];
    if (releasing != null) {
      return releasing.then((_) => ensureLoaded(chatId));
    }
    return _ensureLoaded(chatId);
  }

  Future<void> _ensureLoaded(String chatId) {
    if (_loaded.contains(chatId)) return Future.value();
    return _loading.putIfAbsent(
      chatId,
      () => _load(chatId).whenComplete(() {
        _loading.remove(chatId);
      }),
    );
  }

  Future<void> _load(String chatId) async {
    final page = await _repository.page(chatId);
    _messages[chatId] = page.messages;
    _counts[chatId] = await _repository.count(chatId);
    _hasMore[chatId] = page.hasMore;
    _loaded.add(chatId);
    _notifyMessageUpdate(chatId);
  }

  bool hasMore(String chatId) => _hasMore[chatId] ?? false;
  String? historyError(String chatId) => _errors[chatId];
  bool get _backendEnabled => SessionService.instance.authenticated;
  bool _isRole(String chatId) => RoleService.getRoleById(chatId) != null;
  Uri _uri(String chat, [Map<String, String> params = const {}]) => Uri.parse(
    '${SettingsService.instance.backendUrl}/api/${_isRole(chat) ? 'roles' : 'groups'}/${Uri.encodeComponent(chat)}/chats/messages',
  ).replace(queryParameters: params.isEmpty ? null : params);

  Message _fromBackend(String chat, Map<String, dynamic> json) =>
      Message.fromJson({
        ...json,
        'receiver_id': json['sender_id'] == 'me' ? chat : 'me',
        'quoted_message_id': json['quote_id'],
        'quoted_preview_text': json['quote_content'],
      });

  Future<Map<String, dynamic>> _remotePage(
    String chat, {
    Message? before,
    int? after,
    int limit = pageSize,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (before != null) {
      params['before'] = base64Url.encode(
        utf8.encode(
          jsonEncode([
            before.timestamp.toUtc().microsecondsSinceEpoch,
            before.id,
          ]),
        ),
      );
    }
    if (after != null) params['after'] = '$after';
    final response = await http
        .get(_uri(chat, params))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('history_http_${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final revision = body['revision'] as String?;
    final previousRevision = await _repository.meta('revision:$chat');
    final restoreGeneration =
        '${StorageService.getInt('history_restore_generation') ?? 0}';
    final oldGeneration = await _repository.meta('restore:$chat');
    if ((revision != null &&
            previousRevision != null &&
            revision != previousRevision) ||
        (oldGeneration != null && oldGeneration != restoreGeneration)) {
      // A deletion invalidates only this conversation's cached indexed rows.
      await _repository.db.delete(
        'messages',
        where: 'chat=? AND pending=0',
        whereArgs: [chat],
      );
      _messages[chat] = [];
      await _repository.setMeta('after:$chat', '${body['high_water']}');
    }
    if (revision != null) await _repository.setMeta('revision:$chat', revision);
    await _repository.setMeta('restore:$chat', restoreGeneration);
    _remoteTotals[chat] = body['total'] as int;
    final messages = (body['messages'] as List)
        .map((row) => _fromBackend(chat, Map<String, dynamic>.from(row)))
        .toList();
    await _repository.put(chat, messages);
    if (after != null) {
      final fresh = await _repository.claimIncoming(chat, messages);
      _incoming.putIfAbsent(chat, () => []).addAll(fresh);
    }
    return body;
  }

  Future<void> refreshFromBackend(String chat) {
    return _syncing.putIfAbsent(
      chat,
      () => _refresh(chat).whenComplete(() {
        _syncing.remove(chat);
      }),
    );
  }

  Future<void> _refresh(String chat) async {
    if (!_backendEnabled) {
      _errors[chat] = '请连接后端并登录，再手动重试';
      _notifyMessageUpdate(chat);
      return;
    }
    if (!_isRole(chat) && GroupChatService.getGroup(chat) == null) return;
    try {
      await _ensureLoaded(chat);
      // Retry durable unsynchronized messages in bounded batches, idempotently.
      while (true) {
        final pending = await _repository.pending(chat);
        if (pending.isEmpty) break;
        final response = await http
            .post(
              Uri.parse(
                '${SettingsService.instance.backendUrl}/api/${_isRole(chat) ? 'roles' : 'groups'}/${Uri.encodeComponent(chat)}/chats/sync',
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'messages': pending.map((m) => _payload(m)).toList(),
              }),
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) throw StateError('history_sync_failed');
        await _repository.acknowledge(chat, pending);
      }
      final latest = await _remotePage(chat);
      final saved = await _repository.meta('after:$chat');
      if (saved != null) {
        var after = int.parse(saved);
        while (true) {
          final page = await _remotePage(chat, after: after);
          after = (page['next_after'] as int?) ?? after;
          await _repository.setMeta('after:$chat', '$after');
          if (page['has_more'] != true) break;
          await Future<void>.delayed(Duration.zero);
        }
      } else {
        await _repository.claimIncoming(
          chat,
          (latest['messages'] as List)
              .map((row) => _fromBackend(chat, Map<String, dynamic>.from(row)))
              .toList(),
        );
        await _repository.setMeta('after:$chat', '${latest['high_water']}');
      }
      final visible = _messages[chat] ?? [];
      final loaded = await _repository.page(chat, limit: pageSize);
      // Merge by ID instead of replacing a page another request or the user
      // has just extended while this network request was in flight.
      _messages[chat] = visible.isEmpty
          ? loaded.messages
          : await _repository.since(chat, visible.first);
      _counts[chat] = await _repository.count(chat);
      final visibleCount = _messages[chat]!.length;
      _hasMore[chat] =
          (_counts[chat] ?? 0) > visibleCount ||
          (_remoteTotals[chat] ?? 0) > visibleCount;
      _errors.remove(chat);
      _notifyMessageUpdate(chat);
    } catch (error) {
      _errors[chat] = '聊天记录同步失败，请检查服务器连接后重试';
      DiagnosticsService.event(
        'sync',
        'history_refresh_failed',
        chatId: chat,
        error: error,
      );
      _notifyMessageUpdate(chat);
    }
  }

  Future<void> loadOlder(String chat) {
    return _loading.putIfAbsent(
      'older:$chat',
      () => _older(chat).whenComplete(() {
        _loading.remove('older:$chat');
      }),
    );
  }

  Future<void> _older(String chat) async {
    await _ensureLoaded(chat);
    final current = _messages[chat] ?? [];
    if (current.isEmpty) {
      await refreshFromBackend(chat);
      return;
    }
    try {
      bool remoteMore = false;
      if (_backendEnabled &&
          (_isRole(chat) || GroupChatService.getGroup(chat) != null)) {
        final remote = await _remotePage(chat, before: current.first);
        remoteMore = remote['has_more'] == true;
      }
      final older = await _repository.page(chat, before: current.first);
      final byId = <String, Message>{
        for (final message in [
          ...older.messages,
          ...(_messages[chat] ?? <Message>[]),
        ])
          message.id: message,
      };
      _messages[chat] = byId.values.toList()..sort(_compare);
      _hasMore[chat] = older.hasMore || remoteMore;
      _counts[chat] = await _repository.count(chat);
      _errors.remove(chat);
      _notifyMessageUpdate(chat);
    } catch (error) {
      _errors[chat] = '更早记录加载失败，点击重试';
      DiagnosticsService.event(
        'sync',
        'history_page_failed',
        chatId: chat,
        error: error,
      );
      _notifyMessageUpdate(chat);
    }
  }

  static int _compare(Message a, Message b) {
    final time = a.timestamp.compareTo(b.timestamp);
    return time == 0 ? a.id.compareTo(b.id) : time;
  }

  Stream<List<Message>> watchMessages(String chatId) {
    ensureLoaded(chatId);
    final controller = _streamControllers.putIfAbsent(
      chatId,
      () => StreamController<List<Message>>.broadcast(),
    );
    Future.microtask(() {
      if (controller.hasListener) controller.add(getMessages(chatId));
    });
    return controller.stream;
  }

  void refreshStream(String chatId) => _notifyMessageUpdate(chatId);
  void _notifyMessageUpdate(String chatId) {
    final controller = _streamControllers[chatId];
    if (controller?.hasListener == true) controller!.add(getMessages(chatId));
    notifyListeners();
  }

  Future<void> acceptServerMessages(String chat, List<dynamic> rows) async {
    await ensureLoaded(chat);
    final messages = rows
        .map((row) => _fromBackend(chat, Map<String, dynamic>.from(row as Map)))
        .toList();
    await _repository.put(chat, messages);
    final byId = {
      for (final message in [...?_messages[chat], ...messages])
        message.id: message,
    };
    _messages[chat] = byId.values.toList()..sort(_compare);
    _counts[chat] = await _repository.count(chat);
    _notifyMessageUpdate(chat);
  }

  Future<void> resetSession() async {
    _outgoing.clear();
    _incoming.clear();
    await Future.wait([
      ..._syncing.values,
      ..._loading.values,
      ..._releasing.values,
    ]);
    _messages.clear();
    _counts.clear();
    _remoteTotals.clear();
    _hasMore.clear();
    _errors.clear();
    _loaded.clear();
    _unreadCounts.clear();
    _openHistories.clear();
    _initialized = false;
  }

  Future<void> addMessage(String chat, Message message) async {
    await addMessages(chat, [message]);
    if (_isRole(chat)) unawaited(refreshFromBackend(chat));
  }

  Future<void> addMessages(String chat, List<Message> messages) async {
    await ensureLoaded(chat);
    await _repository.put(chat, messages, pending: _isRole(chat));
    final byId = {
      for (final message in [...?_messages[chat], ...messages])
        message.id: message,
    };
    _messages[chat] = byId.values.toList()..sort(_compare);
    _counts[chat] = await _repository.count(chat);
    _notifyMessageUpdate(chat);
  }

  Future<void> deleteMessage(String chat, String id) async {
    // Delete remotely first: failure must not silently resurrect it on refresh.
    if (_backendEnabled &&
        (_isRole(chat) || GroupChatService.getGroup(chat) != null)) {
      await refreshFromBackend(chat);
      final response = await http
          .delete(Uri.parse('${_uri(chat)}/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw StateError('删除失败，请重试');
    }
    await _repository.remove(chat, id);
    if ((_remoteTotals[chat] ?? 0) > 0) {
      _remoteTotals[chat] = _remoteTotals[chat]! - 1;
    }
    _messages[chat]?.removeWhere((m) => m.id == id);
    _counts[chat] = await _repository.count(chat);
    _notifyMessageUpdate(chat);
  }

  Future<void> clearMessages(String chat) async {
    if (_backendEnabled &&
        (_isRole(chat) || GroupChatService.getGroup(chat) != null)) {
      await refreshFromBackend(chat);
      final response = await http
          .delete(_uri(chat))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) throw StateError('清空失败，请重试');
    }
    await _repository.remove(chat);
    _messages[chat] = [];
    _counts[chat] = 0;
    _remoteTotals[chat] = 0;
    _hasMore[chat] = false;
    _notifyMessageUpdate(chat);
  }

  Future<void> releaseHistory(String chat) => _releasing.putIfAbsent(
    chat,
    () => _release(chat).whenComplete(() {
      _releasing.remove(chat);
    }),
  );

  Future<void> _release(String chat) async {
    // Finish existing reads before shrinking the view. Reopening waits for
    // release, so a late page cannot repopulate an already closed history.
    final pending = [
      _loading[chat],
      _loading['older:$chat'],
      _syncing[chat],
    ].whereType<Future<void>>().toList();
    await Future.wait(pending);
    _loaded.remove(chat);
    final preview = await _repository.page(chat, limit: 1);
    if (!_loaded.contains(chat)) _messages[chat] = preview.messages;
  }

  List<Message> getMessages(String chat) => List.unmodifiable([
    ...?_messages[chat],
    if (_outgoing[chat] case final Message outgoing)
      if (!(_messages[chat] ?? []).any((m) => m.id == outgoing.id)) outgoing,
  ]);
  Message? getMessage(String chat, String id) =>
      (_messages[chat] ?? []).where((m) => m.id == id).firstOrNull;
  List<Message> getRecentMessages(String chat, int count) {
    final list = _messages[chat] ?? [];
    return list.skip(list.length > count ? list.length - count : 0).toList();
  }

  List<Message> getRecentRounds(String chat, int rounds) =>
      getRecentMessages(chat, rounds * 2);
  Future<List<Message>> readRecentRounds(String chat, int rounds) async {
    final wanted = rounds * 2;
    var recent = await _repository.page(chat, limit: wanted);
    if (_backendEnabled && _isRole(chat) && recent.messages.length < wanted) {
      try {
        while (recent.messages.length < wanted) {
          final remaining = wanted - recent.messages.length;
          final remote = await _remotePage(
            chat,
            before: recent.messages.firstOrNull,
            limit: remaining > 200 ? 200 : remaining,
          );
          recent = await _repository.page(chat, limit: wanted);
          if (remote['has_more'] != true ||
              (remote['messages'] as List).isEmpty) {
            break;
          }
        }
      } catch (error) {
        DiagnosticsService.event(
          'sync',
          'context_history_failed',
          chatId: chat,
          error: error,
        );
      }
    }
    return recent.messages;
  }

  int getMessageCount(String chat) {
    final local = _counts[chat] ?? 0;
    final remote = _remoteTotals[chat] ?? 0;
    return local > remote ? local : remote;
  }

  Message? getLastMessage(String chat) => _messages[chat]?.lastOrNull;
  int getUnreadCount(String chat) => _unreadCounts[chat] ?? 0;
  void incrementUnread(String chat, {int count = 1}) {
    _unreadCounts[chat] = getUnreadCount(chat) + count;
    notifyListeners();
  }

  void clearUnread(String chat) {
    _unreadCounts[chat] = 0;
    notifyListeners();
  }

  void setUnread(String chat, int count) {
    _unreadCounts[chat] = count;
    notifyListeners();
  }

  static Map<String, dynamic> _payload(Message m) => {
    'id': m.id,
    'content': m.content,
    if (m.audioUrl != null) 'audio_url': m.audioUrl,
    if (m.durationMs != null) 'duration_ms': m.durationMs,
    'sender_id': m.senderId,
    'timestamp': m.timestamp.toUtc().toIso8601String(),
    'type': m.type.name,
    'quote_id': m.quotedMessageId,
    'quote_content': m.quotedPreviewText,
  };

  /// 将消息列表转换为 API 历史格式
  static List<Map<String, String>> toApiHistory(List<Message> messages) {
    return messages.map((m) {
      final buffer = StringBuffer();
      // 添加引用内容
      if (m.hasQuote && m.quotedPreviewText != null) {
        buffer.writeln('[引用: ${m.quotedPreviewText}]');
      }
      buffer.write(m.content);
      return {
        'role': m.senderId == 'me' ? 'user' : 'assistant',
        'content': buffer.toString(),
      };
    }).toList();
  }
}
