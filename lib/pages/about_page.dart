import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _license(
    BuildContext context,
    String asset,
    String title,
  ) async {
    final text = await rootBundle.loadString(asset);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(text),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于 ZeroChat')),
    body: ListView(
      children: [
        const ListTile(
          title: Text('ZeroChat'),
          subtitle: Text('2.0.0 · 自托管 AI 聊天伴侣'),
        ),
        const Divider(height: 1),
        const ListTile(
          title: Text('对应版本源代码'),
          subtitle: SelectableText(
            'https://github.com/sh1nny0u/ZeroChat/tree/V2.0.0.261112',
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('本软件按 AGPL-3.0-only 提供，不作任何担保。原 MIT 代码的授权声明保留。'),
        ),
        ListTile(
          title: const Text('AGPL 3.0 许可证'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _license(context, 'LICENSE', 'AGPL 3.0'),
        ),
        ListTile(
          title: const Text('版权与来源声明'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _license(context, 'NOTICE', '版权与来源'),
        ),
        ListTile(
          title: const Text('原 MIT 授权'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              _license(context, 'licenses/MIT-original.txt', '原 MIT 授权'),
        ),
        ListTile(
          title: const Text('第三方开源许可'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'ZeroChat',
            applicationVersion: '2.0.0',
          ),
        ),
      ],
    ),
  );
}
