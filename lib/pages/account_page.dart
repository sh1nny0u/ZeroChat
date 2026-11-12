import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/backend_http.dart' as http;
import '../services/session_service.dart';
import '../services/background_delivery_service.dart';
import '../widgets/wechat_form_list.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  List<dynamic> _sessions = [];
  String? _error;
  final _old = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _old.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await BackgroundDeliveryService.refreshStatus();
      final result = await http.get(
        Uri.parse('${SessionService.backend}/api/auth/sessions'),
      );
      if (result.statusCode != 200) throw StateError('设备列表读取失败');
      if (mounted)
        setState(() {
          _sessions = jsonDecode(result.body)['sessions'] as List;
          _error = null;
        });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取设备列表，请手动重试');
    }
  }

  Future<void> _revoke(String id) async {
    try {
      final result = await http.delete(
        Uri.parse('${SessionService.backend}/api/auth/sessions/$id'),
      );
      if (result.statusCode == 200) {
        if (id == SessionService.instance.sessionId) {
          SessionService.instance.invalidate();
        } else {
          await _load();
        }
      } else {
        if (mounted) setState(() => _error = '撤销失败，请手动重试');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法连接后端，撤销未确认，请手动重试');
    }
  }

  Future<void> _change() async {
    if (_password.text.runes.length < 6 || _password.text.runes.length > 14) {
      setState(() => _error = '新密码须为 6 至 14 个字符');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await http.post(
        Uri.parse('${SessionService.backend}/api/auth/password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'old_password': _old.text,
          'new_password': _password.text,
        }),
      );
      if (result.statusCode != 200)
        throw StateError(jsonDecode(result.body)['detail'].toString());
      _old.clear();
      _password.clear();
      await _load();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('密码已修改，其他设备已退出')));
    } catch (error) {
      if (mounted) setState(() => _error = '修改失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账号与设备')),
    body: WechatFormList(
      children: [
        const ListTile(
          title: Text('本设备保持登录'),
          subtitle: Text(
            '登录凭证经本机安全存储，重启后自动恢复；会话长期有效，不因闲置退出。主动退出、撤销设备或密码重置仍会使登录失效。',
          ),
        ),
        SwitchListTile(
          title: const Text('Android 后台消息接收'),
          subtitle: const Text(
            '开启后显示常驻通知并加密保存此会话凭证。退出会清除，通知不显示正文。Android 15 起此类服务每天受 6 小时后台时限；强停、重启或省电限制后需打开应用重新开启，不保证全天送达。',
          ),
          value: BackgroundDeliveryService.enabled,
          onChanged: _busy
              ? null
              : (value) async {
                  setState(() => _busy = true);
                  try {
                    if (value) {
                      await BackgroundDeliveryService.enable();
                    } else {
                      await BackgroundDeliveryService.disable();
                    }
                  } catch (_) {
                    if (mounted) setState(() => _error = '后台接收未开启，请检查通知权限并重试');
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        TextButton(onPressed: _load, child: const Text('刷新设备 / 手动重试')),
        for (final device in _sessions)
          ListTile(
            title: Text(
              '${device['device']}${device['current'] == true ? '（当前设备）' : ''}',
            ),
            subtitle: Text(
              '登录：${DateTime.fromMillisecondsSinceEpoch(((device['created'] as num) * 1000).toInt()).toLocal()}\n最后活动：${DateTime.fromMillisecondsSinceEpoch(((device['last_seen'] as num) * 1000).toInt()).toLocal()}',
            ),
            trailing: TextButton(
              onPressed: () => _revoke(device['id'] as String),
              child: const Text('撤销'),
            ),
          ),
        const Divider(),
        TextField(
          controller: _old,
          obscureText: true,
          decoration: const InputDecoration(labelText: '旧密码'),
        ),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '新密码',
            helperText: '6 至 14 个字符',
            helperMaxLines: 3,
          ),
        ),
        FilledButton(
          onPressed: _busy ? null : _change,
          child: const Text('修改密码并撤销其他设备'),
        ),
        const Text(
          '忘记密码：服务器管理员在本机 server 目录运行 python -m tools.reset_admin。重置会使全部设备会话失效。',
        ),
        TextButton(
          onPressed: () async {
            try {
              await SessionService.instance.logout();
            } catch (_) {
              SessionService.instance.invalidate(
                '本机已退出；服务端撤销未确认，请重新登录后在设备列表撤销旧会话',
              );
            }
          },
          child: const Text('退出登录'),
        ),
      ],
    ),
  );
}
