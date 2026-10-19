# TaskScheduler — Flutter 桌面界面

本目录是 TaskScheduler 的新桌面界面（Flutter / Dart），**业务核心仍然是原来的 C 代码**：
模型调用、JSON 解析、业务校验、依赖图、评分与建议顺序都没有重写，只新增了一个
窄接口的桥接 DLL（`ts_bridge.dll`）供 Dart 通过 FFI 调用。

旧 Win32 界面（`TaskScheduler.exe`）**保留不动**，作为回归对照：它继续直接链接
`ts_core`，不依赖 `ts_bridge.dll`。

当前版本：**产品 0.1.0 / 构建 0.1.0+10**（关于页显示 0.1.0，pubspec/包名同）。
0.1.0 修复了任务清单的一个真实缺陷：先选中任务、再切到「受阻」等会把该任务筛掉的筛选时，
列表为了让选中行仍然可见而向**定长列表**追加元素，build 期间抛
`Cannot add to a fixed-length list`，整块列表面板不再渲染。现在改用可增长列表，
并由 `test/widget/task_list_filter_test.dart` 与 `test/widget/app_shell_test.dart` 两个回归用例锁住。
同时按要求删除设置页探测按钮下方的一条提示句，并去掉开关行鼠标悬停时的整块灰色底。

0.09 继续结构与文字整理：删除设置页/甘特图上多余的说明性文字（账户页首段说明、
“（仅展示 / 参考）”等括号注、API Key 立即生效说明、日历与相对工时视图的说明条），
消除 Bezier 控件与样式值里重复的字体常量，抽出真实 DLL 测试的公共准备代码，
并把一次性诊断转成常驻回归（`test/widget/task_list_filter_test.dart`）。

0.08 完成了 C 端分层（`src/app|bridge|domain|state|platform|util`）、启动装配抽取、
主题拆分（`ui/theme/values.dart` + `ui/theme/buttons.dart` + `ui/theme.dart`）与
通用控件归位（`ui/widgets/`）。

---

## 1. 目录

```
flutter_app/
├─ lib/
│  ├─ main.dart                     入口：只调用 src/app/bootstrap.dart 的 runTaskScheduler()
│  └─ src/
│     ├─ app/bootstrap.dart         启动装配：数据目录 → DLL → 设置 → 会话 → AppShell
│     ├─ app/startup_screens.dart   加载中 / 致命错误两屏
│     ├─ ffi/bridge_ffi.dart        裸 FFI 绑定（TsBridgeBuffer / 全部入口）
│     ├─ ffi/native_gateway.dart    高层封装（JSON ⇄ Map、轮询式异步）
│     ├─ model/                     共享数据契约（plan/display/session/settings/calendar/…）
│     ├─ state/                     控制器、存储、排程与文档提取
│     ├─ ui/theme/values.dart       样式值：颜色、状态色、尺寸、字体、间距
│     ├─ ui/theme/buttons.dart      按钮样式映射（solid / outline / inline / ghost）
│     ├─ ui/theme.dart              主题装配（buildAppTheme）与主题模块出口
│     ├─ ui/widgets/                通用控件与基础形状（bezier_ui、BezierSegments、状态芯片…）
│     └─ ui/                        页面与业务控件（app_shell、calendar_gantt、settings/…）
└─ test/                            单元 + widget + 真实 DLL 集成测试
```

---

## 2. 四个协议边界

| 边界 | 载体 | 谁生成 | 说明 |
| --- | --- | --- | --- |
| 模型输出 | snake_case JSON | 模型 | `schema_version: "2.0"`，含 `summary`、`previous_task_id`、`notes[]`。仍兼容旧的 `1.0`。 |
| 本地计划 | camelCase JSON（`plan_local.c`） | App（C 解析 / 序列化） | 稳定任务 ID、`actualStatus`、`evidence`。**唯一**在 Dart 与 C 之间交换的计划结构。 |
| 展示 DTO | `display.c` 生成的 JSON | C | 只含界面可渲染字段：状态、工时、步骤、前置/后继、外部条件、自然语言理由、时间轴位置。**绝不含**分数、权重、候选池、公式。 |
| 会话存储 | `index.json` + `conversations/*.json` | App | 版本追加式、原子写；进程崩溃时回退到 `.bak`。 |

请求身份（`conversationId` / `requestId` / `baseVersionId` / `baseRevision`）与版本 ID、
稳定任务 ID **全部由本地生成**；模型的 `T1/T2` 只在单次响应内有效，永远不作为跨版本身份。

---

## 3. 界面结构

```
┌────────────┬───────────────────────────────────────────────┐
│ 历史会话   │ 一句话总结（标题）+ 版本切换 + 导出 + 新建      │  ← 顶带，两侧同高 56
│ 240px      ├──────────────────┬────────────────────────────┤
│            │ 任务清单（复选） │ 树状图 / 甘特图（可切换）   │  ← 表头同高，下方一条通栏横线
│            ├──────────────────┴────────────────────────────┤
│            │ 待确认 / 受阻 / 分析假设（计数，可展开卡片）    │
├────────────┼───────────────────────────────────────────────┤
│ 用户 admin │ 附件 + 文本框 + 加号 + 发送箭头（无语音入口）   │  ← 底带，两侧等高
└────────────┴───────────────────────────────────────────────┘
```

布局用**三条通栏横带**实现而不是两列各自堆叠：顶带（会话标题栏 ｜ 摘要标题栏）、中带、
底带（用户入口 ｜ 输入框）。同一横带里的两侧由同一个 `Row` 决定高度，所以"标题栏同高""底带
等高"是布局约束保证的，不是靠调数值凑出来的；底带另有 `IntrinsicHeight`。

- **任务清单**：复选框、任务名、状态（颜色 + 文字）、预计工时。点击行 = 选中并固定详情；
  勾选复选框只改完成状态，不会连带触发行的动作。
- **树状图**：DAG **竖向**分层——最上面是第 1 层（最先执行），越往下越靠后；同一层在同一行
  左右并排；连线从父任务下边进入子任务上边，箭头朝下。每个任务只画一个节点，
  **保留全部前置连线**；支持缩放、平移、适应全部；选中时高亮直接前置/后继及连线。
- **甘特图**：横轴是**相对累计工时**，严格按 C 核心给出的单人串行顺序；未知工时之后的任务
  不给确定起止时间，已完成任务单列且不占剩余时间。
- **详情卡**：悬停 ~300ms 预览、点击固定；分节显示（标题/状态 → 工时与截止 → 步骤 →
  前置与外部条件 → 安排原因 → 解锁对象 → 折叠来源）；关联任务可点击跳转，会**真正滚动清单、
  平移图、滚动时间轴**，而不是只改一个内部变量。
- **用户入口（左下角）**：头像 + `admin`。点开向上弹出菜单：**设置**（可用）、**意见反馈**、
  **退出登录**（浅灰、无交互）。**没有登录系统**，`admin` 只是本地称呼与设置入口。
- **设置弹窗**：居中模态，左栏 7 项（账户安全 / 通用 / 模型 / 快捷键 / 通知 / 存储 / 关于），
  0.0.4 起全部为真实页面（账户安全仍只做 UI）：
  - 所有编辑进入草稿，切换分类不丢；关闭时有未保存修改会询问“保存 / 放弃 / 继续编辑”；
  - **模型**：供应商连接、完整端点、认证方式、API Key（只写不读）、模型发现/手动 ID、
    思考开关与强度、JSON 模式、设为默认；获取模型列表与测试响应是可取消的短超时探针；
  - **通用**：亮/暗主题、字号 0.85–1.30、默认依赖视图、已完成任务显示、发送方式；
  - **快捷键**：Ctrl+Enter 发送、Ctrl+N 新会话、Ctrl+, 设置、Ctrl+O 添加文件、Esc 关闭浮层；
  - **通知**：应用内完成/失败提醒；120 秒提醒独立，不受静音影响；
  - **存储**：目录/大小/打开目录、无密钥备份与恢复、只清 `*.tmp` 缓存；
  - **关于**：真实版本、许可证/帮助、脱敏诊断（无密钥）；无更新后端时不假装检查成功。
- **模型选择**：输入框上方显示当前连接与模型；点击可为**本会话后续请求**切换，切换本身
  不生成计划。全局默认只影响新会话；每个新版本记录实际来源，旧版本显示“来源未知”。
- **等待态**：只显示“正在思考 · 用时 mm:ss”和停止按钮；不显示模型思考正文，不显示虚构百分比。
  超过 120 秒弹出非模态提醒（继续等待 / 取消），继续等待不会重发请求。

---

## 4. 构建与运行

前置：MSVC（VS2022+）、CMake ≥ 3.16、Flutter SDK（本机 `C:\Users\<user>\develop\flutter`）。

```powershell
# 1) 构建 C 内核 + ts_bridge.dll + 桥接集成测试，并跑 C 测试
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1

# 2) 构建 Flutter Windows 应用，并把 DLL/证书/示例配置放到 exe 同目录
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1

# 3) 运行（默认读取 exe 同目录的 config.json；没有则进入 mock 模式）
.\flutter_app\build\windows\x64\runner\Release\taskscheduler.exe
```

运行目录需要：`ts_bridge.dll`、`libcurl-x64.dll`、`cacert.pem`、`config.json`（可选）。

离线/无密钥时：在 `config.json` 里设 `"mock_mode": true`，界面走内置模拟响应。0.0.4 起
分析需要先有一个模型连接：旧 `config.json` 会在首次启动时迁移成 `legacy-config`（不删旧文件），
也可以在“设置 → 模型”里新增连接；完全没有连接时发送会被明确拒绝，不会静默改配置。

单独跑测试：

```powershell
cd flutter_app
flutter test                     # 单元 + widget + 真实 DLL 集成（DLL 未构建则自动跳过）
flutter analyze
```

单独打包：

```powershell
# 0.05 默认打无密钥包；密钥只在设置 → 模型里写入 Windows 凭据管理器
powershell -ExecutionPolicy Bypass -File ..\scripts\make_flutter_release.ps1 `
  -Version 0.05 -NoApiKey
```

### 会话数据保存在哪里

默认放在**程序所在目录**下的 `TaskSchedulerData\`（便携：整个文件夹可整体搬走）。
程序目录不可写时按以下顺序回退，**界面上不会有任何提示**：

1. 环境变量 `TASKSCHEDULER_DATA_DIR`
2. 程序所在目录 `TaskSchedulerData`（默认）
3. `%LOCALAPPDATA%\TaskSchedulerFlutter`
4. `%APPDATA%\TaskSchedulerFlutter`
5. `%TEMP%\TaskSchedulerFlutter`
6. 全部不可写 → 内存存储：程序照常可用，此时才会在顶部提示“本次运行不保存历史”

每个候选都会**实际探测可写性**（建目录 + 写/删探针文件），因为“目录存在”不等于“可写”。
实现见 `lib/src/state/storage_root.dart`，行为由 `test/storage_root_test.dart` 覆盖。
“设置 → 存储”会显示本次实际选中的目录、来源与持久化状态，并允许打开目录、备份/恢复与清理
`*.tmp` 缓存。

0.0.4 的文件布局：

```
<数据目录>/
├─ index.json                    会话列表
├─ conversations/<id>.json       会话与版本（完成状态、版本来源）
├─ attachments/<id>.json         提取后的附件文本
├─ settings.json                 供应商连接（schemaVersion 2，无密钥）
└─ settings/app_prefs.json       界面偏好（schemaVersion 1）
```

---

## 5. 密钥纪律

- 设置窗口里输入的 API Key 只经 FFI 写入 **Windows 凭据管理器**
  （`TaskScheduler/model/<数据空间>/<profileId>`；数据空间由数据目录路径稳定生成，
  两个便携副本不会共用密钥），Dart 侧没有读取接口，也不会回显。
- 凭据与保存时的主机绑定；连接地址更换后必须重新确认并重新输入，旧密钥不会被发往新主机。
- 同一连接的对话地址与模型列表地址必须**同源**（scheme + host + 有效端口）；
  `modelsUrl` 跨源时，bearer/环境变量凭据在保存或请求前被拒绝，不会把密钥发往另一个主机。
- 旧 `config.json` 的内联 `api_key` 仅在首次迁移时导入凭据管理器一次；旧文件保持原样。
- `settings.json`、备份文件、会话历史、展示 DTO、导出文件、日志与诊断都不会包含密钥。
- 测试一律使用假密钥，并在测试后删除自己创建的凭据条目。

---

## 6. 本轮明确不做

PDF/Word/PPT 解析、OCR、语音输入、多人并行资源排程、拖动甘特条自动改计划、
阅读模型思考正文、账户服务器/登录/修改密码、系统级通知、任意快捷键重映射、数据目录迁移。
账户安全页只是为未来接入保留的禁用 UI，**不是已实现的账户系统**。上传入口沿用现有的
TXT / MD 支持范围。

---

## 7. 验证状态

0.05 实际执行结果：

- `scripts/build_flutter_bridge.ps1`：exit 0；`ts_test_settings` 160、`ts_test_probe` 211，其余 11 个 exit 0；CTest 15/15。
- `flutter analyze --no-pub`：`No issues found!`。
- `flutter test --no-pub`：**328 passed / 0 failed / 1 skipped**（skip = opt-in 121 秒长等待；含真实 DLL/本地 HTTP 集成测试与文档提取 37 项）。
- `scripts/make_flutter_release.ps1 -Version 0.05 -NoApiKey`：exit 0，发布包 `dist\TaskScheduler-0.05-win64-x64`。
- 真实 GUI：0.05 包启动，21 张截图；搜索/会话菜单/任务过滤/输入展开/版本差异/快捷键/通知/存储/关于。
- 未验证：系统通知真实显示与点击定位、10/100/1000 规模性能、完整 DPI/键盘矩阵、真实云端。

完整报告：`docs/TASKSCHEDULER_0_05_ACCEPTANCE_REPORT.md`；验证矩阵：[`VERIFICATION.md`](../VERIFICATION.md)。

