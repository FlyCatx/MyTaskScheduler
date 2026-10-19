// 「设置 → 模型」页（0.0.4）。
//
// 与其它部分的约定：
//   * 页面上的一切修改只写入 [SettingsController.draft]，由设置窗口统一保存；
//     本页从不读写 settings.json，也不调用 controller.save()；
//   * 表单只是草稿的一份快照：页面记下最后同步进表单的 profile，当 controller.draft
//     里这条连接被外部替换（保存后 revision/凭据变化、放弃后回滚、load 重新载入）时
//     重新同步文本、选择与 revision，保证下一次保存用的是磁盘上的新 revision；
//   * API Key 只写不读：输入后直接交给原生凭据存储，结束后立刻清空 Dart 侧文本，
//     之后只显示“已配置/未配置”，任何位置都不会回显密钥。密钥立即生效，不随窗口
//     取消/放弃回滚；但原生层把密钥绑定到**已保存**连接的 chatUrl 主机，所以新连接
//     或地址/认证方式有未保存修改时页面直接禁用并说明原因；“已生效但设置文件写入
//     失败”的部分失败按警告呈现，不是失败；
//   * 「获取模型列表」「测试模型响应」是真实的网络调用，由原生层用**已保存**的
//     profile 修订发请求。表单里有未保存的修改时页面会明确说明这一点（地址/认证
//     方式有未保存修改时直接禁用探测），并且绝不把“能列出模型”写成“JSON 分析能力
//     已验证”；
//   * 删除默认连接只清空草稿里的默认选择并提示用户显式重选，绝不自动挑另一条连接；
//   * 校验走 [ProviderProfile.validate] / controller.validateDraft，错误按字段展示。

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../../state/settings_controller.dart';
import '../widgets/bezier_ui.dart';
import '../theme.dart';

/// 校验文案 → 字段的稳定键（只用于把错误提示放到对应输入框下面）。
const String _kNameField = 'name';
const String _kBaseUrlField = 'baseUrl';
const String _kChatUrlField = 'chatUrl';
const String _kModelsUrlField = 'modelsUrl';
const String _kModelIdField = 'modelId';
const String _kIdField = 'id';
const String _kAuthField = 'authMode';
const String _kEnvField = 'apiKeyEnv';
const String _kEffortField = 'effort';
const String _kOtherField = 'other';

/// 「设置 → 模型」：连接列表 + 编辑表单 + 连通性探测 + 默认连接。
class SettingsModelPage extends StatefulWidget {
  final SettingsController controller;

  const SettingsModelPage({super.key, required this.controller});

  @override
  State<SettingsModelPage> createState() => _SettingsModelPageState();
}

class _SettingsModelPageState extends State<SettingsModelPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _chatUrl = TextEditingController();
  final TextEditingController _modelsUrl = TextEditingController();
  final TextEditingController _modelId = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();

  String _formId = '';
  int _revision = 0;

  ProviderProtocol _protocol = ProviderProtocol.deepseekChat;
  ThinkingMode _thinking = ThinkingMode.disabled;
  String? _effort;
  bool _jsonMode = true;
  String _authMode = AuthMode.bearer;

  bool _advancedOpen = false;
  bool _keyEditing = false;
  bool _credentialConfigured = false;
  String? _credentialHost;
  bool _credentialBusy = false;
  String? _credentialError;
  String? _keyStatus;

  final Set<String> _touched = <String>{};

  List<String> _probeModels = const <String>[];
  String? _probeSummary;
  String? _probeError;

  String? _actionStatus;
  String? _actionError;

  /// 凭据“部分失败”警告：密钥已经生效，只是 settings.json 写不进去。
  /// 必须按警告呈现（不是红色失败），因为凭据确实已经改变。
  String? _credentialWarning;

  /// 删除了默认连接、草稿里暂时没有默认连接：提示用户显式选一个，
  /// 页面绝不自动挑另一条连接当默认。
  bool _defaultDeleted = false;

  /// 防止自己写入草稿时触发的通知再来一次 setState。
  bool _inEdit = false;

  /// 最后一次同步进表单的草稿 profile（新连接为 `null`）。
  ///
  /// 用来区分“本页刚写进草稿的修改”和“外部对草稿的替换”（保存后 revision 变化、
  /// 放弃后回滚、load 重新载入）：只有后者才重载表单，否则会把用户正在输入的内容、
  /// 正在输入的密钥、探测结果一起清掉。
  ProviderProfile? _synced;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    final pick = _pickInitial();
    if (pick != null) {
      _loadProfile(pick);
    } else {
      _startNew();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _name.dispose();
    _baseUrl.dispose();
    _chatUrl.dispose();
    _modelsUrl.dispose();
    _modelId.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ controller

  void _onControllerChanged() {
    if (!mounted || _inEdit) return;
    final profiles = widget.controller.draft.profiles;
    final live = _draftProfile(_formId);
    setState(() {
      if (widget.controller.draft.defaultSelection != null) {
        // 用户已经显式选了新的默认连接，旧的“默认已删除”提示不再成立。
        _defaultDeleted = false;
      }
      if (live == null) {
        // 外部变化（load / discard）可能把正在编辑的连接删掉了。
        if (profiles.isEmpty) {
          _startNew();
        } else {
          _loadProfile(profiles.first);
        }
        return;
      }
      final synced = _synced;
      if (synced != null && live != synced) {
        // 保存后 revision / 凭据状态变了、放弃后回滚、或 load 换了一份配置：
        // 表单里的文本、选择与 _revision 都已过期，必须重新同步。
        _loadProfile(live);
      }
    });
  }

  ProviderProfile? _pickInitial() {
    final draft = widget.controller.draft;
    final defaultId = draft.defaultSelection?.profileId ?? '';
    for (final p in draft.profiles) {
      if (p.id == defaultId) return p;
    }
    return draft.profiles.isEmpty ? null : draft.profiles.first;
  }

  ProviderProfile? _draftProfile(String id) {
    for (final p in widget.controller.draft.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ------------------------------------------------------------ form state

  void _loadProfile(ProviderProfile p) {
    _formId = p.id;
    _revision = p.revision;
    _name.text = p.name;
    _baseUrl.text = p.baseUrl;
    _chatUrl.text = p.chatUrl;
    _modelsUrl.text = p.modelsUrl;
    _modelId.text = p.modelId;
    _protocol = p.protocol;
    _authMode = p.authMode;
    _thinking = p.effectiveThinking == ThinkingMode.enabled
        ? ThinkingMode.enabled
        : ThinkingMode.disabled;
    _effort = _thinking == ThinkingMode.enabled
        ? (ReasoningEffort.normalize(p.reasoningEffort) ??
            ReasoningEffort.defaultValue)
        : null;
    _jsonMode = p.jsonMode;
    _credentialConfigured = p.credentialConfigured;
    _credentialHost = p.credentialHost;
    _synced = p;
    _resetTransient();
  }

  void _startNew() {
    _formId = _uniqueId('connection');
    _revision = 0;
    _name.text = '';
    _baseUrl.text = '';
    _chatUrl.text = '';
    _modelsUrl.text = '';
    _modelId.text = '';
    _protocol = ProviderProtocol.deepseekChat;
    _authMode = AuthMode.bearer;
    _thinking = ThinkingMode.disabled;
    _effort = null;
    _jsonMode = true;
    _credentialConfigured = false;
    _credentialHost = null;
    _synced = null;
    _resetTransient();
  }

  void _resetTransient() {
    _apiKey.clear();
    _keyEditing = false;
    _credentialError = null;
    _credentialWarning = null;
    _keyStatus = null;
    _probeModels = const <String>[];
    _probeSummary = null;
    _probeError = null;
    _actionStatus = null;
    _actionError = null;
    _touched.clear();
  }

  String _uniqueId(String base) {
    final used = <String>{};
    for (final p in widget.controller.draft.profiles) {
      used.add(p.id);
    }
    for (final p in widget.controller.profiles) {
      used.add(p.id);
    }
    if (!used.contains(base)) return base;
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    var candidate = '$base-$stamp';
    var n = 2;
    while (used.contains(candidate) || candidate.length > 64) {
      candidate = '$base-$stamp-$n';
      n++;
    }
    return candidate;
  }

  /// 用当前表单 + 草稿里真实的凭据状态构造 profile。
  ///
  /// 凭据字段必须取草稿里的值：页面上的布尔量只是快照，用旧快照覆盖会把
  /// “已配置”悄悄改回“未配置”。
  ProviderProfile _buildProfile() {
    final live = _draftProfile(_formId);
    final thinking =
        _protocol.supportsThinking ? _thinking : ThinkingMode.unsupported;
    return ProviderProfile(
      id: _formId,
      name: _name.text.trim(),
      revision: live?.revision ?? _revision,
      protocol: _protocol,
      baseUrl: _baseUrl.text.trim(),
      chatUrl: _chatUrl.text.trim(),
      modelsUrl: _modelsUrl.text.trim(),
      authMode: _authMode,
      modelId: _modelId.text.trim(),
      thinking: thinking,
      reasoningEffort: thinking == ThinkingMode.enabled
          ? (_effort ?? ReasoningEffort.defaultValue)
          : null,
      jsonMode: _protocol.supportsThinking ? true : _jsonMode,
      // 环境变量名没有页面入口（0.0.4 只用 Windows 凭据管理器），必须沿用草稿里的值：
      // 否则一次编辑就会把它清空，还会让“凭据/探测目标未变”的判断永远为假。
      apiKeyEnv: live?.apiKeyEnv ?? '',
      credentialConfigured: live?.credentialConfigured ?? _credentialConfigured,
      credentialHost: live?.credentialHost ?? _credentialHost,
    );
  }

  /// 把表单写进草稿（不落盘）。返回首个校验问题。
  String? _pushDraft() {
    _inEdit = true;
    try {
      final error = widget.controller.updateDraftProfile(_buildProfile());
      // 记录“表单已与草稿一致”的快照：之后只有外部替换草稿才会被识别为变化。
      _synced = _draftProfile(_formId);
      return error;
    } finally {
      _inEdit = false;
    }
  }

  Map<String, String> _fieldErrors() {
    final out = <String, String>{};
    for (final message in _buildProfile().validate()) {
      out.putIfAbsent(_fieldForError(message), () => message);
    }
    return out;
  }

  static String _fieldForError(String message) {
    if (message.contains('连接 ID')) return _kIdField;
    if (message.contains('基础地址')) return _kBaseUrlField;
    if (message.contains('Chat Completions')) return _kChatUrlField;
    if (message.contains('模型列表')) return _kModelsUrlField;
    if (message.contains('认证方式')) return _kAuthField;
    if (message.contains('环境变量')) return _kEnvField;
    if (message.contains('思考强度')) return _kEffortField;
    if (message.contains('名称')) return _kNameField;
    if (message.contains('模型')) return _kModelIdField;
    return _kOtherField;
  }

  String? _errorFor(String field) =>
      _touched.contains(field) ? _fieldErrors()[field] : null;

  /// 通用编辑入口：先执行 [change]，再把表单写进草稿。
  void _edit({VoidCallback? change, String? touch}) {
    setState(() {
      if (change != null) change();
      if (touch != null) _touched.add(touch);
      _pushDraft();
    });
  }

  // --------------------------------------------------------------- actions

  void _newConnection() {
    setState(() {
      _startNew();
      _pushDraft();
    });
  }

  void _selectProfile(ProviderProfile p) {
    if (p.id == _formId) return;
    // 每次输入都已写入草稿，所以切换连接不会丢内容；这里只需换一份表单。
    setState(() => _loadProfile(p));
  }

  void _setPreset(ProviderProtocol protocol) {
    _edit(
      change: () {
        _protocol = protocol;
        if (protocol.supportsThinking) {
          if (_baseUrl.text.trim().isEmpty) {
            _baseUrl.text = 'https://api.deepseek.com';
          }
          if (_chatUrl.text.trim().isEmpty) {
            _chatUrl.text = 'https://api.deepseek.com/chat/completions';
          }
          if (_modelsUrl.text.trim().isEmpty) {
            _modelsUrl.text = 'https://api.deepseek.com/models';
          }
          if (_modelId.text.trim().isEmpty) _modelId.text = 'deepseek-chat';
          _thinking = ThinkingMode.enabled;
          _effort ??= ReasoningEffort.defaultValue;
          _jsonMode = true;
        } else {
          _thinking = ThinkingMode.unsupported;
          _effort = null;
        }
      },
    );
  }

  Future<void> _deleteConnection(ProviderProfile p) async {
    final label = p.name.trim().isEmpty ? p.id : p.name.trim();
    final confirmed = await _confirm(
      title: '删除连接「$label」？',
      message: '删除只会写进草稿：点设置窗口的「保存」之后才会从 settings.json 移除。'
          '已保存的 API Key 不会随连接自动删除，如有需要请先点「删除密钥」。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final wasDefault =
        widget.controller.draft.defaultSelection?.profileId == p.id;
    // 只改草稿：真正删除磁盘记录由设置窗口的「保存」（deletedProfileIds）完成。
    widget.controller.removeDraftProfile(p.id);
    if (!mounted) return;
    final rest = widget.controller.draft.profiles;
    setState(() {
      if (_formId == p.id) {
        if (rest.isEmpty) {
          _startNew();
        } else {
          _loadProfile(rest.first);
        }
      }
      // 删掉的正是默认连接：显式提示，绝不自动挑另一条连接当默认。
      // 用户点「把当前连接设为默认」或草稿里重新出现默认选择后提示自动消失。
      if (rest.isEmpty) {
        _defaultDeleted = false;
      } else if (wasDefault) {
        _defaultDeleted = true;
      }
    });
  }

  /// 用 [profile] 当前的模型/思考设置把它设为默认连接（草稿）。
  Future<void> _setDefault(ProviderProfile profile) async {
    if (profile.revision < 1) {
      setState(() {
        _actionStatus = null;
        _actionError = '该连接还没有保存过（修订 0）：请先在设置窗口点「保存」，'
            '保存后修订变为 1，才能作为默认连接。';
      });
      return;
    }
    final selection = ModelSelection(
      profileId: profile.id,
      profileRevision: profile.revision,
      modelId: profile.modelId.trim(),
      thinking: profile.effectiveThinking,
      reasoningEffort: profile.effectiveReasoningEffort,
    );
    final error = widget.controller.setDraftDefaultSelection(selection);
    if (!mounted) return;
    setState(() {
      _actionError = error;
      if (error == null) _defaultDeleted = false;
      _actionStatus = error == null
          ? '已设为默认连接（草稿）：新会话将使用 ${profile.modelId.trim()}。'
              '点设置窗口的「保存」后生效。'
          : null;
    });
  }

  // ------------------------------------------------------------ credentials

  /// 为什么此刻不能写 / 换 / 删这条连接的 API Key。
  ///
  /// 原生层把密钥绑定到**已保存** profile 的 chatUrl 主机，所以控制层会拒绝
  /// 尚未保存的新连接、以及地址 / 协议 / 认证方式 / 密钥环境变量有未保存修改的连接。
  /// 页面在点击之前就禁用按钮并给出同样的可读原因，避免“点了没反应”或把密钥
  /// 绑到界面上没显示的旧主机。
  String? _credentialBlockReason() {
    if (!widget.controller.bridgeAvailable) {
      // 原生不可用时页面已有单独的说明，不重复。
      return null;
    }
    final committed = widget.controller.profileById(_formId);
    if (committed == null) {
      return '这条连接还没有保存：请先在设置窗口点「保存」，再保存 API Key'
          '（密钥绑定已保存连接的主机）。';
    }
    if (!_sameCredentialTarget(committed, _buildProfile())) {
      return '连接有未保存的修改（协议 / 地址 / 认证方式 / 密钥环境变量）：'
          '请先保存连接，再保存 API Key。';
    }
    return null;
  }

  static bool _sameCredentialTarget(ProviderProfile a, ProviderProfile b) =>
      a.protocol == b.protocol &&
      a.chatUrl.trim() == b.chatUrl.trim() &&
      a.baseUrl.trim() == b.baseUrl.trim() &&
      a.authMode == b.authMode &&
      a.apiKeyEnv.trim() == b.apiKeyEnv.trim();

  /// 控制层对“密钥已生效、但 settings.json 写入失败”的返回文案。
  ///
  /// 这不是失败：密钥确实已经改变，所以按警告呈现（不再是红色错误），
  /// 并提示重新保存设置以恢复一致。
  static bool _isCredentialPartialWarning(String message) =>
      message.contains('设置文件写入失败');

  Future<void> _saveKey() async {
    final key = _apiKey.text;
    if (key.trim().isEmpty) {
      setState(() => _credentialError = '请输入 API Key');
      return;
    }
    final block = _credentialBlockReason();
    if (block != null) {
      setState(() {
        // 密钥文本不留在页面里：被阻止时也立刻清掉。
        _apiKey.clear();
        _credentialError = block;
      });
      return;
    }
    setState(() {
      _credentialBusy = true;
      _credentialError = null;
      _credentialWarning = null;
      _keyStatus = null;
    });
    // 连接必须先在草稿里存在，原生层才知道这条 key 属于哪个 profile。
    _pushDraft();
    final error = await widget.controller.setCredential(_formId, key);
    if (!mounted) return;
    setState(() {
      _credentialBusy = false;
      // 无论成败都立刻清掉 Dart 侧文本：页面永远不回显密钥。
      _apiKey.clear();
      if (error == null) {
        _keyEditing = false;
        _keyStatus = 'API Key 已写入 Windows 凭据管理器（界面不会显示内容）。';
      } else if (_isCredentialPartialWarning(error)) {
        _keyEditing = false;
        _credentialWarning = error;
      } else {
        _credentialError = error;
      }
      _refreshCredential();
    });
  }

  Future<void> _deleteKey() async {
    final confirmed = await _confirm(
      title: '删除已保存的 API Key？',
      message: '删除后该连接在「Bearer」认证下将无法发送请求，直到重新填写。'
          '此操作立即生效（密钥保存在 Windows 凭据管理器）。',
      confirmLabel: '删除密钥',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _credentialBusy = true;
      _credentialError = null;
      _credentialWarning = null;
      _keyStatus = null;
    });
    final error = await widget.controller.deleteCredential(_formId);
    if (!mounted) return;
    setState(() {
      _credentialBusy = false;
      _apiKey.clear();
      if (error == null) {
        _keyStatus = '已删除该连接的 API Key。';
      } else if (_isCredentialPartialWarning(error)) {
        _credentialWarning = error;
      } else {
        _credentialError = error;
      }
      _refreshCredential();
    });
  }

  void _refreshCredential() {
    final live = _draftProfile(_formId);
    _credentialConfigured =
        live?.credentialConfigured ?? _credentialConfigured;
    _credentialHost = live?.credentialHost ?? _credentialHost;
  }

  // ----------------------------------------------------------------- probes

  /// 为什么此刻不能发起探测。
  ///
  /// 探测由原生层用**已保存**的 profile 修订发请求，所以新连接、以及地址 / 认证
  /// 方式有未保存修改的连接都会被控制层拒绝。页面提前禁用按钮并显示同一份原因，
  /// 避免用户以为“测的是刚改的新地址”。
  String? _probeBlockReason({required bool models}) {
    final controller = widget.controller;
    if (!controller.bridgeAvailable) {
      return '原生设置不可用，无法发起探测（请重新启动程序）。';
    }
    final saved = controller.profileById(_formId);
    if (saved == null) {
      return '这条连接还没有保存到磁盘：请先在设置窗口点「保存」，再测试。'
          '测试只针对已保存的配置。';
    }
    if (!_sameProbeTarget(saved, _buildProfile())) {
      return '连接地址或认证方式有未保存的修改：请先保存连接，再测试实际请求目标'
          '（测试只针对已保存的配置）。';
    }
    if (models && saved.modelsUrl.trim().isEmpty) {
      return '这条连接没有填写「模型列表地址」，无法获取模型列表；可以手动填写模型 ID。';
    }
    return null;
  }

  /// 探测实际会发到哪个目标：协议 / Chat 地址 / 模型列表地址 / 认证方式 / 密钥环境变量。
  /// 只改模型 ID 或思考强度是允许的（探测请求本身会带上这些）。
  static bool _sameProbeTarget(ProviderProfile a, ProviderProfile b) =>
      a.protocol == b.protocol &&
      a.chatUrl.trim() == b.chatUrl.trim() &&
      a.modelsUrl.trim() == b.modelsUrl.trim() &&
      a.authMode == b.authMode &&
      a.apiKeyEnv.trim() == b.apiKeyEnv.trim();

  /// 该禁用原因是否属于“地址/认证方式有未保存修改”这一种。
  ///
  /// 这种原因已经由“当前表单有未保存的修改…”那条橙色提示说明过一次，按钮下方不再重复。
  bool _isUnsavedTargetBlock(String reason) =>
      reason.startsWith('连接地址或认证方式有未保存的修改');

  Future<void> _runProbe({required bool models}) async {
    final block = _probeBlockReason(models: models);
    if (block != null) {
      setState(() {
        _probeError = block;
        _probeSummary = null;
      });
      return;
    }
    final saved = widget.controller.profileById(_formId)!;
    setState(() {
      _probeError = null;
      _probeSummary = null;
      if (models) _probeModels = const <String>[];
    });
    final model = _modelId.text.trim();
    final outcome = models
        ? await widget.controller
            .discoverModels(saved.id, saved.revision, modelId: model)
        : await widget.controller
            .testModel(saved.id, saved.revision, modelId: model);
    if (!mounted) return;
    setState(() {
      if (outcome.ok) {
        _probeSummary = SettingsErrorCatalog.describeProbe(outcome);
        if (models) {
          _probeModels = outcome.models.take(60).toList(growable: false);
        }
        _probeError = null;
      } else if (outcome.isCancelled) {
        _probeSummary = '已取消本次探测。';
        _probeError = null;
      } else {
        _probeError = SettingsErrorCatalog.describeProbe(outcome);
        _probeSummary = null;
      }
    });
  }

  /// 表单与该连接已保存的配置不同（忽略凭据标志）。
  bool _dirtyForProbe() {
    final saved = widget.controller.profileById(_formId);
    if (saved == null) return false;
    final form = _buildProfile();
    return saved.name != form.name ||
        saved.protocol != form.protocol ||
        saved.baseUrl != form.baseUrl ||
        saved.chatUrl != form.chatUrl ||
        saved.modelsUrl != form.modelsUrl ||
        saved.authMode != form.authMode ||
        saved.modelId != form.modelId ||
        saved.effectiveThinking != form.effectiveThinking ||
        saved.effectiveReasoningEffort != form.effectiveReasoningEffort ||
        saved.jsonMode != form.jsonMode;
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.maxWidth.isFinite && constraints.maxWidth < 620;
        if (narrow) {
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _connectionPanel(listMaxHeight: 170),
                const SizedBox(height: 10),
                _formPanel(),
              ],
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 238, child: _connectionPanel()),
              const SizedBox(width: 12),
              Expanded(child: _formPanel()),
            ],
          ),
        );
      },
    );
  }

  Widget _connectionPanel({double listMaxHeight = 430}) {
    final controller = widget.controller;
    final profiles = controller.draft.profiles;
    final defaultId = controller.draft.defaultSelection?.profileId ?? '';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '模型连接',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
              ),
              // A real action button: solid, and the same height as every other solid
              // button in the settings window (it used to be a small filled chip).
              SizedBox(
                height: TsSizes.compactButtonHeight,
                child: FilledButton.icon(
                  key: const Key('settings-model-new'),
                  onPressed: _newConnection,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('新增', style: TextStyle(fontSize: 11.5)),
                  style: TsButtons.solid(
                    minimumSize:
                        const Size(0, TsSizes.compactButtonHeight),
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (profiles.isEmpty)
            _emptyList()
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: listMaxHeight),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final p in profiles)
                    _connectionTile(
                      p,
                      selected: p.id == _formId,
                      isDefault: p.id == defaultId,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyList() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.memory_outlined, size: 22, color: TsColors.textFaint),
          const SizedBox(height: 8),
          Text(
            '还没有模型连接',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: TsColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点右上角「新增」添加一条连接。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: TsColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionTile(
    ProviderProfile p, {
    required bool selected,
    required bool isDefault,
  }) {
    final host = p.endpointHost;
    final credential = widget.controller.credentialConfigured(p.id);
    final label = p.name.trim().isEmpty ? '未命名连接' : p.name.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        key: Key('settings-model-tile-${p.id}'),
        color: selected ? TsColors.accentSoft : TsColors.surfaceAlt,
        shape: const BezierRoundedRectangleBorder(radius: 10),
        child: InkWell(
          customBorder: const BezierRoundedRectangleBorder(radius: 10),
          onTap: () => _selectProfile(p),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: selected
                                    ? TsColors.accent
                                    : TsColors.textPrimary,
                              ),
                            ),
                          ),
                          if (isDefault) ...[
                            const SizedBox(width: 5),
                            _badge('默认', TsColors.ready, TsColors.readySoft),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${p.protocol.label} · ${host.isEmpty ? '未填写地址' : host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: TsColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '修订 ${p.revision} · '
                        '${credential ? '凭据已配置' : '凭据未配置'}',
                        style: TextStyle(
                          fontSize: 10,
                          color:
                              credential ? TsColors.textFaint : TsColors.pending,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Transparent icon affordances with a real 28x28 hit box: the "set as
                    // default" check and the delete bin are icons, not blue bricks.
                    IconButton(
                      key: Key('settings-model-default-${p.id}'),
                      tooltip: '设为默认连接',
                      onPressed: () => _setDefault(p),
                      style: TsButtons.icon(
                        size: 28,
                        foreground:
                            isDefault ? TsColors.ready : TsColors.textFaint,
                      ),
                      icon: Icon(
                        isDefault
                            ? Icons.check_circle
                            : Icons.check_circle_outline,
                        size: 16,
                      ),
                    ),
                    IconButton(
                      key: Key('settings-model-delete-${p.id}'),
                      tooltip: '删除连接',
                      onPressed: () => _deleteConnection(p),
                      style: TsButtons.icon(
                        size: 28,
                        foreground: TsColors.blocked,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _formPanel() {
    final errors = _fieldErrors();
    final draftError = widget.controller.validateDraft();
    // 有已删除的草稿条目时也要立刻说明：删掉默认连接后保存会被控制层拒绝，
    // 不能因为“没碰任何输入框”就把原因藏起来。
    final showDraftError = draftError != null &&
        (_touched.isNotEmpty || widget.controller.draft.deletions.isNotEmpty);
    final advancedOpen = _advancedOpen ||
        (errors.containsKey(_kChatUrlField) &&
            _touched.contains(_kChatUrlField));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _formHeader(),
              if (showDraftError) _warn('草稿校验未通过：$draftError'),
              const SizedBox(height: 10),
              Text(
                '预设 / 协议',
                style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
              ),
              const SizedBox(height: 5),
              BezierSegments(
                key: const Key('settings-model-protocol'),
                // Fills the host width and splits it evenly; the block and the label
                // of an item always share exactly one slot.
                expand: true,
                height: 28,
                items: const [
                  BezierSegmentItem('DeepSeek 官方'),
                  BezierSegmentItem('OpenAI 兼容'),
                ],
                selected: _protocol == ProviderProtocol.deepseekChat ? 0 : 1,
                onChanged: (index) => _setPreset(
                  index == 0
                      ? ProviderProtocol.deepseekChat
                      : ProviderProtocol.openAiChat,
                ),
              ),
              const SizedBox(height: 12),
              _textField(
                key: const Key('settings-model-name'),
                controller: _name,
                label: '名称',
                hint: '例如 DeepSeek 官方 / 公司网关',
                error: _errorFor(_kNameField),
                onChanged: (_) => _edit(touch: _kNameField),
              ),
              const SizedBox(height: 10),
              _textField(
                key: const Key('settings-model-base-url'),
                controller: _baseUrl,
                label: '基础地址',
                hint: '例如 https://api.deepseek.com',
                error: _errorFor(_kBaseUrlField),
                onChanged: (_) => _edit(touch: _kBaseUrlField),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '高级：完整端点',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
              // An inline expander, not a blue brick: it belongs to the sentence above
              // it, and the surrounding card is a form, not an action bar.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('settings-model-advanced'),
                  onPressed: () =>
                      setState(() => _advancedOpen = !_advancedOpen),
                  style: TsButtons.link(fontSize: 11.5),
                  child: Text(
                    advancedOpen ? '收起完整端点' : '展开完整端点（必需）',
                  ),
                ),
              ),
              if (advancedOpen) ...[
                const SizedBox(height: 4),
                _textField(
                  key: const Key('settings-model-chat-url'),
                  controller: _chatUrl,
                  label: 'Chat Completions 完整地址',
                  hint: 'https://api.deepseek.com/chat/completions',
                  error: _errorFor(_kChatUrlField),
                  onChanged: (_) => _edit(touch: _kChatUrlField),
                ),
                const SizedBox(height: 10),
                _textField(
                  key: const Key('settings-model-models-url'),
                  controller: _modelsUrl,
                  label: '模型列表完整地址',
                  hint: 'https://api.deepseek.com/models',
                  error: _errorFor(_kModelsUrlField),
                  onChanged: (_) => _edit(touch: _kModelsUrlField),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        _authCard(),
        const SizedBox(height: 10),
        _modelCard(),
        const SizedBox(height: 10),
        _capabilityCard(errors),
        const SizedBox(height: 10),
        _defaultCard(),
      ],
    );
  }

  Widget _formHeader() {
    final name = _name.text.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? '新连接' : name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'ID：$_formId（创建后不可修改） · 修订 $_revision',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
              ),
            ],
          ),
        ),
        if (_revision > 0)
          _badge('已保存', TsColors.ready, TsColors.readySoft)
        else
          _badge('未保存', TsColors.pending, TsColors.pendingSoft),
      ],
    );
  }

  Widget _authCard() {
    final bridge = widget.controller.bridgeAvailable;
    // 密钥只能绑定“已保存且目标未变”的连接：控制层会拒绝，页面提前禁用并说明。
    final credentialBlock = _credentialBlockReason();
    final credentialReady = bridge && !_credentialBusy && credentialBlock == null;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '认证方式',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TsColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          BezierSegments(
            key: const Key('settings-model-auth'),
            expand: true,
            height: 28,
            items: const [
              BezierSegmentItem('Bearer'),
              BezierSegmentItem('无需认证'),
            ],
            selected: _authMode == AuthMode.bearer ? 0 : 1,
            onChanged: (index) => _edit(
              change: () => _authMode =
                  index == 0 ? AuthMode.bearer : AuthMode.none,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'API Key',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
              ),
              _badge(
                _credentialConfigured ? '已配置' : '未配置',
                _credentialConfigured ? TsColors.ready : TsColors.textFaint,
                _credentialConfigured ? TsColors.readySoft : TsColors.doneSoft,
              ),
            ],
          ),
          if (_credentialHost != null && _credentialHost!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '凭据绑定的主机：$_credentialHost',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
              ),
            ),
          const SizedBox(height: 8),
          if (_credentialConfigured && !_keyEditing) ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  key: const Key('settings-model-replace-key'),
                  onPressed: credentialReady
                      ? () => setState(() {
                            _keyEditing = true;
                            _credentialError = null;
                            _credentialWarning = null;
                            _keyStatus = null;
                          })
                      : null,
                  style: _compactButtonStyle(),
                  child: const Text('替换密钥', style: TextStyle(fontSize: 11.5)),
                ),
                OutlinedButton(
                  key: const Key('settings-model-delete-key'),
                  onPressed: credentialReady ? _deleteKey : null,
                  style: _compactButtonStyle(danger: true),
                  child: const Text('删除密钥', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ] else ...[
            _textField(
              key: const Key('settings-model-api-key'),
              controller: _apiKey,
              label: 'API Key（只写）',
              hint: '粘贴密钥后点「保存密钥」',
              obscure: true,
              enabled: credentialReady,
              onChanged: (_) {
                if (_credentialError != null || _credentialWarning != null) {
                  setState(() {
                    _credentialError = null;
                    _credentialWarning = null;
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton(
                  key: const Key('settings-model-save-key'),
                  onPressed: credentialReady ? _saveKey : null,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 32),
                    textStyle: const TextStyle(fontSize: 11.5),
                  ),
                  child: Text(_credentialBusy ? '正在保存…' : '保存密钥'),
                ),
                if (_keyEditing)
                  TextButton(
                    key: const Key('settings-model-cancel-key'),
                    onPressed: () => setState(() {
                      _keyEditing = false;
                      _apiKey.clear();
                      _credentialError = null;
                      _credentialWarning = null;
                    }),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 11.5)),
                  ),
              ],
            ),
          ],
          if (!bridge)
            _warn('原生设置不可用：无法读写 Windows 凭据管理器（请重新启动程序）。'),
          if (credentialBlock != null)
            _warn(
              credentialBlock,
              key: const Key('settings-model-credential-block'),
            ),
          if (_credentialWarning != null)
            _warn(
              _credentialWarning!,
              key: const Key('settings-model-credential-warning'),
            ),
          if (_credentialError != null)
            _errorBox(
              _credentialError!,
              key: const Key('settings-model-credential-error'),
            ),
          if (_keyStatus != null) _successBox(_keyStatus!),
        ],
      ),
    );
  }

  Widget _modelCard() {
    final controller = widget.controller;
    final modelsBlock = _probeBlockReason(models: true);
    final chatBlock = _probeBlockReason(models: false);
    final busy = controller.probing;
    // “地址/认证方式有未保存修改”不在这里逐条重复：下面的橙色提示已经说明了同一件事，
    // 这里只保留另两种无法探测的原因（未保存的连接、没有模型列表地址）。
    final reasons = <String>[
      if (!busy && modelsBlock != null && !_isUnsavedTargetBlock(modelsBlock))
        modelsBlock,
      if (!busy &&
          chatBlock != null &&
          chatBlock != modelsBlock &&
          !_isUnsavedTargetBlock(chatBlock))
        chatBlock,
    ];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '模型',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TsColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          _textField(
            key: const Key('settings-model-model-id'),
            controller: _modelId,
            label: '模型 ID',
            hint: '例如 deepseek-chat；以服务商文档为准',
            error: _errorFor(_kModelIdField),
            onChanged: (_) => _edit(touch: _kModelIdField),
          ),
          if (_probeModels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '发现的模型（点选填入）：',
              style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final m in _probeModels)
                  ChoiceChip(
                    label: Text(m, style: const TextStyle(fontSize: 11)),
                    selected: _modelId.text.trim() == m,
                    onSelected: (_) {
                      _modelId.text = m;
                      _edit(touch: _kModelIdField);
                    },
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('settings-model-discover'),
                onPressed: busy || modelsBlock != null
                    ? null
                    : () => _runProbe(models: true),
                icon: const Icon(Icons.list_alt, size: 15),
                label: const Text('获取模型列表', style: TextStyle(fontSize: 11.5)),
                style: _compactButtonStyle(),
              ),
              OutlinedButton.icon(
                key: const Key('settings-model-test'),
                onPressed: busy || chatBlock != null
                    ? null
                    : () => _runProbe(models: false),
                icon: const Icon(Icons.bolt_outlined, size: 15),
                label: const Text('测试模型响应', style: TextStyle(fontSize: 11.5)),
                style: _compactButtonStyle(),
              ),
              if (busy)
                TextButton(
                  key: const Key('settings-model-cancel-probe'),
                  onPressed: controller.cancelProbe,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 11.5)),
                ),
              if (busy)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: TsColors.accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '正在请求服务商…',
                      style: TextStyle(
                        fontSize: 11,
                        color: TsColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          for (final reason in reasons) _note(reason),
          if (_dirtyForProbe())
            _warn('当前表单有未保存的修改：探测使用已保存的配置'
                '（修订 ${controller.profileById(_formId)?.revision ?? 0}）。'
                '想测试新地址或新密钥，请先在设置窗口点「保存」。'),
          if (_probeError != null) _errorBox(_probeError!),
          if (_probeSummary != null) _successBox(_probeSummary!),
        ],
      ),
    );
  }

  /// 开关行不画鼠标悬停底色。
  ///
  /// 默认 ListTile 的 hover 覆盖层是整行宽的浅灰矩形，夹在卡片里像另一张面板；
  /// 开关本身（拇指与轨道）已经有足够反馈，不需要整块底色。
  static const Color _kNoTileHover = Colors.transparent;

  Widget _capabilityCard(Map<String, String> errors) {
    if (_protocol.supportsThinking) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '思考与输出',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary,
              ),
            ),
            SwitchListTile(
              key: const Key('settings-model-thinking'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              hoverColor: _kNoTileHover,
              value: _thinking == ThinkingMode.enabled,
              onChanged: (on) => _edit(
                change: () {
                  _thinking =
                      on ? ThinkingMode.enabled : ThinkingMode.disabled;
                  _effort =
                      on ? (_effort ?? ReasoningEffort.defaultValue) : null;
                },
              ),
              title: Text(
                '思考模式',
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
              ),
            ),
            if (_thinking == ThinkingMode.enabled) ...[
              const SizedBox(height: 4),
              // Wider than the intrinsic label width and evenly split in three: the
              // blue block and the hit area of low/high/max must be the same rectangle,
              // and the row must not look like a small control stranded in a wide card.
              SizedBox(
                width: 216,
                child: BezierSegments(
                  key: const Key('settings-model-effort'),
                  expand: true,
                  height: 30,
                  items: const [
                    BezierSegmentItem('low'),
                    BezierSegmentItem('high'),
                    BezierSegmentItem('max'),
                  ],
                  selected:
                      switch (_effort ?? ReasoningEffort.defaultValue) {
                    ReasoningEffort.low => 0,
                    ReasoningEffort.high => 1,
                    _ => 2,
                  },
                  onChanged: (index) => _edit(
                    change: () => _effort = switch (index) {
                      0 => ReasoningEffort.low,
                      1 => ReasoningEffort.high,
                      _ => ReasoningEffort.max,
                    },
                  ),
                ),
              ),
            ],
            if (errors[_kEffortField] != null)
              _errorText(errors[_kEffortField]!),
            SwitchListTile(
              key: const Key('settings-model-json'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              hoverColor: _kNoTileHover,
              value: true,
              onChanged: null,
              title: Text(
                'JSON 模式（固定开启）',
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
              ),
            ),
          ],
        ),
      );
    }
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '思考与输出',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TsColors.textPrimary,
            ),
          ),
          SwitchListTile(
            key: const Key('settings-model-json'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            hoverColor: _kNoTileHover,
            value: _jsonMode,
            onChanged: (on) => _edit(change: () => _jsonMode = on),
            title: Text(
              'JSON 模式（可选）',
              style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _defaultCard() {
    final controller = widget.controller;
    final current = controller.draft.defaultSelection;
    final defaultProfile =
        current == null ? null : _draftProfile(current.profileId);
    final defaultName = current == null
        ? ''
        : (defaultProfile != null && defaultProfile.name.trim().isNotEmpty
            ? defaultProfile.name.trim()
            : current.profileId);
    final defaultText = current == null
        ? '尚未设置默认连接：新会话无法发起分析。'
        : '当前默认：$defaultName · ${current.modelId} · '
            '${_thinkingText(current.thinking, current.reasoningEffort)}';
    final defaultDeleted =
        _defaultDeleted && controller.draft.profiles.isNotEmpty;
    final profile = _buildProfile();
    final canSetDefault = profile.revision >= 1 && profile.isValid;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The action sits on the title line, on the right — the row used to leave the
          // whole right half empty and put the button on its own line below.
          Row(
            children: [
              Expanded(
                child: Text(
                  '默认连接（用于新会话）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: TsSizes.gapBetweenGroups),
              SizedBox(
                height: TsSizes.compactButtonHeight,
                child: FilledButton(
                  key: const Key('settings-model-set-default'),
                  onPressed: canSetDefault ? () => _setDefault(profile) : null,
                  style: TsButtons.solid(
                    minimumSize:
                        const Size(0, TsSizes.compactButtonHeight),
                    fontSize: 11.5,
                  ),
                  child: const Text('把当前连接设为默认'),
                ),
              ),
            ],
          ),
          if (defaultDeleted)
            _warn(
              '默认连接已删除，请在右侧选择新的默认连接后再保存',
              key: const Key('settings-model-default-deleted'),
            ),
          const SizedBox(height: 4),
          // The actual default value keeps its own line: it is the fact this card is
          // about, not a hint under a button.
          Text(
            defaultText,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: TsColors.textSecondary,
            ),
          ),
          if (profile.revision < 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '新连接需要先保存（修订 ≥ 1）才能设为默认',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
              ),
            )
          else if (!profile.isValid)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '连接配置不完整，补齐后才能设为默认',
                style: TextStyle(fontSize: 10.5, color: TsColors.pending),
              ),
            ),
          if (_actionError != null) _errorBox(_actionError!),
          if (_actionStatus != null) _successBox(_actionStatus!),
        ],
      ),
    );
  }

  static String _thinkingText(ThinkingMode thinking, String? effort) =>
      switch (thinking) {
        ThinkingMode.enabled => '思考 ${effort ?? ReasoningEffort.defaultValue}',
        ThinkingMode.disabled => '思考关闭',
        ThinkingMode.unsupported => '不支持思考',
      };

  // ------------------------------------------------------------- primitives

  Widget _card({required Widget child}) => Material(
        color: TsColors.surface,
        shape: BezierRoundedRectangleBorder(
          side: BorderSide(color: TsColors.border),
          radius: 12,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: child,
        ),
      );

  Widget _badge(String text, Color foreground, Color background) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: bezierDecoration(
          color: background,
          radius: 20,
        ),
        child: Text(text, style: TextStyle(fontSize: 9.5, color: foreground)),
      );

  Widget _textField({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? hintBelow,
    String? error,
    bool obscure = false,
    bool enabled = true,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: key,
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          enabled: enabled,
          onChanged: onChanged,
          style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            errorText: error,
            errorMaxLines: 3,
            isDense: true,
            labelStyle:
                TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
            hintStyle: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
            errorStyle: TextStyle(fontSize: 10.5, color: TsColors.blocked),
          ),
        ),
        if (hintBelow != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              hintBelow,
              style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
            ),
          ),
      ],
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.info_outline,
                size: 13,
                color: TsColors.textFaint,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: TsColors.textFaint,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _warn(String text, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.pendingSoft,
          radius: 8,
          border: Border.all(color: TsColors.pending),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.pending),
        ),
      );

  Widget _errorBox(String text, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.blockedSoft,
          radius: 8,
          border: Border.all(color: TsColors.blocked),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.blocked),
        ),
      );

  Widget _successBox(String text, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.readySoft,
          radius: 8,
          border: Border.all(color: TsColors.ready),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.ready),
        ),
      );

  Widget _errorText(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 10.5, color: TsColors.blocked),
        ),
      );

  /// 0.06: the compact action buttons use the shared deep-blue button token; only the
  /// destructive one keeps the red semantic colour.
  ButtonStyle _compactButtonStyle({bool danger = false}) => danger
      ? TsButtons.danger(radius: 8)
      : TsButtons.filled(radius: 8, minimumSize: const Size(0, 32));

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TsColors.surface,
        title: Text(
          title,
          style: TextStyle(fontSize: 14.5, color: TsColors.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: TsColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: const Key('settings-model-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: danger
                ? TsButtons.danger(radius: 8)
                : TsButtons.filled(radius: 8),
            child: Text(confirmLabel, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

