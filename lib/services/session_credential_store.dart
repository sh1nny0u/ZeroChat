import 'dart:io';
import 'package:flutter/services.dart';

/// Only the native vault persists credentials; preferences and exports never do.
class SessionCredentialStore {
  static const channel = MethodChannel('zerochat/session');
  Future<void> _pending = Future<void>.value();

  Future<T> _ordered<T>(Future<T> Function() action) {
    final operation = _pending.then((_) => action());
    _pending = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<Map<String, String>?> read(String server) => _ordered(() async {
    try {
      final value = await channel.invokeMapMethod<String, String>('read', {
        'server': server,
      });
      return value == null ? null : Map<String, String>.from(value);
    } on MissingPluginException {
      if (Platform.isAndroid) throw StateError('无法读取本机安全登录凭证，请重试');
      return null;
    }
  });

  Future<void> write(Map<String, String> value) => _ordered(() async {
    try {
      await channel.invokeMethod<void>('write', value);
    } on MissingPluginException {
      if (Platform.isAndroid) throw StateError('无法安全保存登录状态，请重试');
      // Non-Android platforms have no Android Keystore; never persist plaintext credentials.
    }
  });

  Future<void> clear() => _ordered(() async {
    try {
      await channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      if (Platform.isAndroid) throw StateError('无法清除本机登录凭证，请重试');
    }
  });
}
