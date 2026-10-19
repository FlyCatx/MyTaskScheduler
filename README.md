# TaskScheduler — C 语言 Windows 桌面任务分析器

把文件/文段交给 OpenAI 兼容模型拆解任务与依赖，再由**本地程序**校验并给出**可解释**的
执行顺序：先做什么、为什么先做、做完解锁什么。

**边界**：模型只负责“分析”，程序只负责“规划与展示”。程序不自动执行任务、不运行模型
生成的命令、不操作任何外部应用。依赖边 `A → B` 表示 **B 必须在 A 完成后执行**。

- 设计与算法：见 [DESIGN.md](DESIGN.md)
- 变更记录：见 [CHANGELOG.md](CHANGELOG.md)

---

## 两套界面：旧 Win32 与新的 Flutter 界面

本仓库现在有两套桌面界面，**共用同一份 C 业务核心**（`ts_core`）：

| 界面 | 入口 | 状态 |
| --- | --- | --- |
| 旧 Win32（回归对照） | `build-vs\Release\TaskScheduler.exe` | 保留、可构建、可运行；业务代码未改动 |
| 新 Flutter | `flutter_app\build\windows\x64\runner\Release\taskscheduler.exe` | 新增；通过 `ts_bridge.dll`（FFI）调用同一份 C 内核 |

Flutter 界面的构建、运行、目录结构与协议边界见 [flutter_app/README.md](flutter_app/README.md)；
迁移做了什么、验证了什么、还有哪些没做，见 [MIGRATION.md](MIGRATION.md)。

### Flutter 界面 0.05（产品版本 0.05 / 构建版本 0.0.5）

0.05 在 0.0.4 设置功能上增加会话全生命周期、可自定义快捷键、任务筛选/编辑、版本差异、
存储迁移、PDF/DOCX/PPTX 提取与 Windows 通知。**产品版本 0.05 与 pubspec/构建版本 0.0.5
是同一个版本**：关于页显示 0.05，包名与 `VERSION.txt` 同时写明两者。

| 分类 | 0.05 内容 |
| --- | --- |
| 账户安全 | **仅 UI**。账户服务未接入，登录/修改密码控件全部禁用，不联网、不保存密码；本地分析不受影响。 |
| 通用 | 跟随系统/浅色/深色、字号 0.85–1.30、默认依赖视图、已完成任务显示、发送方式；布局记忆（当前仅会话内）。 |
| 模型 | 供应商连接（DeepSeek Chat Completions / OpenAI 兼容）、完整端点、认证方式、API Key（只写）、模型发现/手动 ID、思考与强度、JSON 模式、设为默认；字段/规则未变。 |
| 快捷键 | 动作注册表 + 自定义/清除/单项与全部恢复默认/冲突检测/录制；保留 Ctrl+Enter、Ctrl+N、Ctrl+,、Ctrl+O、Esc。 |
| 通知 | 应用内完成/失败；Windows 通知中心（托盘气泡）完成/失败通知与点击定位；120 秒提醒保持独立。 |
| 存储 | 目录/大小/打开目录、无密钥备份与恢复、只清应用自有 `cache`；**验证式迁移**到长期目录（复制+校验，重启切换）。 |
| 会话 | 重命名/置顶/归档/最近删除/恢复/永久删除、搜索（含归档与回收）、行菜单绑定目标、墓碑与附件 GC。 |
| 输入/任务/历史 | 输入区手动展开；任务搜索/状态过滤、日期/小时分钟/前置搜索/成环、完成与编辑撤销；版本差异按稳定 ID。 |
| 文件 | TXT/MD/PDF/DOCX/PPTX 本地文本提取（扫描 PDF 明确不支持 OCR；旧 .doc/.ppt 不支持）。 |
| 关于 | 真实版本 0.05、检查更新灰色禁用、诊断信息默认折叠。 |

需求映射：[docs/0_05_REQUIREMENTS_MAP.md](docs/0_05_REQUIREMENTS_MAP.md)。

关键约束（与 0.0.3 的既有行为一致）：

- **API Key 不再写进设置文件**：凭据保存在 Windows 凭据管理器（按 profile 隔离，且与保存时的
  主机绑定）；Flutter/Dart 只有写入/删除入口，**没有读取密钥的接口**，备份、日志、诊断都不含密钥。
- **旧 `config.json` 兼容**：首次启动时按原 `endpoint_url`（完整 URL，不自动拼 `/v1`）生成
  `legacy-config` 连接；旧内联 `api_key` 一次性导入凭据管理器，**旧文件不删不改**；旧会话、
  版本与完成状态照常读取。
- **切换模型不影响进行中的请求**：每次分析在启动瞬间捕获配置快照（profile/revision/model/
  thinking/凭据），运行中保存或删除连接不会改变该请求；下一次请求使用新配置。切换本身不生成
  新计划，补充要求才生成新版本。
- **思考参数**：DeepSeek 连接发送顶层 `thinking.type`；关闭时显式 `disabled` 且不残留
  `reasoning_effort`。OpenAI 兼容连接默认不发送 DeepSeek 专有字段。
- 模型发现只证明列表可用，响应测试使用固定小型无私密 JSON 请求（会消耗少量额度）；两者都
  使用独立短超时并可取消，**不能**当作正式任务提交。
- 正式分析仍是：总超时默认 0、连接超时独立、120 秒只提醒不取消、取消是终态、迟到结果不采纳。
- 账户安全页**不是账户系统**：它没有服务器、没有登录、没有保存任何密码。

设置文件：`<数据目录>\settings.json`（供应商连接，schemaVersion 2，无密钥）与
`<数据目录>\settings\app_prefs.json`（界面偏好，schemaVersion 1）；会话仍在
`<数据目录>\conversations`。数据目录优先级见 `flutter_app/lib/src/state/storage_root.dart`。


```powershell
# 构建 C 内核 + 桥接 DLL + C 测试
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1

# 构建 Flutter Windows 应用（含 analyze / test，并把运行期 DLL 拷到 exe 同目录）
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1

# 打可分发压缩包（会重建、组装、写 MANIFEST、压缩）
#   密钥以 -ApiKey 或环境变量 $env:TS_RELEASE_API_KEY 传入；
#   只会写进包内 config.json 的 "api_key" 字段，不会打印、不会写进日志或 VERSION.txt。
powershell -ExecutionPolicy Bypass -File scripts/make_flutter_release.ps1 -Version 0.0.2 -ApiKey "sk-..."
```

产物：`dist\TaskScheduler-<版本>-win64-x64\` 与同名 `.zip`（含 Flutter 运行库 `data\`、
`ts_bridge.dll`、`libcurl-x64.dll`、`cacert.pem`、`config.json`、`MANIFEST.sha256`）。

> 内联密钥的包**只应在自己可信的机器之间传递**；需要分享时删掉 `config.json` 的 `api_key`
> 行并改用 `api_key_env` 环境变量方式（包内 `README.txt` 有说明）。

下面各节仍描述**旧 Win32 界面**的构建与使用方式，同样适用于新界面的 C 核心部分。

---

## 快速开始

```powershell
# 1. 取真实依赖（cJSON v1.7.18 + libcurl 8.23.0 + TLS 根证书包）
powershell -ExecutionPolicy Bypass -File scripts/fetch_deps.ps1

# 2. 构建（独立目录，Release）
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Test

# 3. 运行
.\build-vs\Release\TaskScheduler.exe --config .\config.example.json
```

需要 **MSVC（Visual Studio 2022 或更高，支持 C11）**、**CMake ≥ 3.16**、
**Windows SDK**。不需要 vcpkg，不需要单独安装 libcurl。

---

## 当前进度

| 阶段 | 状态 |
| --- | --- |
| 1 需求差异确认与设计 | 完成（[DESIGN.md](DESIGN.md)） |
| 2 配置 / 输入 / 内存 / 时钟 / 取消 | 完成并实测 |
| 3 JSON 解析与校验 / 依赖图 / 分层 / 评分 / 调度 / 解释 | 完成并实测 |
| 4 提示词 + libcurl multi 通信 / 取消 / 错误处理 / 有限重试 | 完成并实测（含本地模拟服务 29 场景） |
| 5 Win32 GUI / 后台线程 / 120 秒提醒 / 本地编辑重排 | 完成；GUI 端到端 32 项断言实测 |
| 6 TXT / JSON 导出 | 完成并实测（真实写盘 + 读回校验） |

---

## 项目结构

```
TaskScheduler/
├─ CMakeLists.txt             构建定义（自动使用 third_party/curl）
├─ config.example.json        云端（DeepSeek）配置模板
├─ scripts/
│  ├─ fetch_deps.ps1          获取真实 cJSON / libcurl / CA 证书包
│  ├─ build.ps1               可复现构建（独立目录 + 可选测试）
│  ├─ check_layers.ps1        C 源码分层依赖检查（app/bridge → domain → state → util）
│  └─ make_release.ps1        生成便携 ZIP + 清单 + SHA-256
├─ third_party/
│  ├─ cJSON.c / cJSON.h       上游 v1.7.18 真实文件
│  ├─ curl/{include,lib,bin}  官方 8.23.0 头文件/DLL/导入库 + cacert.pem
│  ├─ DEPENDENCIES.txt        依赖清单（字节数 + SHA-256）
│  └─ README.md               获取方式与许可说明
├─ src/                       业务源码，按依赖方向分层（见 src/README.md）
│  ├─ app/                    入口与生命周期装配（main.c、controller.c/h）
│  ├─ bridge/                 唯一公开 C ABI：ts_bridge.h/.c、ts_file_list.h/.c
│  ├─ domain/                 业务领域：types、input、plan、schedule、analysis、present、export
│  ├─ state/                  配置与持久化：config、profile、profile_store
│  ├─ platform/               Windows 底层服务：text、runtime、credential、file_io
│  ├─ util/                   基础能力：mem.h（分配、安全释放、TsBuf）
│  └─ gui_win32.c/.h          旧 Win32 界面（原位保留，回归对照入口）
└─ tests/
   ├─ test_*.c                控制台回归与集成测试
   ├─ mock_server.py          测试用本地 OpenAI 兼容模拟服务（仅测试）
   ├─ run_http_tests.ps1      一键跑本地 HTTP 集成测试
   └─ validate_*.py           静态校验脚本
```

---

## 配置说明

复制 `config.example.json` 为 `config.json`（放 exe 同目录，或用 `--config` 指定）。

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `endpoint_url` | — | **完整**的 Chat Completions 地址。程序**不会**自动拼接 `/v1`。 |
| `model` | — | 模型名称。 |
| `api_key_env` | 空 | 保存 API Key 的**环境变量名**。留空则不发送 `Authorization`（适配无鉴权本地服务）。 |
| `ca_bundle_path` | `cacert.pem` | TLS 根证书包（PEM）。见下文“关于 HTTPS 证书”。 |
| `reasoning_effort` | `"none"` | `none`/`low`/`high`/`max`，或 `null` = **不发送**该参数。 |
| `connect_timeout_ms` | 15000 | 连接超时。 |
| `wait_prompt_ms` | 120000 | 120 秒提醒阈值；**仅提醒，不中断请求**。 |
| `request_timeout_ms` | 0 | 总超时；**0 = 禁用**（云端默认禁用）。 |
| `max_output_tokens` | 0 | 输出 token 上限。**0 = 不发送 `max_tokens`**，由服务端按模式取默认（非思考 8K / 思考 64K / `reasoning_effort=max` 时 128K）；官方允许范围 1 ~ 393216（384K）。**思考模式下请保持 0**：思考 token 与正文共用该预算，设小了正文会被截断。 |
| `max_input_bytes` | 262144 | 输入材料总字节上限；超限**报错不截断**。 |
| `max_response_bytes` | 2097152 | 响应体上限；超限中止接收。 |
| `json_mode` | true | 是否发送 `response_format: {"type":"json_object"}`。 |
| `temperature` | 0.2 | 采样温度。 |
| `reference_hours` | 2.0 | 工时优势归一化参考值（小时）。 |
| `weights.*` | 0.35/0.30/0.20/0.10/0.05 | 五维基础权重，必须 ∈ [0,1] 且**和为 1**（启动时校验）。 |
| `max_tasks` / `max_steps_per_task` | 200 / 50 | 数量上限。 |
| `max_retry_attempts` | 1 | **网络重试与模型修复共用**的额外调用次数（0 或 1）。 |
| `mock_mode` | false | 使用内置模拟响应，不发起网络请求。 |

### API Key

支持两种来源，**优先级：配置内联 `api_key` > 环境变量 `api_key_env`**。
两者都未提供时视为“无需鉴权”（适配无鉴权本地服务），不发 `Authorization`。

**方式一（推荐）：环境变量。** 密钥不落盘。

```powershell
# 当前会话有效
# 或永久写入用户环境变量（设置后需重开终端 / 重启程序）
setx DEEPSEEK_API_KEY "sk-..."
```

**方式二：配置内联。** 直接在 `config.json` 里填：

```json
"api_key": "sk-...",
"api_key_env": "DEEPSEEK_API_KEY",
```

> ⚠️ **内联方式的安全代价（请务必知晓）**
> 密钥会以**明文**写在 `config.json` 里。该文件可能被：
> 误提交到版本库、随发布包一起分发、被同机其它账户或备份工具读取。
> 如果使用内联方式，建议：
> 1. 用 `icacls config.json /inheritance:r /grant:r "%USERNAME%:(F)"` 收紧读取权限；
> 2. 把 `config.json` 加入 `.gitignore`，**不要**提交；
> 3. 不要把带密钥的配置放进要分享的发布包/压缩包。
> 共享或生产环境请改用方式一。

无论用哪种方式，程序都**不会**把密钥写入源码、日志或导出结果；
导出里只写**来源**（`config_inline` / `env` / `none`）与“是否存在”的布尔值。
内联密钥的格式检查与环境变量一致（首尾空白、控制字符、成对引号都会在请求前被拒绝）。

### 关于 HTTPS 证书（重要）

本项目的 libcurl 是 **curl.se 官方 MinGW 构建（LibreSSL）**，它**不使用 Windows 证书
存储**。因此调用 HTTPS 服务时必须提供 CA 证书包，查找顺序：

1. 配置里的 `ca_bundle_path`；
2. 环境变量 `CURL_CA_BUNDLE` 或 `SSL_CERT_FILE`；
3. **可执行文件同目录的 `cacert.pem`**（发布包与构建产物都会带一份）。

找不到时程序会**明确报错**并告诉你放哪个文件，
**绝不会**通过关闭证书校验来“让它先跑起来”。

证书包来源：curl.se 官方随包提供的 `curl-ca-bundle.crt`（源自 Mozilla CA 列表），
随仓库放在 `third_party/curl/bin/cacert.pem`，用 `scripts/fetch_deps.ps1` 可重放获取。
企业内网可替换成自建 CA 的 PEM 文件。

---

## 构建

```powershell
# 默认：Release，独立目录 build-vs，使用 Visual Studio 生成器
powershell -ExecutionPolicy Bypass -File scripts/build.ps1

# 清理后重建，并运行全部控制台测试 + Python 静态校验
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Clean -Test -StaticChecks

# 直接使用 CMake
cmake -S . -B build-vs -G "Visual Studio 18 2026" -A x64
cmake --build build-vs --config Release
```

产物（`build-vs\Release\`）：`TaskScheduler.exe`、`libcurl-x64.dll`、`cacert.pem`，
以及各测试可执行文件；编译器/命令记录在 `BUILD-INFO.txt`。

> 说明：本仓库开发环境里 CMake 的 **Ninja** 生成器会在 `try_compile` 阶段卡住
> （沙箱下子进程管道受限），因此默认用 Visual Studio 生成器。你的环境若 Ninja 正常，
> 可用 `-Generator Ninja`。

---

## 运行

```powershell
# 图形界面（默认读取 exe 同目录的 config.json）
.\build-vs\Release\TaskScheduler.exe

# 指定配置 / 离线模拟（不需要 API Key）
.\build-vs\Release\TaskScheduler.exe --config .\config.example.json --mock

# 非交互验收模式：加载材料 → 分析 → 导出 → 退出（按扩展名决定 TXT/JSON）
.\build-vs\Release\TaskScheduler.exe --config .\config.example.json `
    --input .\tests\data\sample_utf8.txt --export .\out.json
```

### 界面说明

- **顶部操作区**：添加文件（可多选）、输入文段、开始分析、取消、导出、按依赖层级分组。
- **状态区**：当前阶段、已等待时间、错误或重试状态（**不显示虚构的完成百分比**）。
- **下一步卡片**：建议现在做什么、为什么先做、完成后立即解锁什么；没有可开始任务时给出受阻原因。
- **左侧任务列表**：建议序号、名称、状态、截止时间、预计工时、前置摘要。
- **右侧详情**：任务目标与步骤、前置任务、外部条件、排序理由、得分分解、解锁任务、来源引用。
- **底部**：受阻 / 待确认 / 受影响任务，以及模型假设与待确认问题。
- **本地编辑**：标记完成/撤销完成、编辑字段、编辑多前置依赖、切换外部条件状态；
  修改后本地**立即重新校验并排序，不重新调用模型**。

状态一律“**颜色 + 文字**”双通道表达：可开始（绿）、待前置（蓝）、待确认（橙）、
受阻（红）、已完成（灰）；受上游受阻影响的任务标注“(受影响)”。

“**当前立即解锁**”（`R`，立刻满足全部前置的直接后继数）与
“**执行到该步骤时解锁**”（顺序列表里的“完成后解锁/仍待其它前置”）是两件事：
前者进入分数计算，后者是执行提示，界面上分别展示。

支持窗口缩放与基本 DPI 适配（`WM_DPICHANGED`），全 Unicode 中文显示。

### 导出

- **TXT（UTF-8 带 BOM）**：建议执行顺序（含步骤、前置任务、外部条件、排序理由与得分、
  完成后立即解锁）、受阻任务、待确认任务、受影响任务、未排入顺序的其他任务、
  模型假设、待确认事项。受阻任务**单独分区**并注明“未包含在上面的建议执行顺序中”。
- **JSON（UTF-8 无 BOM，用 cJSON 构造）**：`schema_version`、`algorithm_version`、
  `exported_at`/`sorted_at`、配置与权重、完整任务数据、状态快照、每个任务的排序依据与
  得分分解、`order` 最终顺序、受阻/待确认/受影响清单、假设与待确认事项、汇总统计。
  **绝不写入 API Key**（有自动测试遍历整棵输出树来保证）。

导出失败（路径不可写、磁盘满）只提示错误，**内存与界面中的分析结果保持不变**。

### 120 秒提醒与取消

状态区显示已等待时间；超过 `wait_prompt_ms` 弹出提示框「本次请求已等待超过 120 秒，
模型尚未返回完整结果。是否取消本次请求？」：

- 弹窗为**非模态**，弹窗期间**原请求继续运行**；主界面始终可用。
- 不操作或关闭提示框 = 继续等待；选择「继续等待」后**不重发请求、不重复弹窗**
  （已有自动化测试断言“全程只发送 1 次请求”）。
- 结果到达时自动关闭过期提示并展示结果。
- 取消是**协作式**的：设置取消标志，后台线程在 200ms 内响应；**不使用 `TerminateThread`**。
- 取消是**终态**：取消后即使完整结果到达也不采纳，**不自动重试**。
  **取消客户端请求不保证服务端停止推理。**

---

## 接入真实 DeepSeek 云端

按当前 DeepSeek 官方文档（<https://api-docs.deepseek.com/>）核对的结果：

| 项 | 值 |
| --- | --- |
| Chat Completions 地址 | `https://api.deepseek.com/chat/completions`（`/v1/chat/completions` 同样可用） |
| 模型名 | `deepseek-flash`、`deepseek-v4-pro`（旧名 `deepseek-chat` 已不在可选列表中） |
| 鉴权 | `Authorization: Bearer <API Key>` |
| JSON 输出 | `response_format: {"type":"json_object"}`；官方要求**提示词里也要出现 "json"**（本程序的 system 提示词已明确要求输出 JSON） |
| 输出长度 | `max_tokens` 取值 1..393216（384K）；未设置时默认 8K（非思考）/64K（思考）/128K（`reasoning_effort=max`） |
| 思考模式 | `thinking` 默认 **enabled**；**思考 token 与正文共用 `max_tokens` 预算**，预算不足时正文会被截断（`finish_reason=length`） |

**关于截断（实测数据）**：本项目用 843 字节材料 + `reasoning_effort: high` 实测一次调用为
输入 1237 token、输出 6688 token，**其中思考占 4607 token（约 69%）**，留给 JSON 正文的只有约 2080。
因此**思考模式下必须保持 `max_output_tokens: 0`**（不发送 `max_tokens`，由服务端给思考模式默认的 64K）；
若硬设一个偏小的值（例如 8000），思考就会吃掉大半预算、正文被截断。

导出 JSON 里会记录 `token_usage` 段（含 `reasoning_tokens`），
报错信息也会带上“输出共 N token，其中思考 M token”，便于判断是预算问题还是输入过长。

若服务不识别 `reasoning_effort`，把它写成 `null`，程序就不发送该参数。

---

## 切换到本地兼容模型

**前提**：本地服务器必须暴露 **OpenAI 兼容的 `/chat/completions`**，并且请求/响应字段与
下面约定一致——否则“只改配置”不成立：

- 请求：`model`、`messages[]`（`role`/`content`）、`temperature`、`max_tokens`、`stream`，
  以及可选的 `response_format`、`reasoning_effort`；
- 响应：`choices[0].message.content`（字符串）与 `choices[0].finish_reason`。

**步骤**（只改 `config.json`，不动代码）：复制 `config.local.example.json` 为你的本地配置：

```jsonc
{
  "endpoint_url": "http://127.0.0.1:11434/v1/chat/completions", // 填完整地址
  "model": "Qwen2.5-7B-Instruct",                               // 本地服务的模型名
  "api_key_env": "",                                            // 无鉴权则留空
  "ca_bundle_path": "cacert.pem",                               // http 端点用不到
  "reasoning_effort": null,                                     // 本地服务多半不认，写 null 不发送
  "wait_prompt_ms": 120000,
  "request_timeout_ms": 0,
  "json_mode": true,                                            // 本地不支持就改为 false
  "mock_mode": false
}
```

常见本地服务：`llama.cpp`（`llama-server --port 8000`）、`vLLM`（`vllm serve <model>`）、
`Ollama`（`http://127.0.0.1:11434/v1/chat/completions`）。

**注意事项**：

- 地址必须填**完整**路径，程序不会补 `/v1`。
- 本地模型若**不支持** `response_format`，把 `json_mode` 设为 `false`；提示词已要求“只输出 JSON”。
- 本地模型输出容易不规范：程序会做结构校验，并**最多请求一次针对性修复**
  （与网络重试共用 `max_retry_attempts` 这一次预算）。
- 本地模型能力较弱时可能拆解质量下降；程序不会为了“修好”而删除依赖边，而是明确报错。
- 同时保留云端与本地两份配置，用 `--config` 切换。

---

## 测试

```powershell
# 全部控制台回归（不需要网络）
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Test

# 本地 HTTP 集成测试（29 场景；会自行启动/关闭本地模拟服务）
powershell -ExecutionPolicy Bypass -File tests/run_http_tests.ps1

# 真实 HTTPS/TLS 传输层（需要网络；不发送用户材料）
.\build-vs\Release\ts_test_model_tls.exe cacert.pem

# GUI 端到端验收（真实窗口 + 消息循环 + mock 响应）
.\build-vs\Release\ts_test_gui.exe

```

测试工具（`tests/mock_server.py`、Python 检查脚本）**只用于测试**，
不是正式软件的运行依赖，也不进入发布包。

---

## 打包发布

```powershell
powershell -ExecutionPolicy Bypass -File scripts/make_release.ps1
```

生成 `dist/TaskScheduler-<版本>-win64-x64[-prerelease].zip`，内含：

- `TaskScheduler.exe`（Release）
- `libcurl-x64.dll`（唯一需要的非系统 DLL，依赖已用 `dumpbin` 核实）
- `cacert.pem`（TLS 根证书包）
- `config.example.json`（云端）与 `config.local.example.json`（本地兼容模型）——**不含密钥**
- `licenses/`（cJSON、curl、LibreSSL、nghttp2/3、ngtcp2、brotli、zstd、zlib-ng、libssh2、libpsl）
- `MANIFEST.sha256`（包内每个文件的 SHA-256）

脚本会做**打包前自检**：不得包含测试服务、测试可执行文件、静态库、调试产物，
也不得出现疑似密钥的字符串。

**发布包运行验证清单（在未安装开发工具的 Windows 上）**：

1. 解压到任意目录（**可含中文路径**）；
2. 启动 `TaskScheduler.exe`，应正常显示主窗口（无“缺少 DLL”提示）；
3. 把 `config.example.json` 复制为 `config.json`，填入 `model` 并设置
   `DEEPSEEK_API_KEY` 环境变量；
4. 加 `--mock` 启动一次，走通“输入文段 → 开始分析 → 查看顺序 → 标记完成 → 导出”，
   确认解析/校验/排序/展示/本地重排/导出都正常（**离线，不需要 Key**）；
5. 去掉 `--mock`，用一段不含敏感信息的小材料做一次真实云端调用；
6. 把 `wait_prompt_ms` 临时设为 3000，用一个慢速端点确认提醒框只出现一次、
   “继续等待”不重发、“取消”后不再重试；
7. 分别导出 `.txt` 与 `.json`，确认 TXT 在记事本里中文正常、JSON 可被解析器读取，
   且两者都不含密钥；
8. 正常关闭窗口，确认进程退出、无残留。

---

## 已知限制

1. **输入格式**：只支持 UTF-8 的 TXT / MD 与直接输入文段。PDF / DOCX / 图片等会**明确提示
   先转换为文本**（不静默忽略）；UTF-16/UTF-32 文件同样提示转码。
2. **不使用流式响应**：只能显示“已等待时间”，不显示生成进度，也**不显示虚构的完成百分比**。
3. **客户端取消不保证服务端停止推理**。
4. **默认无总超时**：`request_timeout_ms = 0`，只保留连接超时与响应大小上限——
   这正是 120 秒提醒存在的理由。
5. **不做资源级调度**：不建模多人/多机并行、上下文切换成本、日历与工作时间；
   `C`（关键链）**不代表单人串行总完成时间，也不宣称数学最优**。
6. **依赖图为 DAG**：循环依赖直接报错，不自动删边；不支持条件分支/或依赖。
7. **无依赖连线图**：主视图是顺序列表，仅支持“按依赖层级分组”，不画连线。
8. **单机单用户**：无数据库、无多用户协作、无历史版本。
9. **不自动执行任何任务**，也不运行模型生成的命令。
10. **模型可能偏保守**：对材料未明说的外部条件，模型倾向记为 `unknown`，于是任务显示为
    “待确认”而不进入 `R` 的立即解锁计数。例如真实样例 A 中，“手机缴电费”这类显然可行的
    任务被标为待确认，导致只有当次可做任务较少。这不是缺陷（未知条件不应默认为已满足），
    但会降低“立刻能做什么”的可用性；**在界面上把条件改为“已满足”即可本地重排，
    不需要再次调用模型**。提示词工程上或可进一步要求模型只把**材料明确提到**的限制
    记为 `unknown`（后续可优化）。
11. **`estimated_hours` 未知时为 `null`**，绝不当作 0；此时 `Q` 维度按 0.5 处理，
    并标记 `hours_unknown`。
12. **要求模型输出的字段完整**：`depends_on` / `preconditions` / `steps` / `source_refs`
    必须出现（空则 `[]`），`estimated_hours` / `estimate_reason` / `deadline` 必须出现
    （未知则 `null`）。省略字段会触发一次修复请求。
13. **必须提供 TLS 根证书包**才能用 HTTPS（见上文）。**不会**为了连通而关闭证书校验。

---

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 启动提示“配置加载失败” | 把 `config.example.json` 复制为 `config.json`；确认是合法 UTF-8 JSON；用 `--config` 指定绝对路径 |
| 提示“缺少 TLS 根证书包” | 把 `cacert.pem` 放在 exe 同目录，或在配置里设置 `ca_bundle_path`，或设 `CURL_CA_BUNDLE` |
| 提示“未启用 libcurl” | 运行 `scripts/fetch_deps.ps1 -Curl` 后重新构建；或设 `"mock_mode": true` / 加 `--mock` |
| 提示“配置要求使用环境变量 XXX 提供密钥，但当前进程读取不到该变量” | **这是请求前预检**：配置要求密钥但进程里没有，程序**不会**发出无鉴权请求。设置该环境变量后**必须重新启动程序**（运行中的进程不会自动继承新变量） |
| 提示“环境变量 XXX 的值存在可疑格式” | 密钥带首尾空白/控制字符/成对引号。请在本机重新设置该变量（**不要**把引号一起写进去），再重启程序。程序不会自动截断或改写密钥 |
| 提示“配置要求提供密钥，但当前既没有内联 api_key，也读取不到环境变量 XXX” | 两种设置方式任选其一：在配置文件 `"api_key"` 字段直接填写，或设置环境变量后**重新启动程序**。程序**不会**发出无鉴权请求 |
| 提示“模型名不存在”（HTTP 400） | 按服务端返回的受支持列表填 `model`。**当前实测受支持：`deepseek-flash`、`deepseek-v4-pro`**；填错只会 400，不是 401 |
| 提示“鉴权失败：服务端返回 HTTP 401” | 请求**确实带上了**密钥，但服务端拒绝了。提示里会给出配置文件路径、接口主机、密钥环境变量名与进程是否读到密钥，请据此核对“密钥与服务地址是否匹配”。**不会自动重试** |
| 提示“鉴权失败：服务端返回 HTTP 403” | 同上；密钥可能有效但无权访问该模型/接口。**不会自动重试** |
| 提示模型名不存在 | 按官方文档确认 `model`（当前为 `deepseek-flash` / `deepseek-v4-pro`） |
| 一直等待不出结果 | 正常现象（默认无总超时）；超过 120 秒会弹提醒框，可取消 |
| 提示“模型输出校验失败” | 输出不符合约定结构；程序已自动请求过**一次**修复；可换模型或降低输入复杂度 |
| 提示“分析材料超过输入上限” | 减少文件/文段，或调大 `max_input_bytes`（不会静默截断） |
| 添加文件被拒绝 | PDF/DOCX/图片等不支持，请先转换为 UTF-8 文本（后续计划见 `TODO.md`） |
| 模型把任务判为“待确认” | 材料未说明该条件；在界面上把外部条件改为“已满足”即可本地重排 |

