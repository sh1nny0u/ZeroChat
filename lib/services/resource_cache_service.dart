import 'package:http/http.dart' as http;
import 'session_service.dart';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'settings_service.dart';

/// Persistent resource cache, separate for each backend and authenticated identity.
class ResourceCacheService {
  static final Map<String, CacheManager> _managers = {};
  static String _identity = 'anonymous';
  static Map<String, String> _headers = {};
  static bool _accessAllowed = false;

  // Authentication must call this before rendering protected resources. Session
  // revocation disables even in-memory images; tokens never enter a cache key.
  static void setSession({
    required String identity,
    Map<String, String> headers = const {},
    bool accessAllowed = true,
  }) {
    _identity = identity;
    _headers = Map.of(headers);
    _accessAllowed = accessAllowed;
  }

  static bool get accessAllowed => _accessAllowed;
  static Map<String, String> get headers => Map.unmodifiable(_headers);
  static Map<String, String> headersFor(String url) {
    final target = Uri.parse(resolve(url));
    final backend = Uri.parse(SettingsService.instance.backendUrl);
    return target.origin == backend.origin && target.path.startsWith('${backend.path}/api/') ? headers : const {};
  }
  static String scopeFor(String backend, String identity) =>
      sha256.convert(utf8.encode('$backend\n$identity')).toString();
  static String get scope => scopeFor(
    SettingsService.instance.backendUrl.replaceFirst(RegExp(r'/+$'), ''),
    _identity,
  );

  static String resolve(String url) => url.startsWith('/')
      ? '${SettingsService.instance.backendUrl.replaceFirst(RegExp(r'/+$'), '')}$url'
      : url;

  static String key(String url) => '$scope:${resolve(url)}';

  static CacheManager get manager =>
      _managers.putIfAbsent(scope, () => create(scope));

  static CacheManager create(
    String scope, {
    String? root,
    FileService? fileService,
  }) {
    return CacheManager(
      Config(
        'resources_$scope',
        stalePeriod: const Duration(days: 90),
        maxNrOfCacheObjects: 2000,
        fileSystem: _PersistentFiles('resources_$scope', root),
        repo: root == null
            ? CacheObjectProvider(databaseName: 'resources_$scope')
            : JsonCacheInfoRepository(path: '$root/resources_$scope.json'),
        fileService: fileService ?? HttpFileService(httpClient: _ResourceClient()),
      ),
    );
  }

  static CachedNetworkImageProvider provider(String url) =>
      CachedNetworkImageProvider(
        resolve(url),
        cacheKey: key(url),
        cacheManager: manager,
        headers: headersFor(url),
      );
}

class _PersistentFiles implements FileSystem {
  final String name;
  final String? root;
  _PersistentFiles(this.name, this.root);
  @override
  Future<fs.File> createFile(String filename) async {
    final base = root ?? (await getApplicationSupportDirectory()).path;
    final directory = const LocalFileSystem().directory('$base/$name');
    await directory.create(recursive: true);
    return directory.childFile(filename);
  }
}

class _ResourceClient extends http.BaseClient {
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!ResourceCacheService.accessAllowed) throw StateError('请登录后访问资源');
    final generation = SessionService.instance.generation;
    request.followRedirects = false;
    request.headers.removeWhere((key, _) => key.toLowerCase() == 'authorization');
    request.headers.addAll(SessionService.instance.headers(request.url));
    final response = await _client.send(request).timeout(const Duration(seconds: 10));
    if (generation != SessionService.instance.generation) throw StateError('会话已切换，已忽略旧资源请求');
    SessionService.instance.observe(response.statusCode, request.url);
    return response;
  }
  @override
  void close() => _client.close();
}
