# TaskScheduler 0.0.4 设置功能实现规格（工作文档）

本文件是实现依据，不是最终用户文档。产品边界与验收要求见任务描述与 `settings-reference/`。

## 0. 不可破坏的现有行为

- 模型只分析不执行；依赖硬约束、调度算法、分数/权重不进入产品 UI。
- 120 秒只提醒不取消；正式分析总超时默认 0；连接超时独立；探针可单独短超时。
- 补充要求生成新版本，旧版本与完成状态保留；迟到结果防护、取消终态保持不变。
- TLS 校验永不关闭；不自动换供应商重发材料；日志/备份/返回信息不含密钥。
- 旧 `config.json` 的 `endpoint_url` 是**完整** Chat Completions URL，不得自动拼 `/v1`。
- 左侧“账户安全”名称不变；账户服务本期不实现（无网络调用、无密码保存、无假登录）。
- 供应商/API Key/模型全部在“模型”页。

## 1. 文件与职责

### C（src/）

新增：
- `src/profile.h/.c`：供应商 profile 数据结构、JSON 解析/序列化、校验、与 `TsConfig` 互转。
- `src/credential.h/.c`：Windows Credential Manager 写入/读取/删除（仅 C 内部；无读取导出 API）。
- `src/profile_store.h/.c`：`settings.json` 读写（schemaVersion、原子保存、备份、迁移）。
- `tests/test_settings.c`：profile/凭据/迁移/设置保存的离线测试。
- `tests/test_probe.c`：内置 winsock mock HTTP 服务，验证模型发现/测试/请求参数/凭据主机隔离/快照隔离。

修改：
- `src/config.h/.c`：增加 profile/protocol/thinking 字段；`ts_config_copy`（深拷贝）；`ts_secure_free`。
- `src/prompt.c`：按协议构造 `thinking` / `reasoning_effort` / `response_format`。
- `src/model.h/.c`：导出通用 HTTP 调用供探针使用（URL/方法/超时覆盖/取消），保持 TLS 校验。
- `src/bridge/ts_bridge.h/.c`：ABI 2；job 表；快照；settings/credential/probe 接口。
- `CMakeLists.txt`：新文件、advapi32、测试目标。

### Dart（flutter_app/lib/src/）

新增：
- `model/settings.dart`：`AppPreferences`、`ProviderProtocol`、`ThinkingMode`、`ProviderProfile`、`ModelSelection`、`ModelSource`、默认值、JSON。
- `state/settings_store.dart`：应用偏好原子读写（`<root>/settings/app_prefs.json`，schemaVersion）。
- `state/settings_controller.dart`：全局设置状态（偏好 + 原生 profiles + 草稿 + 保存/探针/凭据）。
- `state/backup_service.dart`：无密钥备份/校验恢复/缓存清理。
- `ui/settings/settings_dialog.dart`（替换旧 `ui/settings_dialog.dart` 内容或保留同名导出）、
  `settings_account_page.dart`、`settings_general_page.dart`、`settings_model_page.dart`、
  `settings_shortcuts_page.dart`、`settings_notifications_page.dart`、`settings_storage_page.dart`、
  `settings_about_page.dart`、`settings_widgets.dart`。
- 测试：`test/settings_store_test.dart`、`test/settings_controller_test.dart`、
  `test/backup_service_test.dart`、`test/widget/settings_pages_test.dart`。

修改：
- `ffi/bridge_ffi.dart`：ABI=2；新函数绑定。
- `ffi/native_gateway.dart`：`settingsGet/settingsSave/credentialSet/credentialDelete/probeAsync/probeResult`。
- `main.dart`：`SettingsController` 启动装载、主题/字号、传给 AppShell。
- `ui/app_shell.dart`：快捷键、通知、默认视图、完成任务过滤、模型选择入口。
- `ui/composer.dart`：发送方式（Ctrl+Enter / Enter）、输入法合成保护、当前模型提示。
- `ui/theme.dart`：亮/暗两套调色板 + `TsColors` 可变全局（见 §5）。
- `model/session.dart`：会话 `modelSelection`、版本 `modelSource`。
- `state/app_controller.dart`：发送时捕获选择并在版本记录来源；会话选择持久化。
- `app_info.dart`、`pubspec.yaml`：版本 0.0.4+4。
- 旧测试适配（`settings_rail_test.dart` 等）。

## 2. C 数据模型

```c
typedef enum TsProtocol { TS_PROTOCOL_LEGACY = 0, TS_PROTOCOL_DEEPSEEK_CHAT = 1,
                          TS_PROTOCOL_OPENAI_CHAT = 2 } TsProtocol;
typedef enum TsThinking { TS_THINKING_UNSUPPORTED = 0, TS_THINKING_DISABLED = 1,
                          TS_THINKING_ENABLED = 2 } TsThinking;

typedef struct TsProfile {
    char *id;            /* 稳定不变，非空，[A-Za-z0-9_-]{1,64} */
    char *name;
    long revision;       /* >=1 */
    TsProtocol protocol;
    char *base_url;      /* 只用于展示/派生，不自动拼路径 */
    char *chat_url;      /* 完整 Chat Completions URL（请求实际使用） */
    char *models_url;    /* 完整列表 URL；可空 */
    char *auth_mode;     /* "bearer" | "none" */
    char *api_key_env;   /* 兼容旧配置：环境变量名，可空 */
    char *model_id;
    TsThinking thinking;
    char *reasoning_effort; /* enabled 时 low/high/max；否则 NULL */
    int json_mode;
    char *credential_host;  /* 凭据保存时的主机；空表示无凭据 */
    int credential_configured;
} TsProfile;

typedef struct TsProfileList {
    TsProfile *items; size_t count;
    char *default_profile_id;
    char *default_model_id;
    TsThinking default_thinking;
    char *default_reasoning_effort;
    int schema_version;   /* 2 */
    int migration_legacy; /* 本次运行从旧 config.json 迁移出 profile */
    char *migration_note;
} TsProfileList;
```

`TsConfig` 新增：`char *profile_id; long profile_revision; int protocol; int thinking;
char *thinking_effort; char *models_url; char *auth_mode; char *credential_host;
char *api_key_env;` 以及 `long probe_timeout_ms`（探针用，不进入正式请求策略）。

- `ts_config_copy(TsConfig *dst, const TsConfig *src)` 深拷贝全部 owned 字段；失败返回非 0 且 dst 已初始化。`ts_config_move` 用指针交换实现。
- 密钥释放统一 `ts_secure_free(char **)`：先 `memset` 再 `ts_free`。

## 3. 设置持久化 `/settings.json`

位置：`<data_dir>/settings.json`，由 `ts_bridge_create_ex(config_path, data_dir, ...)` 传入 data_dir。
`ts_bridge_create` 保留，等价于 data_dir = 配置文件目录（无配置时 = 当前目录）。

```json
{
  "schemaVersion": 2,
  "defaultProfileId": "deepseek-official",
  "defaultModelId": "deepseek-chat",
  "defaultThinking": "enabled",
  "defaultReasoningEffort": "high",
  "profiles": [{
    "id": "deepseek-official", "name": "DeepSeek 官方", "revision": 3,
    "protocol": "deepseek-chat", "baseUrl": "https://api.deepseek.com",
    "chatUrl": "https://api.deepseek.com/chat/completions",
    "modelsUrl": "https://api.deepseek.com/models",
    "authMode": "bearer", "apiKeyEnv": "",
    "modelId": "deepseek-chat", "thinking": "enabled",
    "reasoningEffort": "high", "jsonMode": true,
    "credentialConfigured": true, "credentialHost": "api.deepseek.com"
  }]
}
```

规则：
- 原子保存：`settings.json.tmp` → 现有文件改 `.bak` → 提升 tmp；任一步失败不得破坏旧文件，内存态保持旧值。
- 损坏/不兼容：保留原文件不覆盖，加载内置默认空列表并返回 `warning`；不删除用户文件。
- 保存接口用“期望 revision”做乐观并发：已存在 id 的 `revision` 必须等于磁盘上 revision，否则整体拒绝
  `{"ok":false,"errorKind":"conflict","error":"模型配置已被修改，请刷新后重试","current":{...}}`，
  不写盘。新 profile 的 revision 传 0，保存后为 1；字段实际变化时保存后 +1；无变化保持不变。
- `defaultProfileId` 必须指向存在的 profile；`defaultModelId` 非空。
- 保存成功后内存列表整体替换（锁内），运行中的分析任务使用自己的快照，不受影响。
- 删除 profile 后运行中的任务仍能结束；之后引用返回 `errorKind:"profileDeleted"`。
- 未知/缺失 revision 的请求明确失败，绝不静默用最新配置替代。

## 4. 凭据

- 凭据目标按**数据空间**隔离：`TaskScheduler/model/<space>/<profileId>`，`space` 由数据目录
  绝对路径规范化（分隔符统一、大小写不敏感）后 FNV-1a 64 位生成 16 位小写十六进制。
  这样两个便携副本/不同数据目录里的同名 profile 不会共用或互相覆盖密钥。
- `ts_credential_set_scoped(space, profile_id, host, key)` → CredWriteW，
  userName=`host:<host>`，blob=UTF-8 key，persist=CRED_PERSIST_LOCAL_MACHINE。
- `ts_credential_load_scoped(space, profile_id, &key, &host)` 仅 C 内部使用；Dart 无读取接口。
  新目标缺失时回退旧目标 `TaskScheduler/model/<profile_id>`，命中后复制到新目标（不删除旧目标），
  供 0.0.4 之前保存的凭据迁移；`delete` 会同时删除新旧目标。
- 认证目标：保存/请求前以**最终请求 URL**（chatUrl、modelsUrl）校验凭据授权范围；同一连接的
  认证端点必须与 chatUrl **同 origin**（scheme + host + 有效端口）。`modelsUrl` 跨源时：
  `authMode=bearer`/`apiKeyEnv` 非空的 profile 在保存期被拒绝，旧 settings.json 在运行期被拦截；
  `authMode=none` 允许跨源且永不发送 Authorization。https→http 视为不同源，不得无提示降级。
- 主机变化：请求/探针解析凭据时若目标主机与 `credential_host` 不一致，返回配置错误：
  “连接地址已更换（旧 host → 新 host），请重新确认认证方式并重新输入 API Key”，不得发送旧密钥。
- 无凭据但 `auth_mode=bearer` 且没有 `api_key_env` → 请求前配置错误，不发送无鉴权请求。
- 兼容旧配置：内联 `api_key` 在首次创建时导入 CredMan 到 legacy profile，仅此一次，写入
  `migration_note`；旧 config.json 不删除、不修改。环境变量方式保留 `api_key_env`，运行时解析
  （同样受同源限制）。
- 凭据写入/删除会立即生效，**不受设置窗口“取消/放弃”回滚**；若凭据成功但 settings.json 写入
  失败，错误 JSON 带 `partial:true`/`credentialConfigured`/`credentialHost`，UI 必须刷新权威状态
  并提示“请重新保存设置”，不能当作完全失败或完全成功。
- 备份/设置/日志/错误/诊断一律不含密钥；`settings.json` 无 key 字段。

## 5. 请求构造（prompt.c）

- `protocol=deepseek-chat`：顶层 `"thinking":{"type":"enabled"|"disabled"}`；
  仅 enabled 时 `"reasoning_effort":"low"|"high"|"max"`；disabled/unsupported 不带 effort。
- `protocol=openai-chat`：绝不发送 `thinking` / `reasoning_effort`；`response_format` 仅在
  `jsonMode=true` 时发送。能力未知不显示为已验证。
- `protocol=legacy (0)`：保持 0.0.3 行为（旧测试依赖），迁移后的 profile 使用 1/2。
- `max_tokens` 规则不变（0 = 省略）。`temperature`、`stream` 保持。
- 解析响应仍只用 `choices[0].message.content`；`reasoning_content` 不展示、不保存、不返回。

## 6. 桥接 ABI 2

`TS_BRIDGE_ABI_VERSION` 改为 2；Dart `kExpectedAbiVersion=2`。

```c
int ts_bridge_create_ex(const char *config_path_utf8, const char *data_dir_utf8,
                        TsBridge **out_bridge, TsBridgeBuffer *out_error);
int ts_bridge_settings_get(TsBridge *, TsBridgeBuffer *out_json);
int ts_bridge_settings_save(TsBridge *, const char *settings_json, size_t length,
                            TsBridgeBuffer *out_json_or_error);
int ts_bridge_credential_set(TsBridge *, const char *profile_id,
                             const char *key_utf8, size_t key_len,
                             TsBridgeBuffer *out_error);
int ts_bridge_credential_delete(TsBridge *, const char *profile_id,
                                TsBridgeBuffer *out_error);
int ts_bridge_probe_async(TsBridge *, const char *probe_json, size_t length,
                          TsJobId *out_job, TsBridgeBuffer *out_error);
```

- `settings_get` 返回 §3 JSON + `{"abiVersion":2,"settingsPath":"...","profiles":[...]}`。
- `credential_set/delete` 只返回 `{ok:true}` 或 `{ok:false,errorKind,error}`；不返回密钥。
- `probe_json`：`{"kind":"models"|"chat","profileId":"...","profileRevision":N,
  "modelId":"...","thinking":"enabled|disabled|unsupported","reasoningEffort":"high"}`。
  - 用 profile 快照 + 凭据（主机校验）构造请求；`models` 为 GET `modelsUrl`；
    `chat` 为 POST `chatUrl`，固定小型无私密请求：system=“你是连通性测试助手，只输出 JSON。”
    user=`{"task":"connectivity","probe":true}`，要求返回 `{"ok":true}`；不使用任何用户文件。
  - 超时：连接 `min(cfg.connect_timeout_ms, 10000)`，总超时默认 30000ms（可在 probe_json
    用 `timeoutMs` 覆盖，限制 [3000,120000]），可取消。
  - 结果：`{"ok":true,"kind":"models","httpStatus":200,"elapsedMs":123,"models":["..."]}`
    或 `{"ok":true,"kind":"chat","httpStatus":200,"elapsedMs":123,"model":"...",
    "contentIsJson":true,"usage":{...}}`；失败带 `errorKind` 与可读原因（对齐现有分类）。
  - 探针 job 与 analyze job 复用 poll/result/release/cancel，但 result 中 `jobType:"probe"`；
    Dart 不得把探针结果提交为计划。分析同一时刻仍只允许一个；探针可并发，最多 4 个。
- job 表：固定容量（分析 1 + 探针 4）；job 拥有线程句柄、事件、结果、配置快照。
- `analyze_async` 请求新增：
```json
"modelSelection": {"profileId":"...","profileRevision":3,"modelId":"...",
                   "thinking":"enabled","reasoningEffort":"high"}
```
  - 缺省 = 全局默认；revision 不匹配/删除/无 profile → 立即返回错误（不创建 job）。
  - 在锁内校验并**深拷贝 profile + 基础配置 + 凭据到 job 自有 TsConfig**；工作线程只读快照；
    后续保存/删除/切换均不影响。不得修改 `bridge->cfg`，不得销毁 bridge 切换模型。
  - 结果增加 `"source"`：profileId/profileRevision/modelId/protocol/thinking/
    reasoningEffort/endpointHost（无密钥）；失败结果不含 source 时 Dart 记“来源未知”。
- 关闭顺序不变；destroy 释放 job 表与 profile 列表、凭据内存（不删除已存凭据）。

## 7. Dart 接口

```dart
enum ProviderProtocol { deepseekChat, openAiChat }
enum ThinkingMode { unsupported, disabled, enabled }

class ModelSelection { profileId, profileRevision, modelId, thinking, reasoningEffort; validate(); toJson(); }
class ModelSource { profileId, profileRevision, modelId, protocol, thinking, reasoningEffort, endpointHost; fromJson/toJson; }
class ProviderProfile { id,name,revision,protocol,baseUrl,chatUrl,modelsUrl,authMode,apiKeyEnv,modelId,thinking,reasoningEffort,jsonMode,credentialConfigured,credentialHost; }
class AppPreferences { themeMode,fontScale,defaultChartMode,showCompletedTasks,sendMode,notifyOnSuccess,notifyOnFailure; copyWith; toJson/fromJson; }
```

`SettingsController extends ChangeNotifier`（供 UI 与 AppController 共享）：
- `load()`；`prefs`；`profiles`；`defaultSelection`；`settingsPath`；`bridgeAvailable`；
- `draft`：`SettingsDraft`（prefs + profiles + defaultSelection + deletions），`updateDraft...`；
- `bool get dirty`；`save()`（先保存 prefs，再原生 settings_save；失败保留旧值并返回错误）；
- `discard()`；`credentialConfigured(profileId)`；`Future<ProbeOutcome> discoverModels(profileId, revision, modelId)`；
  `Future<ProbeOutcome> testModel(...)`；`Future<String?> setCredential(profileId, key)`；`deleteCredential`。
- AppController 使用 `settingsController.currentSelectionFor(conversation)` 在 `startAnalysis` 捕获，
  写入请求；成功后把 result `source` 写入新 `PlanVersion.modelSource`。

## 8. 设置窗口

- 尺寸自适应：`maxWidth 980 / maxHeight 660`，小窗口（宽 < 900）改为窄边栏（图标 + 文本可换行）。
- 底部按钮：取消 / 保存。保存进行中禁用并显示“正在保存…”。保存失败保持打开并显示原因。
- 切换分类不丢草稿；有未保存修改时关闭（X / Esc / 点击遮罩）弹询问：保存 / 放弃 / 继续编辑。
- 无 dirty 时关闭不弹。账户页无实际配置：只有“关闭”可用，不显示虚假保存成功。
- 字号缩放要适配（文字可换行，固定宽度输入框可扩展）。

### 页面要点

- 账户安全：说明“账户服务尚未接入”，登录/修改密码表单 disabled，登录按钮 disabled；
  不发起网络、不保存密码、不显示伪造身份。说明区块列出未来能力与“本地分析不受影响”。
- 通用：主题（跟随系统/浅色/深色）、字号（0.85–1.30 滑块，标注预览）、默认依赖视图、已完成任务显示、发送方式。
- 模型：左列连接列表（新增/编辑/删除/设为默认）；右侧表单：
  预设（DeepSeek 官方 / 自定义）、名称、基础地址、高级完整 URL（chat/models）、认证方式、
  API Key（已配置状态、替换、删除；只写不读）、模型列表（刷新按钮 + 下拉/手动 ID）、
  思考开关 + 强度（仅 DeepSeek）、JSON 模式（仅自定义兼容）、
  “获取模型列表”“测试模型响应”（说明少量调用用量；结果区分错误类型）。
  保存前校验 URL/模型；默认连接用于新会话。
- 快捷键：列出真实操作：Ctrl+Enter 发送、Ctrl+N 新会话、Ctrl+, 设置、Ctrl+O 添加文件、
  Esc 关闭顶层浮层。注明不做自定义重映射。发送方式影响 Enter 行为。
- 通知：应用内“分析完成/失败”提醒开关；说明 120 秒提醒不属于通知静音；系统通知未接入，不提供开关。
- 存储：实际目录、来源（env/portable/localAppData/appData/temp/memory）、持久化状态、
  目录大小；打开目录；备份（路径对话框，默认“文档”，单 JSON，无密钥）；
  恢复（先校验结构与版本，暂存后提交，失败保留原数据，自动留下 `.bak`）；
  清理缓存（只删明确列举的 `*.tmp` 残留，显示数量/字节；不动历史、附件、用户原文件）。
  TEMP 提示可能被系统清理；内存模式提示关闭即丢失。
- 关于：真实版本（0.0.4）、许可证链接/说明、帮助（打开程序目录 README 或提示不存在）、
  脱敏诊断（复制到剪贴板：版本、ABI、端点 host、profile 数量、存储来源；无 key）。
  无更新服务：显示“更新服务未配置”，不模拟检查成功。

## 9. 主题与字号

- `TsColors` 改为可变全局调色板：`TsTheme.apply(Brightness)` 设置 surface/background/border/
  text 颜色；亮色保持现值，暗色使用 `#15171C / #1D2026 / #2A2E36 / #E6E8EC` 等。
- 状态色亮暗共用。需要去掉使用 `TsColors.*` 的 `const` 构造（编译器会指出）。
- `main.dart`：`MaterialApp(theme: buildAppTheme(Brightness.light), darkTheme: ...,
  themeMode: prefs.themeMode)`，`builder` 套 `MediaQuery` 的 `textScaler: TextScaler.linear(prefs.fontScale)`。
- 发送方式：`ctrlEnter`（默认）与 `enter`；输入法 `composing.isValid` 时不触发发送。

## 10. 快捷键

AppShell 顶层 `Shortcuts/Actions`：Ctrl+N 新会话、Ctrl+, 设置、Ctrl+O 添加文件；
Esc 先关设置/详情/菜单（dialog 自带），不取消分析。`Ctrl+Enter` 在 composer。
设置对话框打开时不被外层快捷键抢走（对话框路由优先）。

## 11. 测试与构建

- C：`scripts/build_flutter_bridge.ps1` 构建，新增测试必须加入脚本运行列表；全部既有测试通过。
- 新 C 测试（无 Python，使用 C winsock mock 服务）：
  1) 请求捕获：模型 ID/URL/thinking/effort 按选择变化；disabled 无 effort；
  2) 运行中保存配置：旧 job 请求体不变，新 job 用新配置；
  3) authMode=none 不发 Authorization；bearer 发且 host 不匹配拒绝；
  4) 未知 revision 明确失败；删除 profile 不影响运行中任务；
  5) 401/404/429/超时/截断/无效 JSON 分类（探针或分析）；
  6) settings 保存/重载 revision、旧 config 迁移、凭据 set/load/delete 往返。
- Dart：`flutter analyze` 0 error；`flutter test` 全部通过（含新测试）：
  prefs 原子与恢复、备份无密钥/恢复失败保留、模型选择 JSON、错误分类 UI 文案、
  账户页无网络（禁用控件）、小窗口/1.5 字号可渲染、设置对话框脏检查。
- 构建：`flutter build windows --release`（沙箱需 danger-full-access，仅构建命令）；
  C Release 构建；报告实际输出。

## 12. 已知不可验证项

- 真实 DeepSeek 联网调用（无可用密钥/不消耗额度）：用本地 mock 验证请求形状与错误分类；
  报告“未对真实服务执行”。
- 系统通知、账户服务：本期未实现，不提供可用开关/假成功。

