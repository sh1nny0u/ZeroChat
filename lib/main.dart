import 'services/session_service.dart';
import 'services/resource_cache_service.dart';
import 'services/backend_sync_service.dart';
import 'pages/auth_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pages/chat_list_page.dart';
import 'pages/contacts_page.dart';
import 'pages/discover_page.dart';
import 'pages/profile_page.dart';
import 'pages/create_group_page.dart';
import 'widgets/tab_bar.dart';
import 'services/storage_service.dart';
import 'services/settings_service.dart';
import 'services/role_service.dart';
import 'services/chat_list_service.dart';
import 'services/notification_service.dart';
import 'pages/chat_detail_page.dart';
import 'services/group_chat_service.dart';
import 'services/background_delivery_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ========== 请求权限 ==========
  await _requestPermissions();

  // ========== 初始化服务 ==========
  await StorageService.init();
  await SettingsService.init();

  ResourceCacheService.setSession(identity: 'anonymous', accessAllowed: false);
  await NotificationService.instance.init();

  // ========== 后端同步（异步，不阻塞 UI） ==========
  var hadSession = SessionService.instance.ready;
  SessionService.instance.addListener(() {
    if (SessionService.instance.ready) {
      if (!hadSession) BackendSyncService.start();
    } else {
      BackendSyncService.stop();
      if (hadSession) {
        NotificationService.instance.clearAllNotifications().catchError((_) {});
      }
    }
    hadSession = SessionService.instance.ready;
  });

  // 设置状态栏样式
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const ZeroChatApp());
}

/// 后端同步状态
bool get isBackendAvailable => SessionService.instance.ready;

/// 请求运行时权限
Future<void> _requestPermissions() async {
  // 请求通知权限
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // 请求相机权限
  if (await Permission.camera.isDenied) {
    await Permission.camera.request();
  }

  // 请求存储权限（Android 13+ 使用 photos）
  if (await Permission.photos.isDenied) {
    await Permission.photos.request();
  }

  // 旧版存储权限
  if (await Permission.storage.isDenied) {
    await Permission.storage.request();
  }

  debugPrint('✅ Permissions requested');
}

class ZeroChatApp extends StatelessWidget {
  static var navigatorKey = GlobalKey<NavigatorState>();
  static String? _navigationSession;
  const ZeroChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SessionService.instance,
      builder: (_, _) {
        final navigationSession = SessionService.instance.ready
            ? SessionService.instance.sessionId
            : 'signed-out';
        if (_navigationSession != navigationSession) {
          _navigationSession = navigationSession;
          navigatorKey = GlobalKey<NavigatorState>();
        }
        return MaterialApp(
          key: ValueKey(
            SessionService.instance.ready
                ? SessionService.instance.sessionId
                : 'signed-out',
          ),
          navigatorKey: navigatorKey,
          title: 'ZeroChat',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF07C160),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            listTileTheme: const ListTileThemeData(
              tileColor: Colors.white,
              contentPadding: EdgeInsets.symmetric(horizontal: 16),
              iconColor: Color(0xFF888888),
              minVerticalPadding: 12,
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 13,
                ),
              ),
            ),
            inputDecorationTheme: const InputDecorationTheme(
              hintMaxLines: 5,
              helperMaxLines: 5,
              errorMaxLines: 5,
              filled: true,
              fillColor: Colors.white,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFE5E5E5), width: .5),
              ),
            ),
            scaffoldBackgroundColor: const Color(0xFFEDEDED),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFEDEDED),
              foregroundColor: Color(0xFF000000),
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: true,
              titleTextStyle: TextStyle(
                color: Color(0xFF000000),
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          home: SessionService.instance.ready
              ? const MainPage()
              : const AuthPage(),
        );
      },
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;
  final GlobalKey<ContactsPageState> _contactsKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    NotificationService.instance.onOpenChat = _openNotification;
    BackgroundDeliveryService.onOpenChat = _openNotification;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final chat =
          NotificationService.instance.pendingChat ??
          await BackgroundDeliveryService.launchChat();
      NotificationService.instance.pendingChat = null;
      if (chat != null) _openNotification(chat);
    });
  }

  @override
  void dispose() {
    NotificationService.instance.onOpenChat = null;
    BackgroundDeliveryService.onOpenChat = null;
    super.dispose();
  }

  void _openNotification(String chat) {
    if (!mounted || !SessionService.instance.ready) return;
    final role = RoleService.getRoleById(chat);
    final group = GroupChatService.getGroup(chat);
    if (role == null && group == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatDetailPage(
          chatId: chat,
          chatName: role?.name ?? group!.name,
          isGroup: group != null,
          memberIds: group?.memberIds,
        ),
      ),
    );
  }

  List<Widget> get _pages => [
    const ChatListPage(),
    ContactsPage(key: _contactsKey),
    const DiscoverPage(),
    const ProfilePage(),
  ];

  final List<String> _titles = const ['ZeroChat', '通讯录', '发现', '我'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        actions: [
          // 只保留 + 按钮，去掉搜索
          IconButton(
            onPressed: () => _handleAddAction(context),
            icon: const Icon(Icons.add_circle_outline, size: 24),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!SessionService.instance.connected)
            MaterialBanner(
              content: Text(SessionService.instance.error ?? '连接暂时中断，请恢复后手动重试'),
              actions: [
                TextButton(
                  onPressed: () => SessionService.instance.validate(),
                  child: const Text('重新连接'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(index: _currentIndex, children: _pages),
          ),
        ],
      ),
      bottomNavigationBar: AppBottomTabBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }

  void _handleAddAction(BuildContext context) {
    // 统一显示菜单，所有页面都一样
    _showAddMenu(context);
  }

  void _showAddRoleDialog(BuildContext context) async {
    final nameController = TextEditingController(
      text: StorageService.getString('new_role_name'),
    );
    final promptController = TextEditingController(
      text: StorageService.getString('new_role_prompt'),
    );
    void keepDraft() {
      StorageService.setString('new_role_name', nameController.text);
      StorageService.setString('new_role_prompt', promptController.text);
    }

    nameController.addListener(keepDraft);
    promptController.addListener(keepDraft);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建角色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '角色名称',
                hintText: '例如: 编程助手',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: promptController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '角色设定',
                hintText: '例如: 你是一个专业的编程助手...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (confirmed == true && nameController.text.isNotEmpty) {
      try {
        await RoleService.createRole(
          name: nameController.text,
          systemPrompt: promptController.text.isNotEmpty
              ? promptController.text
              : '你是一个友好的AI助手。',
        );
        await StorageService.remove('new_role_name');
        await StorageService.remove('new_role_prompt');
        if (!mounted) return;
        // 刷新列表
        ChatListService.instance.refresh();
        _contactsKey.currentState?.refresh();
        setState(() {});
      } catch (_) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('角色创建未确认，名称和设定已保留。请先刷新角色列表，再手动重试'),
              action: SnackBarAction(
                label: '查看草稿',
                onPressed: () => _showAddRoleDialog(context),
              ),
            ),
          );
      }
    }
    nameController.dispose();
    promptController.dispose();
  }

  void _showAddMenu(BuildContext context) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 150,
        kToolbarHeight + MediaQuery.of(context).padding.top,
        10,
        0,
      ),
      color: const Color(0xFF4C4C4C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _buildMenuItem(Icons.group_add, '发起群聊'),
        _buildMenuItem(Icons.person_add, '添加朋友'),
      ],
    ).then((value) {
      if (value == '发起群聊') {
        _navigateToCreateGroup();
      } else if (value == '添加朋友') {
        _showAddRoleDialog(context);
      }
    });
  }

  PopupMenuItem<String> _buildMenuItem(IconData icon, String text) {
    return PopupMenuItem<String>(
      value: text,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    );
  }

  void _navigateToCreateGroup() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    ).then((_) {
      ChatListService.instance.refresh();
      setState(() {});
    });
  }
}
