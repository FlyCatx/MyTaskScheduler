# TaskScheduler 迁移记录：Win32 → Flutter（C 内核保持不变）

> **适用版本：0.05 迁移当时（源码路径为 0.05 布局）。** 0.08 起 C 源码已按
> `src/app|bridge|domain|state|platform|util` 分层，下文出现的 `src/plan_local.c`、
> `src/display.c`、`src/export_user.c`、`src/main.c` 等路径均已移动。当前结构见
> [src/README.md](src/README.md)，本轮变更见 [CHANGELOG.md](CHANGELOG.md)。
> 本文作为历史记录保留，不复述当前路径。

本次迁移把**桌面界面**改为 Flutter，同时保留原有的 C 业务核心（模型调用、JSON 解析、
业务校验、依赖图、评分、建议顺序、导出）。旧 Win32 程序继续可构建、可运行，作为回归对照。

- 新界面：`flutter_app/`（说明见 [flutter_app/README.md](flutter_app/README.md)）
- 新桥接：`(0.08 起) src/bridge/ts_bridge.{h,c}` → `ts_bridge.dll`
- 新增 C 模块：本地计划编解码、展示 DTO、面向用户的 TXT 导出
  （0.08 起分别位于 `src/domain/plan/plan_local.c`、`src/domain/present/display.c`、
  `src/domain/export/export_user.c`）
- 旧界面：`src/gui_win32.c` + `src/app/main.c` → `TaskScheduler.exe`（业务代码未改动）

---

## 0.05 数据/版本迁移说明

- 产品版本 **0.05** 与构建版本 **0.0.5+5** 是同一版本；旧 0.0.4 数据目录可直接打开。
- 会话/索引 schema 升到 2：新增 `meta`（customTitle/pinOrder/archivedAt/deletedAt）与
  `activityAt`。旧文件缺字段时使用安全默认；**未来 schema 会拒绝读取并提示，不会覆盖**。
- 索引仍可重建（缺失/损坏时按会话文件恢复）；永久删除先写 `tombstones.json`，因此
  `.bak` 回退和索引重建都不会让已删除会话复活。附件只清理无人引用项。
- 操作日志 `operations.json` 记录永久删除；中断后下次启动续做并清理索引。
- 设置/偏好仍为 `settings/app_prefs.json`，新增 `shortcuts`（稳定 keyId+修饰键）、
  `notifySystem` 等字段；缺失时用默认值，损坏的快捷键项被丢弃而不阻止启动。
- 系统通知使用 Windows 通知中心；若系统拒绝，应用内会提示“系统通知不可用”。
- 存储迁移：存储页输入空目标目录→复制+逐文件校验→写位置指针，**下次启动**切换；
  旧目录保留；凭据按数据目录命名空间隔离，迁移后需重新输入 API Key。
- 备份/恢复包含会话元数据、偏好与快捷键，仍排除所有密钥；恢复拒绝分析中/未保存设置/同 ID 冲突。

---

## 0. 0.0.4 设置数据迁移（旧 config.json / 旧会话 → 新设置）

0.0.4 新增 Flutter 设置窗口，但**不要求**用户改旧文件：

- 首次以旧 `config.json` 启动时，C 层在内存中生成一个 `legacy-config` 连接：
  `chatUrl` = 原 `endpoint_url`（仍是**完整** Chat Completions 地址，不自动拼 `/v1`）；
  协议按主机推断（`api.deepseek.com` 用 DeepSeek Chat，其它用 OpenAI 兼容）；
  `reasoning_effort`：`none` → 思考关闭，`low/high/max` → 思考开启 + 该强度，`null` → 不发送。
- 旧内联 `api_key` 仅在首次迁移时一次性写入 Windows 凭据管理器；旧 `config.json` **不删除、
  不修改**，因此回退到 0.0.3 或旧 Win32 界面仍然可用。未设置内联密钥时保留 `api_key_env` 的
  环境变量读取方式。
- 旧会话 JSON 没有 `modelSelection` / `modelSource` 时：会话视为“跟随全局默认”，旧版本的
  来源显示“来源未知”，任务、版本、完成状态、执行签名照常读取（不伪造模型名）。
- 只有用户第一次在设置窗口点“保存”才会写 `settings.json`；加载损坏或不兼容的
  `settings.json` 时保留原文件并回退默认值，不覆盖用户数据。
- 备份（0.0.4 新增）为单个 JSON：含会话、版本、完成状态、界面偏好与**无密钥**的连接配置；
  恢复先校验再暂存提交，失败保留原数据并留下 `.bak`。模型连接的 API Key 必须在恢复后重新输入。

---

## 1. 四个协议边界（实施结果）

| 边界 | 实现位置 | 关键约束 |
| --- | --- | --- |
| 模型输出 | `src/prompt.c`（提示词）、`src/plan.c`（解析）、`src/plan_validate.c`（校验） | schema 升到 `2.0`：新增 `summary`、`previous_task_id`、`notes[]`（带 `task_refs`）；校验器**同时接受**旧的 `1.0`，所以旧 fixture 与模拟服务无需改动 |
| 本地计划 | `src/plan_local.c` | camelCase，携带稳定任务 ID 与 `actualStatus`；这是 Dart ⇄ C 之间**唯一**的计划结构 |
| 展示 DTO | `src/display.c` | 只输出可渲染事实与自然语言理由；**不输出** 分数 / 权重 / 公式 / 候选池 / 思考正文 / token 用量 |
| 会话与版本 | `flutter_app/lib/src/state/session_store.dart` + `model/session.dart` | `index.json` + `conversations/*.json`，追加式版本、原子写（tmp → 主文件 / `.bak` 回退） |

请求 ID、会话 ID、版本 ID、稳定任务 ID 全部由本地生成。模型的 `T1/T2` 只在单次响应内有效，
跨版本身份只认本地稳定 ID（`execution-v1` 执行签名 + 名称相似度匹配）。

---

## 2. 逐项对照：要求 → 实现 → 证据

| # | 要求 | 实现 | 本轮实际验证 |
| --- | --- | --- | --- |
| 1 | 检查可复用模块，保留旧 Win32 可运行版本 | `ts_core` 原样复用；`TaskScheduler.exe` 仍是 CMake 目标，不链接 `ts_bridge` | 构建产物含 `TaskScheduler.exe`；10 个旧控制台测试全部 exit=0（§4.1） |
| 2 | 四个协议边界；摘要只随有效结果提交；ID 本地生成 | 见 §1；`_commitResult()` 只有在提交门通过后才**同时**写标题与计划 | `test/commit_gate_test.dart`（9 例）、`tests/test_bridge.c` 的 late/cancel 用例 |
| 3 | 先建真实 C DLL + 最小 FFI 验证 | `ts_bridge.dll`（76 项断言）+ `flutter_app/test/bridge_live_test.dart` 直连真实 DLL | §4.1、§4.3 |
| 4 | 会话持久化、版本基准检查、稳定身份匹配、完成状态继承（含拆分/合并复核） | `session_store.dart`、`commit_gate.dart`、`reconciler.dart`、`signature.dart` | §4.3（19 例） |
| 5 | 固定测试数据完成布局、勾选、统一选择、悬停/固定详情、关联跳转（真实滚动/平移） | `task_interaction.dart` 的 revealer 注册表 + 三个视图各自的 `_reveal`（清单 `ensureVisible`、依赖图矩阵动画、甘特横向滚动） | §4.3 widget 测试 + §4.4 截图 |
| 6 | 完整 DAG 分层布局、相对工时甘特、跨视图同一任务高亮 | `ui/dag_graph.dart`（分层 + 全前置连线 + 贝塞尔 + 平移/缩放/适应全部）、`ui/gantt_chart.dart`（相对工时轴、分组） | §4.1 `display.c` 时间轴断言 + §4.4 截图 |
| 7 | 接入真实分析流程、新增 summary、保持云端配置/取消/120 秒提醒/异常处理 | `analyze.c` 的 `ts_analyze_run_ex` + 桥接工作线程；`app_controller.dart` 的轮询、120s 提醒、迟到结果拒绝 | §4.1（mock 分析、取消、迟到结果）+ §4.3 |
| 8 | 自然语言理由 + 分节待确认/受阻/假设卡片；保留条件确认、编辑与导出；诊断不外泄 | `display.c` 的 `build_user_reasons`；`ui/notes_panel.dart`；`ui/task_edit_dialog.dart`；`ui/detail_popup.dart`（条件点击切换）；`export_user.c` | §4.1 的 `display`/`export` 断言 + §4.3 的 “no score…” 断言 |
| 9 | 单元 / widget / C bridge / Windows GUI 测试 | 见 §4 | 55 个 Dart 测试 + 76 项 C 断言 + 真实 GUI 截图 |

---

## 3. 原有缺陷的处理

| 原问题 | 处理 | 证据 |
| --- | --- | --- |
| 关联任务跳转无效 | `TaskInteraction.selectAndReveal()` 依次调用所有视图注册的 revealer：清单 `Scrollable.ensureVisible`、依赖图用 `TransformationController` 把目标节点动画到视野中心、甘特用 `ScrollController` 横向滚到对应工时。**不是**只改内部选择变量 | widget 测试 “related task chips switch the selection to the target task” / “switching to the gantt keeps the same selected task” |
| 界面暴露分数加权与公式 | 展示 DTO 由 `display.c` 单独生成，物理上不含 `score/weight/candidates/公式`；旧的 `TsScheduleStep.reason`（含 `100×(0.35×U…)`）只留在诊断导出（`format=diag`） | C 测试断言快照不含“基础分/最终分/candidates/weight/76.05”；widget 测试断言界面文本不含这些词 |
| 备注与详情堆叠无层次 | 详情卡分节（标题状态 → 工时截止 → 步骤 → 前置与外部条件 → 安排原因 → 解锁 → 折叠来源）；底部大备注框换成“待确认/受阻/分析假设”三计数 + 可展开卡片 | 截图 `04-notes-and-detail.png` |
| 等待时显示模型思考正文 | 桥接只上报 `stage`/`detail`（构建提示词/调用模型/修复/等待重试），从不携带正文；界面只显示“正在思考 · 用时”与停止按钮 | 代码路径 + 事件 JSON 契约（`ts_bridge.h`） |

---

## 4. 验证记录（本轮实际执行）

### 4.1 C 侧

```
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1
```

构建产物：`ts_core.lib`、`TaskScheduler.exe`（旧界面）、`ts_bridge.dll`、全部测试 exe。

`ts_test_bridge.exe` —— **76 通过 / 0 失败**（独立运行复核：`76 通过，0 失败`）：

- 配置缺失 → 可读错误，缓冲区可安全释放；`ts_bridge_free` 清空
- `ts_bridge_info` 报告脱敏端点、mock 模式、`hasApiKey`，**不含密钥**
- `ts_bridge_edit`：可开始/待确认/受阻/已完成状态、未知工时标记、未知工时之后“起始时间待定”、
  已完成任务单列 `completed`、DAG 层级、来源引用、待确认/假设条目
- 展示快照**不含**“基础分/最终分/score/candidates/weight/76.05”
- 非法计划（依赖不存在）被拒绝且**不返回半成品快照**
- 导出：用户 TXT 不含“基础分/最终分/全局加分公式”、含“为什么这样安排”；诊断 JSON 有
  `schema_version` 与计算数据、不含密钥
- `analyze_async` 调用本身 < 500ms；已有分析时拒绝第二个（不排队）
- 事件队列：`started`/`progress`/终态事件，回带 conversationId/requestId/baseRevision
- `result` 可重复读取（poll 不消费结果）；`release` 后取结果干净失败；重复 release 被拒绝
- 取消后结果 `ok=false`；真实传输层（不可达端点）下同样验证取消与迟到结果
- `shutdown_begin` → 轮询 `shutdown_ready` → `destroy` 顺序正常

旧回归（全部 exit=0）：`ts_test`、`ts_test3`、`ts_test4`、`ts_test6`、`ts_test_validate`、
`ts_test_plan`、`ts_test_export_json`、`ts_test_model`、`ts_test_initonce`、`ts_test_auth_offline`，
以及旧界面的端到端 GUI 测试 `ts_test_gui.exe` —— **32 项全部通过**
（含“点击导出确实弹出对话框”“关闭主窗口无挂起”）。说明旧 Win32 界面在本次改动后仍然可用，
可以作为回归对照。

### 4.2 新增/调整的 C 测试

- `tests/test_bridge.c`（新增，见 §4.1）
- `tests/test_validate.c`：schema 用例从“拒绝 2.0”改为“拒绝 3.x、接受 2.0”，与新协议一致

### 4.3 Dart / Flutter 侧

```
cd flutter_app
flutter analyze     # No issues found!
flutter test        # All tests passed! (62)
```

覆盖点：

- `test/signature_test.dart`（9）：估时/优先级/影响力/截止/条件状态变化**不**改变执行签名；
  名称/步骤/依赖变化**会**改变；依赖按名称比较；空白与大小写折叠不产生假差异
- `test/reconciler_test.dart`（16）：内容未变才继承完成；调换顺序/重编号不影响匹配；
  hint 指向不存在的 ID 不被信任；已待复核不会被静默清除；拆分与合并进入待复核；
  被删除的已完成任务进入变更摘要；依赖改写为稳定 ID
- `test/commit_gate_test.dart`（9）：取消 / 跨会话 / 迟到响应 / 基准版本或修订过期 / 重复版本 ID 全部拒绝；
  同一会话只允许一个活动请求；取消后票据保持占用直到终态
- `test/session_store_test.dart`（6）：版本追加不破坏旧版本；主文件损坏回退 `.bak`；
  附件文本在源文件移动后仍可读；索引随版本数更新
- `test/app_controller_test.dart`（7）：**会话切换**不串计划；**旧版本只读**（勾选为 no-op）；
  **完成状态复核**落盘并 revision+1；图表视图偏好持久化；无原生桥接时给出清晰错误；
  草稿可编辑且不影响计划；**编辑被 C 校验拒绝时不落盘**
- `test/widget/app_shell_test.dart`（13）：历史栏/摘要/清单/双图切换/底部输入存在且**无语音**；
  界面不含内部数据；复选框只改完成状态并触发重算、且不触发“固定详情”；
  勾选后落盘且 revision+1；切换图表保持选中；点击节点固定详情、关闭后消失；
  关联 chip 真正切换目标；备注计数展开；未知工时显示“工时待确认”而非 0；
  甘特对未排期给出原因；显示快照 JSON 解析（未知工时、completed、起始时间待定、计数）
- `test/bridge_live_test.dart`（4）：直连真实 `ts_bridge.dll` —— `edit()` 的非阻塞与
  快照内容、非法计划被拒、`analyzeAsync` 立即返回并送达终态事件与结果、`close()` 不挂起

### 4.4 Windows GUI（真实进程 + 截图）

```
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
powershell -ExecutionPolicy Bypass -File scripts/gui_probe.ps1 ...
```

产物：`flutter_app\build\windows\x64\runner\Release\taskscheduler.exe`
（同目录有 `ts_bridge.dll`、`libcurl-x64.dll`、`cacert.pem`、`config.example.json`）。

截图（`docs/screenshots/`，均由上述脚本在真实进程中截取，DPI 感知 1:1）：

1. `01-tree-view.png` —— 左侧历史会话、顶部一句话总结 + 版本/导出/新建、
   中部任务清单（复选框/序号/状态/工时/层）+ 依赖树状图（自动适应 + 全前置连线）、
   底部三计数与输入区（加号 + 发送箭头，无语音按钮）
2. `03-pinned-detail.png` / `04-notes-and-detail.png` —— 点击节点**固定**详情卡（显示“已固定”），
   分节内容（步骤/前置/安排原因/解锁/仍待其它前置/时间轴说明），
   底部备注计数展开为分节卡片并带可跳转 chip
3. `02-tree-hover-preview.png` / `05-gantt-relative-hours.png` —— 甘特图：相对工时轴（0 小时 / 1 小时）、
   “已完成（不占用剩余时间）”分组、“未排期（每行说明原因，不伪造起止时间）”分组
   （预计工时待确认 / 前序任务工时未知起始时间待定 / 受阻未排期 / 外部条件待确认未排期），
   底部并列“没有可立即执行的任务：所有剩余任务均受阻/待确认…”提示；同时可见悬停预览卡

旧 `build-vs\Release\TaskScheduler.exe` 仍可运行，作为回归对照。

---

## 5. 过程中实际发现并修复的问题（不是“参考包里提到的问题”）

1. **FFI 长度用了 UTF-16 码元数**：Dart 把 `String.length` 当作 UTF-8 字节数传给 C，
   任何中文请求都会被截断 → C 报“JSON 解析失败”。改为按 UTF-8 字节数传递（`_NativeUtf8`）。
   这个问题在 `bridge_live_test.dart` 里被真实 DLL 暴露出来。
2. **详情卡永不显示**：`AppShell` 只监听 `AppController`，而悬停/固定状态在 `TaskInteraction`
   里；已改为同时监听，否则“点击固定详情”完全失效。
3. **浮窗挡住图表切换按钮**：详情卡现在避开图表头部 52px 区域。
4. **`format` 字符串悬垂指针**：`ts_bridge_export` 里 `format` 指向已 `cJSON_Delete` 的树，
   导致诊断导出被写成日常 TXT；已改为先复制到本地缓冲。
5. **拆分/合并检测过窄**：仅用名称相似度无法识别“…ListInit 与 ListInsert”这类合并；
   改为“相似度 + 显著词被包含”，并补了对应单元测试。
6. **widget 测试死锁**：`pumpAndSettle` 在 fake-async 区域里等真实文件 I/O 永不返回；
   改为注入 `SessionRepository` 的内存实现（同时让生产代码依赖接口而非具体存储）。
7. **`_applyTasks` 在校验失败时误判成功**：`_safeCompute` 返回上一份快照会被当成“成功”，
   现改为返回可空快照并拒绝落盘。
8. **本地编辑不更新执行签名**：改名/改步骤后应更新签名，否则下次分析会误判“内容未变”。
9. **受限账户下启动即失败**（用户实测：“无法启动 … PathAccessException … OS Error 5”）：
   数据目录被写死为 `%LOCALAPPDATA%\TaskSchedulerFlutter`，且初始化异常被当成致命错误。
   现改为**候选 + 探测 + 回退**（`storage_root.dart`）：env → `%LOCALAPPDATA%` →
   程序目录 `TaskSchedulerData` → `%APPDATA%` → `%TEMP%` → 内存降级；
   改用其它位置时在顶部提示实际路径，左侧会话栏常驻显示保存位置；
   全部不可写时仍可正常使用，只是不保存历史。启动失败信息也按阶段区分
   （DLL 缺失 / 数据目录问题），不再对任何异常都显示“缺少 ts_bridge.dll”。
   已用两种环境各启动真实进程验证（受限环境走便携目录 + 提示条；正常环境走 AppData 且无提示条）。

---

## 6. 尚未执行 / 已知限制

1. **本轮没有用真实 DeepSeek 云端做回归**：验证使用 mock 模式与不可达端点（用于取消/超时路径）。
   真实云端调用需要用户自己的 `DEEPSEEK_API_KEY`，本轮未使用任何真实密钥。
2. **没有做长时间连续压力测试**（例如连续 50 轮补充要求、超大材料）。
3. 甘特图**不允许拖动条**改计划（本轮范围外）。
4. 不支持 PDF / DOCX / PPT 解析、OCR、语音、多人并行资源排程。
5. 依赖图是分层 + 层内按建议顺序布局，**不是**交叉最小化最优布局；大计划可读性会下降。
   初始缩放有可读性下限（0.62），超出部分靠“适应全部”或平移查看。
6. “编辑旧版本产生分支”**未实现**：旧版本为只读。
7. 文件选择是应用内浏览对话框（避免第三方包与阻塞式原生模态框），不是资源管理器风格原生对话框。
8. 合成鼠标事件在部分位置不可靠，因此 GUI 验证主要依赖：真实进程截图（首屏/详情/备注/甘特）
   + widget 测试（交互语义）。

---

## 7. 常用命令

```powershell
# C 内核 + 桥接 DLL + C 测试
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1

# Flutter 应用（含 analyze / test / build windows / 拷贝运行期 DLL）
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1

# 生成演示会话数据（用于界面核对）
cd flutter_app
dart run tool/seed_demo_data.dart "C:\path\to\data-dir"

# 截取界面（可带点击序列）
powershell -ExecutionPolicy Bypass -File scripts/gui_probe.ps1 `
  -Exe flutter_app\build\windows\x64\runner\Release\taskscheduler.exe `
  -DataDir out\demo_data -ConfigPath out\demo_config.json -OutDir out\gui
```

