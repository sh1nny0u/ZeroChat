import 'dart:io';
import 'package:flutter/services.dart';
import 'session_service.dart';

/// Optional native receiver: explicitly enabled and stopped on logout/revocation.
class BackgroundDeliveryService {
  static const channel = MethodChannel('zerochat/delivery');
  static bool enabled = false;
  static Future<void> enable() async {
    if (!Platform.isAndroid) throw StateError('后台接收目前仅支持 Android');
    final uri = Uri.parse('${SessionService.backend}/api/notifications/poll');
    final authorization = SessionService.instance.headers(uri)['Authorization'];
    if (authorization == null) throw StateError('请先登录');
    await channel.invokeMethod<void>('enable', {
      'server': SessionService.backend,
      'authorization': authorization,
    });
    enabled = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openChat') onOpenChat?.call(call.arguments as String);
    });
  }

  static void Function(String)? onOpenChat;
  static void _listen() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openChat') onOpenChat?.call(call.arguments as String);
    });
  }

  static Future<bool> refreshStatus() async {
    if (!Platform.isAndroid) return false;
    _listen();
    try {
      enabled = await channel.invokeMethod<bool>('status') ?? false;
    } on MissingPluginException {
      enabled = false;
    }
    return enabled;
  }

  static Future<void> cancelChat(String chat) async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('cancelChat', {'chat': chat});
    } on MissingPluginException {
      /* Native receiver unavailable; no credentials are persisted here. */
    }
  }

  static Future<void> disable() async {
    enabled = false;
    if (Platform.isAndroid) {
      try {
        await channel.invokeMethod<void>('disable');
      } on MissingPluginException {
        /* Native receiver unavailable; no credentials are persisted here. */
      }
    }
  }

  static Future<String?> launchChat() async {
    if (!Platform.isAndroid) return null;
    _listen();
    try {
      return await channel.invokeMethod<String>('launchChat');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> claim(String chat, List<String> ids) async {
    if (!Platform.isAndroid) return true;
    try {
      return await channel.invokeMethod<bool>('claim', {
            'chat': chat,
            'ids': ids,
          }) ??
          true;
    } on MissingPluginException {
      return true;
    }
  }
}
