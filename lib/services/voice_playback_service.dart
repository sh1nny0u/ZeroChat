import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'backend_http.dart' as http;
import 'resource_cache_service.dart';
import 'session_service.dart';

/// One player per app. Every play rechecks authorization before using disk cache.
class VoicePlaybackService extends ChangeNotifier {
  static final instance = VoicePlaybackService();
  AudioPlayer? _player;
  String? active;
  bool loading = false;
  int _generation = 0;
  VoicePlaybackService() {
    SessionService.instance.addListener(_sessionChanged);
  }
  void _sessionChanged() {
    if (!SessionService.instance.authenticated) unawaited(stop());
  }

  Future<void> stop() async {
    _generation++;
    active = null;
    loading = false;
    final previous = _player;
    _player = null;
    await previous?.dispose();
    notifyListeners();
  }

  Future<void> toggle(String id, String url) async {
    if (active == id) return stop();
    final generation = ++_generation;
    final previous = _player;
    _player = null;
    active = null;
    loading = false;
    await previous?.dispose();
    if (generation != _generation) return;
    final session = SessionService.instance;
    final uri = Uri.parse(ResourceCacheService.resolve(url));
    if (!session.authenticated ||
        !session.owns(uri) ||
        !RegExp(r'/api/audio/[a-f0-9]{64}\.wav$').hasMatch(uri.path)) {
      throw StateError('请登录同一后端后播放有效语音');
    }
    final sessionGeneration = session.generation;
    active = id;
    loading = true;
    notifyListeners();
    try {
      // HEAD uses the same protected route, including when a local file exists.
      final check = await http.head(uri).timeout(const Duration(seconds: 10));
      if (check.statusCode != 200) {
        throw StateError('语音不可访问（${check.statusCode}），请重新登录或手动重试');
      }
      final file = await ResourceCacheService.manager.getSingleFile(
        uri.toString(),
        key: ResourceCacheService.key(url),
        headers: ResourceCacheService.headersFor(url),
      );
      if (generation != _generation ||
          sessionGeneration != session.generation ||
          !session.authenticated) {
        return;
      }
      final player = AudioPlayer();
      _player = player;
      player.onPlayerComplete.listen((_) {
        if (generation == _generation) {
          active = null;
          loading = false;
          notifyListeners();
        }
      });
      await player.play(DeviceFileSource(file.path));
      if (generation != _generation ||
          sessionGeneration != session.generation) {
        await player.dispose();
      } else {
        loading = false;
        notifyListeners();
      }
    } catch (_) {
      if (generation == _generation) {
        active = null;
        loading = false;
        final failed = _player;
        _player = null;
        await failed?.dispose();
        notifyListeners();
      }
      rethrow;
    }
  }
}
