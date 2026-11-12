import 'package:http/http.dart' as raw;
import 'session_service.dart';
export 'package:http/http.dart'
    show Response, MultipartRequest, MultipartFile, StreamedResponse;

Future<raw.Response> _request(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
}) async {
  final client = raw.Client();
  final generation = SessionService.instance.generation;
  try {
    final request = raw.Request(method, uri)..followRedirects = false;
    request.headers.addAll({
      ...?headers,
      ...SessionService.instance.headers(uri),
    });
    if (body is String) request.body = body;
    final timeout =
        method == 'POST' &&
            (uri.path.startsWith('/api/ai/') ||
                uri.path == '/api/chat/vision' ||
                RegExp(r'^/api/groups/[^/]+/turn$').hasMatch(uri.path))
        ? const Duration(minutes: 10)
        : const Duration(seconds: 90);
    final response = await (() async {
      final streamed = await client.send(request);
      return raw.Response.fromStream(streamed);
    })().timeout(timeout);
    if (generation != SessionService.instance.generation)
      throw StateError('会话已切换，已忽略旧请求结果');
    SessionService.instance.observe(response.statusCode, uri);
    return response;
  } finally {
    client.close();
  }
}

Future<raw.Response> get(Uri uri, {Map<String, String>? headers}) =>
    _request('GET', uri, headers: headers);
Future<raw.Response> head(Uri uri, {Map<String, String>? headers}) =>
    _request('HEAD', uri, headers: headers);
Future<raw.Response> post(
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
}) => _request('POST', uri, headers: headers, body: body);
Future<raw.Response> put(
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
}) => _request('PUT', uri, headers: headers, body: body);
Future<raw.Response> delete(
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
}) => _request('DELETE', uri, headers: headers, body: body);

Future<raw.Response> upload(raw.MultipartRequest request) async {
  final generation = SessionService.instance.generation;
  final client = raw.Client();
  try {
    request.followRedirects = false;
    request.headers.addAll(SessionService.instance.headers(request.url));
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 60));
    final response = await raw.Response.fromStream(
      streamed,
    ).timeout(const Duration(seconds: 60));
    if (generation != SessionService.instance.generation)
      throw StateError('会话已切换，已忽略旧上传结果');
    SessionService.instance.observe(response.statusCode, request.url);
    return response;
  } finally {
    client.close();
  }
}
