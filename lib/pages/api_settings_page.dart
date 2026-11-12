import '../services/diagnostics_service.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/backend_http.dart' as http;
import '../services/settings_service.dart';
import '../services/api_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../widgets/tts_api_section.dart';
import '../widgets/api_provider_presets.dart';

/// API 设置页面
/// 配置主聊天、意图识别、图像识别 API
class ApiSettingsPage extends StatefulWidget {
  const ApiSettingsPage({super.key});

  @override
  State<ApiSettingsPage> createState() => _ApiSettingsPageState();
}

class _ApiSettingsPageState extends State<ApiSettingsPage> {
  // 后端服务器
  late TextEditingController _backendUrlController;
  bool _isTestingConnection = false;
  bool? _connectionSuccess;
  String? _connectionError;

  // 模型列表
  List<String> _availableModels = [];
  bool _isLoadingModels = false;

  // 主聊天 API
  late TextEditingController _chatUrlController;
  late TextEditingController _chatKeyController;
  late TextEditingController _chatModelController;

  // 意图识别 API
  bool _intentEnabled = false;
  late TextEditingController _intentUrlController;
  late TextEditingController _intentKeyController;
  late TextEditingController _intentModelController;
  List<String> _intentModels = [];
  bool _isLoadingIntentModels = false;
  bool _visionEnabled = false;
  bool _dirty = false, _updating = false;
  late TextEditingController _visionUrlController,
      _visionKeyController,
      _visionModelController;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;

    _backendUrlController = TextEditingController(text: settings.backendUrl);

    _chatUrlController = TextEditingController(text: settings.chatApiUrl);
    _chatKeyController = TextEditingController(text: settings.chatApiKey);
    _chatModelController = TextEditingController(text: settings.chatModel);

    _intentEnabled = settings.intentEnabled;
    _intentUrlController = TextEditingController(text: settings.intentApiUrl);
    _intentKeyController = TextEditingController(text: settings.intentApiKey);
    _intentModelController = TextEditingController(text: settings.intentModel);
    _visionEnabled = settings.visionEnabled;
    _visionUrlController = TextEditingController(text: settings.visionApiUrl);
    _visionKeyController = TextEditingController();
    _visionModelController = TextEditingController(text: settings.visionModel);
    for (final controller in _controllers) {
      controller.addListener(_edited);
    }
    settings.addListener(_settingsChanged);
  }

  List<TextEditingController> get _controllers => [
    _backendUrlController,
    _chatUrlController,
    _chatKeyController,
    _chatModelController,
    _intentUrlController,
    _intentKeyController,
    _intentModelController,
    _visionUrlController,
    _visionKeyController,
    _visionModelController,
  ];

  void _edited() {
    if (!_updating) _dirty = true;
  }

  void _settingsChanged() {
    if (!mounted || _dirty) return;
    final settings = SettingsService.instance;
    _updating = true;
    _chatUrlController.text = settings.chatApiUrl;
    _chatModelController.text = settings.chatModel;
    _intentUrlController.text = settings.intentApiUrl;
    _intentModelController.text = settings.intentModel;
    _visionUrlController.text = settings.visionApiUrl;
    _visionModelController.text = settings.visionModel;
    _updating = false;
    setState(() {
      _intentEnabled = settings.intentEnabled;
      _visionEnabled = settings.visionEnabled;
    });
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_settingsChanged);
    for (final controller in _controllers) {
      controller.removeListener(_edited);
    }
    _backendUrlController.dispose();
    _chatUrlController.dispose();
    _chatKeyController.dispose();
    _chatModelController.dispose();
    _intentUrlController.dispose();
    _intentKeyController.dispose();
    _intentModelController.dispose();
    _visionUrlController.dispose();
    _visionKeyController.dispose();
    _visionModelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('AI 接口设置'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text('保存', style: TextStyle(color: Color(0xFF07C160))),
          ),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 后端服务器
          _buildSectionTitle('后端服务器'),
          _buildSection([
            _buildTextField(
              '服务器地址',
              _backendUrlController,
              'http://localhost:8000',
            ),
            _buildDivider(),
            _buildConnectionTestButton(),
          ]),

          const SizedBox(height: 20),

          // 主聊天 API
          _buildSectionTitle('主聊天 API（保存在后端）'),
          _buildSection([
            ApiProviderPresets(
              urlController: _chatUrlController,
              onSelected: (preset) {
                if (preset.url.isEmpty) return;
                if (ApiProviderPreset.forUrl(_chatUrlController.text) == preset)
                  return;
                setState(() {
                  _chatUrlController.text = preset.url;
                  _chatKeyController.clear();
                  _chatModelController.clear();
                  _availableModels = [];
                  _dirty = true;
                });
              },
            ),
            _buildTextField(
              'API URL',
              _chatUrlController,
              'https://api.openai.com/v1',
            ),
            _buildDivider(),
            _buildTextField(
              'API Key',
              _chatKeyController,
              '同来源留空保留；更换来源须填新密钥',
              obscure: true,
            ),
            _buildDivider(),
            _buildApiConnectButton(),
            _buildDivider(),
            _buildModelSelector(),
          ]),

          const SizedBox(height: 20),

          // 意图识别 API
          _buildSectionTitle('意图识别 API'),
          _buildSection([
            _buildSwitchItem('启用意图识别', _intentEnabled, (v) {
              _dirty = true;
              setState(() => _intentEnabled = v);
            }),
            if (_intentEnabled) ...[
              _buildDivider(),
              _buildTextField(
                'API URL',
                _intentUrlController,
                'https://api.openai.com/v1',
              ),
              _buildDivider(),
              _buildTextField(
                'API Key',
                _intentKeyController,
                '同来源留空保留；更换来源须填新密钥',
                obscure: true,
              ),
              _buildDivider(),
              _buildIntentModelFetchButton(),
              _buildDivider(),
              _buildIntentModelSelector(),
            ],
          ]),

          const SizedBox(height: 20),

          _buildSectionTitle('图片识别 API（地址与密钥都留空时继承聊天）'),
          _buildSection([
            _buildSwitchItem(
              '启用图片识别',
              _visionEnabled,
              (v) => setState(() {
                _dirty = true;
                _visionEnabled = v;
              }),
            ),
            if (_visionEnabled) ...[
              _buildDivider(),
              _buildTextField('API URL', _visionUrlController, '留空继承聊天供应商'),
              _buildDivider(),
              _buildTextField(
                'API Key',
                _visionKeyController,
                '同来源留空保留；换供应商需新密钥',
                obscure: true,
              ),
              _buildDivider(),
              _buildTextField('模型', _visionModelController, '填写支持图片的模型'),
              TextButton(
                onPressed: () => _fetchPurposeModels('vision'),
                child: const Text('读取已保存视觉配置的模型列表'),
              ),
              TextButton(
                onPressed: _testVision,
                child: const Text('选择图片测试已保存配置（可能收费）'),
              ),
            ],
          ]),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '更换供应商来源会停用旧密钥，请填写该供应商的新密钥。模型列表使用已保存配置；图片可从聊天附件发送测试，可能产生费用。',
            ),
          ),
          _buildSectionTitle('语音合成 TTS'),
          const TtsApiSection(),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            obscureText: obscure,
            minLines: 1,
            maxLines: obscure ? 1 : 3,
            decoration: InputDecoration(
              helperText: hint,
              helperMaxLines: 5,
              hintMaxLines: 5,
              hintStyle: const TextStyle(color: Color(0xFFCCCCCC)),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchItem(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
          Switch(
            value: value,
            activeColor: const Color(0xFF07C160),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, indent: 16);
  }

  Widget _buildConnectionTestButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isTestingConnection ? null : _testConnection,
              icon: _isTestingConnection
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _connectionSuccess == null
                          ? Icons.wifi_find
                          : (_connectionSuccess!
                                ? Icons.check_circle
                                : Icons.error),
                      size: 18,
                    ),
              label: Text(_isTestingConnection ? '测试中...' : '测试连接'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _connectionSuccess == true
                    ? const Color(0xFF07C160)
                    : (_connectionSuccess == false ? Colors.red : null),
                foregroundColor: _connectionSuccess != null
                    ? Colors.white
                    : null,
              ),
            ),
          ),
          if (_connectionError != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _connectionError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _testConnection() async {
    final url = _backendUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connectionSuccess = false;
        _connectionError = '请输入服务器地址';
      });
      return;
    }

    setState(() {
      _isTestingConnection = true;
      _connectionSuccess = null;
      _connectionError = null;
    });

    try {
      DiagnosticsService.event('settings', 'legacy_event');
      final response = await http
          .get(Uri.parse('$url/api/health'))
          .timeout(const Duration(seconds: 5));
      if (!mounted || url != _backendUrlController.text.trim()) return;

      if (response.statusCode == 200) {
        setState(() {
          _connectionSuccess = true;
          _connectionError = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ 连接成功'),
              backgroundColor: Color(0xFF07C160),
            ),
          );
        }
      } else {
        setState(() {
          _connectionSuccess = false;
          _connectionError = 'HTTP ${response.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      DiagnosticsService.event('settings', 'legacy_event', error: e);
      setState(() {
        _connectionSuccess = false;
        _connectionError = e.toString().length > 50
            ? '${e.toString().substring(0, 50)}...'
            : e.toString();
      });
    } finally {
      if (mounted)
        setState(() {
          _isTestingConnection = false;
        });
    }
  }

  /// 获取可用模型列表
  Future<void> _fetchModels() async {
    setState(() => _isLoadingModels = true);

    try {
      final backendUrl = _backendUrlController.text.trim();
      final response = await http.get(
        Uri.parse('$backendUrl/api/settings/models'),
      );
      if (!mounted || backendUrl != _backendUrlController.text.trim()) return;
      if (response.statusCode != 200) throw StateError('后端模型列表读取失败');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] != true) throw StateError('供应商模型列表读取失败');
        if (data['success'] == true) {
          final models = List<String>.from(data['models'] ?? []);
          setState(() {
            _availableModels = models;
          });
        }
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模型读取失败，请先保存后端 API 设置，再手动重试')),
        );
    } finally {
      if (mounted) setState(() => _isLoadingModels = false);
    }
  }

  Widget _buildApiConnectButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isLoadingModels ? null : _fetchModels,
              icon: _isLoadingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download),
              label: Text(_isLoadingModels ? '获取中...' : '获取模型列表'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelInput(TextEditingController controller, List<String> models) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTextField('模型', controller, '填写供应商控制台的完整模型 ID；也可从已读取列表选择'),
        if (models.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey(models.join('|')),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '从列表填入模型'),
              items: models
                  .map(
                    (model) => DropdownMenuItem(
                      value: model,
                      child: Text(model, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) controller.text = value;
              },
            ),
          ),
      ],
    );
  }

  Widget _buildModelSelector() =>
      _modelInput(_chatModelController, _availableModels);

  /// 意图识别模型获取按钮
  Widget _buildIntentModelFetchButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型列表', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isLoadingIntentModels ? null : _fetchIntentModels,
              icon: _isLoadingIntentModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(_isLoadingIntentModels ? '获取中...' : '获取模型列表'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF07C160),
                side: const BorderSide(color: Color(0xFF07C160)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 意图识别模型选择器
  Widget _buildIntentModelSelector() =>
      _modelInput(_intentModelController, _intentModels);

  /// 获取意图识别模型列表
  Future<void> _fetchIntentModels() async {
    setState(() => _isLoadingIntentModels = true);
    try {
      final response = await http.get(
        Uri.parse(
          '${SettingsService.instance.backendUrl}/api/settings/models?purpose=intent',
        ),
      );
      if (response.statusCode != 200) throw StateError('后端模型列表读取失败');
      final data = jsonDecode(response.body) as Map;
      if (data['success'] != true) throw StateError(data['error'].toString());
      if (mounted)
        setState(
          () => _intentModels = List<String>.from(data['models'] as List),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('获取模型失败，请检查后端配置后手动重试')));
    } finally {
      if (mounted) setState(() => _isLoadingIntentModels = false);
    }
  }

  Future<void> _saveSettings() async {
    final settings = SettingsService.instance;
    try {
      // 保存后端服务器地址
      await settings.updateBackendUrl(_backendUrlController.text.trim());

      // 保存主聊天 API
      await settings.updateChatApi(
        url: _chatUrlController.text.trim(),
        key: _chatKeyController.text.trim(),
        model: _chatModelController.text.trim(),
      );

      // 保存意图识别 API
      await settings.updateIntentApi(
        enabled: _intentEnabled,
        url: _intentUrlController.text.trim(),
        key: _intentKeyController.text.trim(),
        model: _intentModelController.text.trim(),
      );
      await settings.updateVisionApi(
        enabled: _visionEnabled,
        url: _visionUrlController.text.trim(),
        key: _visionKeyController.text.trim(),
        model: _visionModelController.text.trim(),
      );

      // 自动同步到后端
      final synced = await settings.syncApiSettingsToBackend();
      DiagnosticsService.event('settings', 'legacy_event');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(synced ? '设置已保存到后端' : '后端保存失败，请保留输入并手动重试'),
            duration: const Duration(seconds: 1),
          ),
        );
        if (synced) Navigator.pop(context);
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设置未保存到后端，请检查连接或重新登录后手动重试')),
        );
    }
  }

  Future<void> _fetchPurposeModels(String purpose) async {
    try {
      final response = await http.get(
        Uri.parse(
          '${SettingsService.instance.backendUrl}/api/settings/models?purpose=$purpose',
        ),
      );
      final data = jsonDecode(response.body) as Map;
      if (response.statusCode != 200 || data['success'] != true)
        throw StateError('${data['error']}');
      if (!mounted) return;
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final model in data['models'] as List)
                ListTile(
                  title: Text('$model'),
                  onTap: () => Navigator.pop(ctx, '$model'),
                ),
            ],
          ),
        ),
      );
      if (choice != null && mounted)
        setState(() => _visionModelController.text = choice);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('模型列表读取失败：$error')));
    }
  }

  Future<void> _testVision() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (file == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('测试图片识别'),
        content: const Text(
          '图片将发送给已保存的视觉供应商，可能产生费用。每次确认都会创建新请求；失败或结果不明不会自动重试。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认发送'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (await file.length() > 9 * 1024 * 1024)
        throw StateError('图片超过 9 MiB，请重新选择');
      final extension = file.path.toLowerCase();
      final result = await ApiService.request('/api/chat/vision', {
        'request_id': ApiService.requestId(),
        'image_base64': base64Encode(await File(file.path).readAsBytes()),
        'mime_type': extension.endsWith('.png')
            ? 'image/png'
            : extension.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg',
        'user_prompt': '请简要描述图片内容，用于验证图片识别配置。',
      });
      if (mounted)
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('图片识别成功'),
            content: SingleChildScrollView(
              child: SelectableText('${result['reply']}'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          ),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('图片测试未完成：$error')));
    }
  }
}
