import 'backend_sync_service.dart';
import 'background_delivery_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'resource_cache_service.dart';
import 'settings_service.dart';
import 'session_credential_store.dart';

/// Restores an encrypted device session; passwords are never persisted.
class SessionService extends ChangeNotifier {
  static final instance = SessionService();
  SessionService({SessionCredentialStore? credentialStore})
    : _credentialStore = credentialStore ?? SessionCredentialStore();
  final SessionCredentialStore _credentialStore;
  String? _token;
  String? _server;
  String? identity;
  String? sessionId;
  String? error;
  bool initialized = true;
  bool ready = false;
  bool checking = false;
  bool connected = true;
  bool compatible = true;
  Timer? _validation;
  int generation = 0;
  int _checkAttempt = 0;
  bool get authenticated => _token != null && _server == backend;
  static String get backend =>
      SettingsService.instance.backendUrl.replaceFirst(RegExp(r'/+$'), '');
  bool owns(Uri uri) {
    final root = Uri.parse(backend);
    return uri.scheme == root.scheme &&
        uri.host == root.host &&
        uri.port == root.port &&
        uri.path.startsWith('${root.path}/api/');
  }

  Map<String, String> headers(Uri uri) =>
      authenticated && owns(uri) ? {'Authorization': 'Bearer $_token'} : {};

  void invalidate([String? message]) {
    unawaited(BackgroundDeliveryService.disable());
    unawaited(
      _credentialStore.clear().catchError((Object _) {
        error = '本机安全登录凭证清除失败，请重新打开应用后退出登录';
        notifyListeners();
      }),
    );
    generation++;
    _checkAttempt++;
    checking = false;
    ready = false;
    connected = false;
    _token = null;
    _server = null;
    identity = null;
    sessionId = null;
    _validation?.cancel();
    error = message;
    ResourceCacheService.setSession(
      identity: 'anonymous',
      accessAllowed: false,
    );
    notifyListeners();
  }

  void observe(int status, Uri uri) {
    if (status == 401 && owns(uri) && authenticated) {
      invalidate('登录已失效或设备已被撤销，请重新登录');
    }
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final client = http.Client();
    try {
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers.addAll(headers);
      if (body is String) request.body = body;
      final result = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      return await http.Response.fromStream(
        result,
      ).timeout(const Duration(seconds: 20));
    } finally {
      client.close();
    }
  }

  Future<void> check({bool loadData = true}) async {
    if (checking) return;
    final checkAttempt = ++_checkAttempt;
    final expected = generation;
    checking = true;
    error = null;
    notifyListeners();
    final server = backend;
    try {
      final response = await _request(
        'GET',
        Uri.parse('$server/api/auth/status'),
      ).timeout(const Duration(seconds: 8));
      if (server != backend || expected != generation) return;
      if (response.statusCode != 200) {
        throw StateError('无法连接后端（${response.statusCode}）');
      }
      final status = jsonDecode(response.body) as Map;
      initialized = status['initialized'] == true;
      compatible =
          (status['protocol_version'] as int? ?? 0) >= 9 &&
          (status['min_client_protocol'] as int? ?? 0) <= 9;
      if (!compatible) {
        error = '客户端与服务器版本不兼容，请将两端更新至兼容的 2.0 版本';
        return;
      }
      if (initialized && !ready) {
        await _restore(server, expected, loadData: loadData);
      }
    } catch (_) {
      if (server == backend && expected == generation) {
        connected = false;
        error = '无法恢复连接，已保存的登录不会清除；请检查网络后手动重试';
      }
    } finally {
      if (checkAttempt == _checkAttempt) {
        checking = false;
        notifyListeners();
      }
    }
  }

  Future<void> _restore(
    String server,
    int expected, {
    required bool loadData,
  }) async {
    final saved = await _credentialStore.read(server);
    if (server != backend || expected != generation || saved == null) return;
    if (saved['server'] != server ||
        [
          'token',
          'identity',
          'session_id',
        ].any((key) => saved[key]?.isNotEmpty != true)) {
      await _credentialStore.clear();
      return;
    }
    // Validate remotely before exposing cached private data or starting sync.
    final response = await _request(
      'GET',
      Uri.parse('$server/api/auth/me'),
      headers: {'Authorization': 'Bearer ${saved['token']}'},
    );
    if (server != backend || expected != generation) return;
    if (response.statusCode == 401) {
      invalidate('本设备登录已被撤销，请重新登录');
      return;
    }
    if (response.statusCode != 200) throw StateError('自动登录暂不可用');
    final user = jsonDecode(response.body) as Map;
    if (user['identity'] != saved['identity'] ||
        user['session_id'] != saved['session_id']) {
      invalidate('服务器账号已变化，请重新登录');
      return;
    }
    _server = server;
    _token = saved['token'];
    identity = saved['identity'];
    sessionId = saved['session_id'];
    await _prepare(expected, loadData: loadData);
  }

  Future<void> _prepare(int expected, {required bool loadData}) async {
    connected = true;
    error = null;
    ResourceCacheService.setSession(
      identity: identity!,
      headers: headers(Uri.parse('$backend/api/auth/me')),
    );
    try {
      if (loadData) await BackendSyncService.prepare();
    } catch (_) {
      if (expected == generation && authenticated) {
        connected = false;
        ready = false;
        error = '登录已保留，数据加载暂未完成；请恢复连接后手动重试';
        ResourceCacheService.setSession(
          identity: identity!,
          accessAllowed: false,
        );
        notifyListeners();
      }
      return;
    }
    if (expected != generation || !authenticated) return;
    ready = true;
    _validation?.cancel();
    _validation = Timer.periodic(
      const Duration(seconds: 15),
      (_) => validate(),
    );
    notifyListeners();
  }

  Future<void> login({
    required String username,
    required String password,
    String setupToken = '',
    bool loadData = true,
  }) async {
    if (!compatible) {
      throw StateError('客户端与服务器版本不兼容，请更新两端后重新连接');
    }
    invalidate();
    final attempt = generation;
    final server = backend;
    await BackgroundDeliveryService.disable();
    await _credentialStore.clear();
    await BackendSyncService.quiesce();
    if (attempt != generation || server != backend)
      throw StateError('登录状态已变化，请重试');
    final response = await _request(
      'POST',
      Uri.parse('$server/api/auth/${initialized ? 'login' : 'setup'}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'device': '${Platform.operatingSystem} 设备',
        if (!initialized) 'setup_token': setupToken,
      }),
    ).timeout(const Duration(seconds: 20));
    if (server != backend || attempt != generation) {
      throw StateError('服务器或登录状态已变化，请重新登录');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError(
        data['detail'] is String ? data['detail'] : '登录失败，请检查输入',
      );
    }
    _server = server;
    _token = data['token'] as String;
    connected = true;
    identity = data['identity'] as String;
    sessionId = data['session_id'] as String;
    error = null;
    initialized = true;
    try {
      await _credentialStore.write({
        'server': server,
        'token': _token!,
        'identity': identity!,
        'session_id': sessionId!,
      });
    } catch (_) {
      if (attempt == generation) invalidate('无法安全保存登录状态，请重试');
      throw StateError('无法安全保存登录状态，请重试');
    }
    if (attempt != generation || !authenticated) throw StateError('登录状态已变化');
    await _prepare(attempt, loadData: loadData);
  }

  Future<void> validate() async {
    if (!authenticated) return;
    final expected = generation;
    final uri = Uri.parse('$backend/api/auth/me');
    try {
      final result = await _request(
        'GET',
        uri,
        headers: headers(uri),
      ).timeout(const Duration(seconds: 8));
      if (expected != generation) return;
      observe(result.statusCode, uri);
      if (result.statusCode == 200) {
        connected = true;
        error = null;
        ResourceCacheService.setSession(
          identity: identity!,
          headers: headers(uri),
        );
        notifyListeners();
      } else if (result.statusCode != 401) {
        connected = false;
        error = '后端暂时不可用，请恢复连接后手动重试';
        notifyListeners();
      }
    } catch (_) {
      if (expected != generation) return;
      connected = false;
      error = '网络暂时不可用，登录和输入已保留；请恢复连接后手动重试';
      ResourceCacheService.setSession(
        identity: identity ?? 'anonymous',
        accessAllowed: false,
      );
      notifyListeners();
    }
  }

  Future<void> logout() async {
    final uri = Uri.parse('$backend/api/auth/logout');
    try {
      final response = await _request(
        'POST',
        uri,
        headers: headers(uri),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 && response.statusCode != 401) {
        throw StateError('本机退出后，服务端撤销仍未确认，请在设备列表撤销旧会话');
      }
    } finally {
      invalidate();
      await _credentialStore.clear();
    }
  }

  @override
  void dispose() {
    _validation?.cancel();
    super.dispose();
  }
}
