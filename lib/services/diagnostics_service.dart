import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Only structured metadata enters diagnostics; never pass prompts or responses.
class DiagnosticsService {
  static String reference(String value) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(value)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static void event(
    String module,
    String name, {
    String? chatId,
    String? roleId,
    String? requestId,
    Object? error,
    int? count,
    int? elapsedUs,
    int? status,
  }) {
    if (!kDebugMode && !kProfileMode) return;
    final safe = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
    if (!safe.hasMatch(module) || !safe.hasMatch(name)) return;
    debugPrint(
      jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'module': module,
        'event': name,
        if (chatId != null) 'chat_ref': reference(chatId),
        if (roleId != null) 'role_ref': reference(roleId),
        if (requestId != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId))
          'request_id': requestId,
        if (error != null) 'error_type': error.runtimeType.toString(),
        'count': ?count,
        'elapsed_us': ?elapsedUs,
        'status': ?status,
      }),
    );
  }
}
