import 'package:flutter/material.dart';
import '../services/session_service.dart';
import '../services/settings_service.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _server = TextEditingController(
    text: SettingsService.instance.backendUrl,
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _setup = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    SessionService.instance.addListener(_sessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SessionService.instance.check();
    });
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SessionService.instance.removeListener(_sessionChanged);
    for (final controller in [_server, _username, _password, _setup]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SettingsService.instance.updateBackendUrl(_server.text.trim());
      await SessionService.instance.check();
    } catch (_) {
      _error = '请输入有效的 HTTP 或 HTTPS 服务器地址';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    if (!SessionService.instance.initialized &&
        (_username.text.trim().runes.length < 6 ||
            _username.text.trim().runes.length > 14 ||
            _password.text.runes.length < 6 ||
            _password.text.runes.length > 14)) {
      setState(() => _error = '新建管理员账号和密码均须为 6 至 14 个字符');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionService.instance.login(
        username: _username.text.trim(),
        password: _password.text,
        setupToken: _setup.text.trim(),
      );
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionService.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(session.initialized ? '登录 ZeroChat' : '创建唯一管理员'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              TextField(
                controller: _server,
                decoration: const InputDecoration(labelText: '后端服务器地址'),
              ),
              TextButton(
                onPressed: _busy || session.checking ? null : _connect,
                child: const Text('连接 / 手动重试'),
              ),
              if (_error ?? session.error case final String message)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (session.error == null && !session.checking) ...[
                TextField(
                  key: const ValueKey('auth-username'),
                  controller: _username,
                  decoration: InputDecoration(
                    labelText: '管理员账号',
                    helperText: session.initialized ? '使用已有账号登录' : '6 至 14 个字符',
                    helperMaxLines: 3,
                  ),
                  autofillHints: const [AutofillHints.username],
                ),
                TextField(
                  key: const ValueKey('auth-password'),
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: '密码',
                    helperText: session.initialized
                        ? '旧版密码可继续登录'
                        : '6 至 14 个字符',
                    helperMaxLines: 3,
                  ),
                  onSubmitted: (_) {
                    if (!_busy) _login();
                  },
                ),
                if (!session.initialized) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '请在服务器本机读取 config/setup-token.txt 中的初始化凭证。管理员创建后关闭初始化入口。',
                    ),
                  ),
                  TextField(
                    key: const ValueKey('auth-setup'),
                    controller: _setup,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '初始化凭证'),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: Text(
                    _busy
                        ? '处理中…'
                        : session.initialized
                        ? '登录'
                        : '创建管理员并登录',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '公网请使用 HTTPS；HTTP 仅用于可信局域网。本设备登录后会安全保存会话，重启后自动恢复，不因时间或闲置过期；主动退出、撤销或重置密码后需重新登录。不会保存账号密码。',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
