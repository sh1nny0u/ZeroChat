import 'package:flutter/material.dart';

class ApiProviderPreset {
  final String name, url;
  const ApiProviderPreset(this.name, this.url);
  static const choices = [
    ApiProviderPreset('DeepSeek 官方', 'https://api.deepseek.com'),
    ApiProviderPreset('智谱 GLM 官方', 'https://open.bigmodel.cn/api/paas/v4'),
    ApiProviderPreset('Kimi 官方', 'https://api.moonshot.cn/v1'),
    ApiProviderPreset(
      '通义千问官方',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    ),
    ApiProviderPreset('自定义兼容接口', ''),
  ];

  static ApiProviderPreset? forUrl(String value) {
    if (value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri != null) {
      final path = uri.path
          .replaceFirst(RegExp(r'/chat/completions/?$'), '')
          .replaceFirst(RegExp(r'/$'), '');
      for (final preset in choices.where((p) => p.url.isNotEmpty)) {
        final base = Uri.parse(preset.url);
        final hostMatches =
            uri.host.toLowerCase() == base.host ||
            (base.host == 'api.moonshot.cn' &&
                uri.host.toLowerCase() == 'api.moonshot.ai');
        if (uri.scheme == 'https' &&
            hostMatches &&
            uri.userInfo.isEmpty &&
            uri.port == 443 &&
            (path == base.path ||
                (base.host == 'api.deepseek.com' && path == '/v1'))) {
          return preset;
        }
      }
    }
    return choices.last;
  }
}

class ApiProviderPresets extends StatelessWidget {
  final ValueChanged<ApiProviderPreset> onSelected;
  final TextEditingController urlController;
  final bool enabled;
  const ApiProviderPresets({
    super.key,
    required this.urlController,
    required this.onSelected,
    this.enabled = true,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: ValueListenableBuilder<TextEditingValue>(
      valueListenable: urlController,
      builder: (context, value, _) {
        final selected = ApiProviderPreset.forUrl(value.text)?.name;
        return DropdownButtonFormField<String>(
          key: ValueKey(selected),
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '接口供应商',
            helperText: '只填写地址；请填入对应密钥，模型可手动填写或保存后读取。',
            helperMaxLines: 4,
          ),
          items: [
            for (final preset in ApiProviderPreset.choices)
              DropdownMenuItem(value: preset.name, child: Text(preset.name)),
          ],
          onChanged: !enabled
              ? null
              : (name) {
                  if (name != null) {
                    onSelected(
                      ApiProviderPreset.choices.firstWhere(
                        (p) => p.name == name,
                      ),
                    );
                  }
                },
        );
      },
    ),
  );
}
