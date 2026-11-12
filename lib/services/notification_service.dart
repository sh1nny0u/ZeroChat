import 'diagnostics_service.dart';
import 'background_delivery_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:app_badge_plus/app_badge_plus.dart';

/// 通知服务
/// 处理本地通知和应用角标
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  static NotificationService get instance => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 当前是否在聊天页面（避免重复通知）
  String? _currentChatId;
  void Function(String)? onOpenChat;
  String? pendingChat;

  // Match Android String.hashCode so native and Flutter notifications replace
  // and cancel the same conversation across process restarts.
  static int notificationId(String chatId) {
    var value = 0;
    for (final unit in chatId.codeUnits) {
      value = (31 * value + unit) & 0xffffffff;
    }
    return value >= 0x80000000 ? value - 0x100000000 : value;
  }

  /// 初始化通知服务
  Future<void> init() async {
    if (_initialized) return;

    // Android 初始化设置
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    // iOS 初始化设置
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    final launch = await _notifications.getNotificationAppLaunchDetails();
    pendingChat = launch?.notificationResponse?.payload;

    _initialized = true;
    debugPrint('NotificationService: Initialized');
  }

  /// 设置当前聊天ID（在聊天页面时不显示该聊天的通知）
  void setCurrentChat(String? chatId) {
    _currentChatId = chatId;
  }

  /// 显示消息通知
  Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String message,
    String? avatarUrl,
  }) async {
    // 如果用户正在查看该聊天，不显示通知
    if (_currentChatId == chatId) {
      debugPrint('NotificationService: Skipping notification for current chat');
      return;
    }

    try {
      // Android 通知详情
      final androidDetails = AndroidNotificationDetails(
        'zerochat_messages',
        '消息通知',
        channelDescription: 'ZeroChat 消息通知',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        category: AndroidNotificationCategory.message,
        styleInformation: BigTextStyleInformation(
          '收到新的聊天消息，点击查看',
          contentTitle: 'ZeroChat 新消息',
          summaryText: '新消息',
        ),
      );

      // iOS 通知详情
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // 使用 chatId 的 hashCode 作为通知 ID（确保同一聊天覆盖之前的通知）
      await _notifications.show(
        notificationId(chatId),
        'ZeroChat 新消息',
        '收到新的聊天消息，点击查看',
        details,
        payload: chatId,
      );

      DiagnosticsService.event('resources', 'showed_notification_for');
    } catch (e) {
      DiagnosticsService.event(
        'resources',
        'error_showing_notification',
        error: e,
      );
    }
  }

  /// 使用指定数量更新角标
  Future<void> setBadgeCount(int count) async {
    try {
      final supported = await AppBadgePlus.isSupported();
      if (!supported) return;

      if (count > 0) {
        await AppBadgePlus.updateBadge(count);
      } else {
        await AppBadgePlus.updateBadge(0);
      }
      DiagnosticsService.event('resources', 'badge_set_to');
    } catch (e) {
      DiagnosticsService.event('resources', 'error_setting_badge', error: e);
    }
  }

  /// 清除所有通知
  Future<void> clearAllNotifications() async {
    pendingChat = null;
    _currentChatId = null;
    await _notifications.cancelAll();
    await AppBadgePlus.updateBadge(0);
    debugPrint('NotificationService: Cleared all notifications');
  }

  /// 清除指定聊天的通知
  Future<void> clearChatNotification(String chatId) async {
    await BackgroundDeliveryService.cancelChat(chatId);
    await _notifications.cancel(notificationId(chatId));
    DiagnosticsService.event(
      'resources',
      'cleared_notification_for',
      chatId: chatId,
    );
  }

  /// 通知点击回调
  void _onNotificationTapped(NotificationResponse response) {
    final chatId = response.payload;
    if (chatId != null) {
      DiagnosticsService.event(
        'resources',
        'notification_tapped_for_chat',
        chatId: chatId,
      );
      if (onOpenChat != null) {
        onOpenChat!(chatId);
      } else {
        pendingChat = chatId;
      }
    }
  }
}
