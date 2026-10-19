# 变更记录

本文件按时间倒序记录实际发生的变更。每条都对应仓库里可核查的代码/脚本改动。

---

## [0.1.0] — 2026-10-20 — 修复任务清单筛选渲染错误 + 删除探测提示与开关行悬停底色

产品版本 **0.1.0**（构建版本 **0.1.0+10**）。交付包
`dist/TaskScheduler-0.1.0-win64-x64.zip`。C ABI（2）与导出符号（101 个）未变。

### 1. 修复：切换「全部 / 受阻」时任务清单不再渲染（功能错误）
- **现象**：先点选一个任务，再切到「受阻」（或任何把该任务筛掉的筛选/搜索），任务清单
  整块不再渲染。
- **根因**：`ui/task_list.dart` 把筛选结果存成定长列表
  （`all.where(matches).toList(growable: false)`），随后为了让“已选中但被筛掉”的任务
  仍然可见而执行 `visible.add(...)`，在 build 期间抛出
  `UnsupportedError: Cannot add to a fixed-length list`。
- **修复**：改用可增长列表（`toList()`），保持“临时显示被选中的行”这一既有行为。
- **回归测试**：`test/widget/task_list_filter_test.dart` 新增用例
  “选中的任务被筛选隐藏时仍能渲染（临时显示那一行）”，修复前该用例以同一异常失败。
- 影响面：仅 Dart 列表构建方式；筛选语义、隐藏计数、排序与 C 侧快照均未改变。

### 2. 删除探测按钮下方的提示句（附图 1）
- `settings_model_page.dart`：`_modelCard` 不再渲染
  「连接地址或认证方式有未保存的修改：请先保存连接，再测试实际请求目标（测试只针对已保存的配置）。」
  （`_isUnsavedTargetBlock` 过滤该原因）。同一件事实仍由下方橙色提示
  「当前表单有未保存的修改：探测使用已保存的配置（修订 N）……」说明一次。
- 另外两种禁用原因（连接未保存、没有模型列表地址）继续在按钮下方显示。
- 相关断言更新为：按钮禁用 + 被删句子不存在 + 橙色提示存在。

### 3. 删除开关行的整块悬停底色（附图 2）
- `settings_model_page.dart`：三个 `SwitchListTile`（思考模式、JSON 模式×2）显式设置
  `hoverColor: Colors.transparent`。此前鼠标停在行上时 ListTile 会画一条整行宽的浅灰矩形，
  夹在卡片里像另一张面板。
- 回归测试：`思考模式的开关行没有整块悬停底色` 断言 `hoverColor == Colors.transparent`。
- 视觉差异仅限该底色；开关的拇指、轨道、聚焦与点击反馈未改。

### 4. 版本
- `app_info.dart` → `0.1.0 / 0.1.0`，`pubspec.yaml` → `0.1.0+10`，
  `make_flutter_release.ps1` 默认 `-Version 0.1.0` 并登记别名 `0.1.0 = 0.1.0`。

---

## [0.09] — 2026-10-19 — 说明性文字清理 + 结构复核（字体去重、测试公共准备、分层检查）

产品版本 **0.09**，pubspec/构建版本 **0.0.9+9**。交付包
`dist/TaskScheduler-0.09-win64-x64.zip`。功能逻辑、数据格式、C ABI（2）与导出符号未变。

### 1. 按要求删除界面上的说明性文字
- 账户安全页：删除页首"账户服务尚未接入……下面的表单是界面占位……"整段说明；
  `未登录云端（账户服务未接入）` → `未登录云端`。禁用表单与按钮未动。
- 模型页：删除字段标签里的括号注（`基础地址（仅展示 / 参考）`、`Chat Completions 完整地址
  （请求实际使用）`、`模型列表完整地址（可空）`、`模型 ID（可手动输入）`）；
  删除 `留空则不能「获取模型列表」…` 提示行与 `密钥写入后立即生效…` 说明行；
  删除凭据主机行尾的 `（换地址后需要重新填写密钥）`。
- 日历甘特：`任务 · 已安排/预计（真实日期时间，不是累计工时）` → `任务 · 已安排/预计`；
  `_banner` 不再输出"已根据可用时间自动安排…N 个任务未排期"，只在有冲突或排程说明时出现
  （冲突列表本身未动）。
- 相对工时甘特：删除顶部两条说明条（轴语义、工时未知提示）与
  `任务 · 相对累计工时（单人串行，不是日历排程）` 的括号行。
- 相关 widget 断言同步调整：改用 `本地账户` 作为"停留在账户页"的判定，删除对已移除文案的断言。

### 2. 结构复核（依据 `TaskScheduler_DeepSeek_Architecture_Review_Prompt.md`）
- **字体常量去重**：`widgets/bezier_ui.dart` 的 `_segmentFont` / `_segmentFontFallback` 与
  `theme/values.dart` 的 `kUiFontFamily` / `kUiFontFallback` 值完全相同，改为引用后者并删除重复定义。
- **导出写盘整合**：`domain/export/export_user.c` 不再自己转换路径、写 BOM、开文件；
  改用 `export_internal.h` 的 `ts_export_write_file`（UTF-8 BOM + 失败删除半成品），
  因此 `export_user.c` 不再直接使用 `windows.h` / `MultiByteToWideChar`。
- **测试公共准备**：`test/support/native_bridge.dart` 提供 `findBridgeDir` / `stageNativeLibs`，
  `bridge_live_test.dart` 与 `settings_bridge_integration_test.dart` 共用，删除两份重复实现。
- **分层检查脚本**：新增 `scripts/check_layers.ps1`，静态检查 `src/` 的 include 方向
  （app/bridge → domain → state → util，platform → util），当前 0 违规；
  唯一例外（`app/main.c` → `gui_win32.h`）在脚本与 `src/README.md` 中显式登记。
- **一次性诊断转正**：新增 `test/widget/task_list_filter_test.dart`，覆盖全部 `TaskFilter` ×
  `showCompleted` 的渲染与受阻任务可见性（原为 `test_tmp` 里靠 `print` 观察的探针）。
- **归档（不删除）**：`flutter_app/test_tmp/filter_probe2|3_test.dart` 与
  `tests/fix_check_macro.py`（`CHECK(` 已全部改写完成、无格式化参数残留）移入 `docs/archive/`，
  并写明替代覆盖。

### 3. 文档修正（准确性）
- `src/README.md`：删掉"平台调用只出现在 platform"这类绝对表述，改为逐项列出仍然存在的
  平台调用（`state/profile_store.c`、`domain/analysis/model.c`、`domain/analysis/prompt.c`、
  `domain/export/export.c`、`bridge/ts_bridge.c`、`gui_win32.c`）与迁移前提；
  补充"文件头注释不能替代契约"与分层检查命令。
- `ui/theme/values.dart`：文件头不再把 `TsColors.apply` 说成纯函数，明确它会改写静态 `_palette`。
- `CMakeLists.txt`：`BUILD-DEPS.md` 断链改为 `third_party/DEPENDENCIES.txt`；
  `controller.c` 注释改为事实（只被 `gui_win32.c` 使用，bridge 不共享该路径）。
- `MIGRATION.md`：标注为 0.05 历史记录，旧路径逐条给出 0.08 后的新位置。

### 4. 版本
- `app_info.dart` → `0.09 / 0.0.9`，`pubspec.yaml` → `0.0.9+9`，
  `scripts/make_flutter_release.ps1` 别名新增 `0.09 = 0.0.9`。

---

## [0.08] — 2026-10-20 — 结构优化：分层目录、主题拆分、段前注释收敛

产品版本 **0.08**，pubspec/构建版本 **0.0.8+8**。交付包
`dist/TaskScheduler-0.08-win64-x64.zip`。本轮只做结构与注释整理，
**视觉、交互、数据格式、C ABI（2）、导出符号（101 个）全部不变**。

### 1. C 侧按依赖方向分层（移动为主，行为不变）
- 新布局：`src/app`、`src/bridge`、`src/domain/{input,plan,schedule,analysis,present,export}`、
  `src/state`、`src/platform`、`src/util`；`gui_win32.c/.h` 原位保留（Win32 回归入口）。
- `CMakeLists.txt`：新增 `TS_INCLUDE_RELS` 登记 include 根目录，核心源列表按层分组；
  测试 target 复用同一组 include 根。
- 边界整改（函数级，非纯移动）：
  - `ts_secure_free` 由 `config.c` 下沉到 `util/mem.h`（static inline），`platform/credential.c`
    不再引用 `config.h`；
  - 新增 `platform/file_io.{c,h}` 的 `ts_file_read_raw`（原 `ts_input_read_file_raw`），
    `state/config.c` 不再引用 `domain/input/input.h`；
  - 迁移后 `platform` 只依赖 `util`，`state` 只依赖 `platform`/`util`。

### 2. Flutter 侧结构优化
- 启动装配从 `lib/main.dart` 抽到 `src/app/bootstrap.dart`（`runTaskScheduler` / `TsBootstrap`），
  启动期界面抽到 `src/app/startup_screens.dart`；`main.dart` 只剩入口调用。
- 主题拆分（解除 theme ↔ bezier_ui 循环 import）：
  - `ui/theme/values.dart`：`TsPalette`、`TsColors`、`StatusPalette`、`TsSizes`、
    `kPaneHeaderHeight`、`kTopBarHeight`、字体常量（只依赖 material，不放控件）；
  - `ui/theme/buttons.dart`：`TsButtons` 样式映射（可依赖基础形状）；
  - `ui/theme.dart`：`buildAppTheme` 装配 + 主题模块导出（`values` / `buttons` / 按钮行 / 状态芯片）；
  - `kTopBarHeight` 从 `history_panel.dart` 迁到值层，`summary_bar.dart` 不再为它单独 import。
- 通用控件归位到 `ui/widgets/`：`bezier_ui.dart`、`bezier_menu.dart`、`status_strip.dart`、
  `button_row.dart`（`TsButtonRow`）、`status_chip.dart`（`StatusChip`）。
- `ui/theme.dart` 作为主题出口保留原有 import 路径，页面与设置的引用无需改动。

### 3. 段前注释收敛（只保留文件职责与主要函数）
- C：49 个源文件的文件头「设计理由/为什么这样写」改为「文件职责 + 主要函数」两段式。
- Flutter：17 个文件的段前注释改为「文件职责 + 主要类型/函数」，并清除叙述版本历史的注释
  （`0.06/0.07 removed…`、`0.07 bug fix` 等）与已不成立的“循环 import”说明。
- 代码逻辑、常量值、断言与测试未改动。

### 4. 文档
- 新增 `src/README.md`：C 目录分层、允许依赖方向、include 约定与构建命令。
- `README.md` / `flutter_app/README.md` 更新项目结构与当前版本说明。

---

## [0.07] — 2026-10-19 — 图 1–11 修正：时间解析、真实模型识别、菜单/按钮/设置改造

产品版本 **0.07**，pubspec/构建版本 **0.0.7+7**。交付包
`dist/TaskScheduler-0.07-win64-x64.zip`（SHA-256 `9a7b3fb7…3ad5701`）。
完整验收记录见 `docs/TASKSCHEDULER_0_07_ACCEPTANCE_REPORT.md`。

### 1. 共用时间解析器（图 1）
- 新增 `state/time_ranges.dart`：`parseTimeRanges` / `parseTimeRangesOrError` /
  `mergeTimeRanges` / `formatTimeRanges` / `totalTimeRangeMinutes`。
  接受中英文冒号、中英文逗号/分号/顿号、`-`/`–`/`—`/`~`/`〜`/`至`/`到`，允许分隔符旁空白；
  `8` 与 `08` 等价；完整匹配（`8-12xyz` 报错）；`24:00` 仅可作结束，禁止 `24:30`/`25:00`/`8:60`；
  `00:00` 结束保留"日末"旧义；跨午夜 `22:00-02:00` → 结束分钟 1560；等起止拒绝；
  `00:00-24:00` 为整日；多段排序合并后合计。
- `model/calendar.dart`：`WallClockRange.format` 对 >1440 的结束改用回绕时刻显示
  （`22:00-02:00`），并新增 `isFullDay` / `crossesMidnight`。
- 三个编辑入口（每周可用、日期例外、占用）全部改用该解析器，不再各写一套正则。

### 2. 真实模型识别日历约束（图 2）
- 新增 C 作业 `ts_bridge_constraints_async`（`src/constraints.c` / `.h`）：专用 system 提示词 +
  专用结果校验器（`ts_constraints_validate`），绝不把占用 JSON 交给任务 schema；复用现有配置
  快照、凭据、取消、429/5xx 退避与一次"修复"预算；如实上报本次请求实际使用的思考配置。
- 桥接：`TS_JOBKIND_CONSTRAINTS`，`jobType="constraints"`，结果含 `constraints.proposals/notes`
  与 `thinking`；与探针共用 poll/cancel/result/release（最多 4 个并发）。
- Dart：`model/calendar_proposals.dart`（提案模型、稳定内容 ID、序列化）与
  `state/calendar_constraints.dart`（解码/校验/应用/去重）；`NativeGateway.constraintsAsync` /
  `constraintsResult`；`Conversation.calendarProposals` 持久化缓存（带材料签名）。
- `AppController.fetchCalendarProposals`：材料 = 输入框文本 + 已上传附件提取文本；
  命中同签名缓存不重复请求；`force` 仅由"重新识别"触发；迟到/切换会话/材料变化不落地。
- 删除旧的本地正则"识别"路径（不再把正则冒充 AI）。

### 3. 可用时间弹窗布局（图 1–3）
- 显式 `Scrollbar` + `ScrollController` + 内容右侧 16 px 留白（滚动条不再压住控件）。
- 底部"取消 / 保存并重新安排"统一 36 px 高、9 px 圆角、12.5 px 字号、居中；
  日期例外"关闭/开放"与删除按钮之间有 8 px 真实间距、32 px 命中区；占用行窄宽度自动换行。
- 删除两条指定说明（"每周规则按此偏移…"、"空白的星期表示不可用…"），保留时区实际值与合计。

### 4. 图标分层与工具栏（图 4）
- 全局 `IconButtonTheme`/`TextButtonTheme` 不再强制蓝底：普通图标与行内动作透明 + hover/focus 反馈；
  真正实体操作显式使用 `TsButtons.solid()`。
- `BezierSegments` 外层 `Align` 加 `widthFactor: 1`：日/周控件不再占满一行，
  日历工具栏（今天/缩小/放大/可用时间/自动安排/重排全部）与日/周同处一行，窄窗自然换行。
- 删除"真实年月日与时间；拖动可移动片段…"与"未排期（每行说明原因…）"两处文字。

### 5. 统一菜单（图 5–6）
- 新增 `ui/bezier_menu.dart`（`showBezierMenu`）：主题表面色、1 px 细边框、Bezier 圆角、
  统一 40 px 行高、`elevation: 0`、无阴影；`showGeneralDialog` + `FadeTransition`（150 ms）
  只做透明度过渡，无缩放/尺寸/位移；保留外部点击、Esc、焦点恢复与边缘定位。
- 会话右键、会话"更多"、日历片段右键全部改用该组件。

### 6. 设置窗口（图 6）
- 默认进入「账户安全」（`showSettingsDialog` 与 `SettingsDialog` 默认值）。
- 底栏固定「取消 / 应用 / 保存」，去掉 `accountOnly` 单关闭特例：
  应用 = 校验 + `SettingsController.save()` + 停留在当前页且清除 dirty；保存 = 同一次写入后关闭；
  无修改时应用禁用、保存仍可退出；取消只放弃上次应用以来的草稿；失败留在窗口并显示原因。

### 7. 设置页删除说明性文案（图 7）
- 存储页：删除页顶说明、完整路径、"来源/持久化"行、"模型设置文件"行、迁移/备份/恢复/清理长说明；
  保留数据目录名、占用统计、打开目录、刷新占用、目录输入框与全部操作。
- 模型页：删除预设/基础地址/端点/探测/认证说明与 `SwitchListTile.subtitle`，保留真实错误与不可用原因。
- 快捷键：删除页顶说明、逐条 `def.description` 与两条长提示；保留 Esc/编辑键保留说明（真实限制）。
- 通知/关于：删除逐条 subtitle 与冗余段落，保留"更新服务未配置"等真实状态。
- 通用：删除页顶说明、三项 subtitle 与字号"预览"教学块、"当前：…"总结行。

### 8. 按钮间距与规格（图 8–9）
- 新增 `TsSizes`（实体按钮 36、紧凑 32、行内 28、图标命中 32/28、组内 8、组间 14）
  与 `TsButtonRow`；快捷键"录制/清除/默认"改为 8 px 间隔的三按钮。
- `TsButtons` 拆为 `solid` / `outline` / `inline` / `ghost` / `icon`，图标与行内动作不再蓝底；
  模型连接卡的默认勾选/删除图标透明但保留语义色与 28 px 命中区。

### 9. 布局与配色（图 10–11）
- `SettingsTile` 断点从 640 改为按文字缩放计算的最小可用宽度（300×scale），
  空间足够时控件回到功能名右侧；"把当前连接设为默认"移至标题行右侧，默认值另起一行；
  思考强度 low/high/max 加宽并三等分。
- `TsPalette` 新增 `selected/selectedHover/selectedPressed/selectedDisabled/track/trackDisabled`，
  `ThemeData` 为 Switch/Slider/Checkbox/Radio 显式配色（含 hover/pressed/disabled），
  `BezierSegments` 轨道与选中块改用同一 token；弹窗/菜单主题 elevation 0、无阴影。

### 10. 版本与打包
- `pubspec.yaml` → `0.0.7+7`，`app_info.dart` → `0.07 / 0.0.7`，
  `make_flutter_release.ps1` 版本别名新增 `0.07 = 0.0.7`，并以文件夹为根打包 ZIP。

### 11. 测试
- 新增 `test/time_ranges_test.dart`（21）、`test/calendar_constraints_test.dart`（25）、
  `test/widget/calendar_settings_dialog_test.dart`（12）、C 侧 `tests/test_constraints.c`（27）；
  `bridge_live_test.dart` 增加真实 DLL 的约束作业往返与类型隔离验证。
- 按新需求重写/更新 `theme_buttons_test`、`session_menu_test`、`settings_pages_test`、
  `settings_model_page_test`、`settings_storage_page_test`、`ui_polish_test`、`ui_polish2_test`。

---

## [0.06] — 2026-10-19 — 分段控件几何、按钮配色、日历排程

产品版本 **0.06**，pubspec/构建版本 **0.0.6+6**。

### 1. 分段选择器几何（图1 错位）
- 新增 `SegmentControlGeometry`（`ui/bezier_ui.dart`）：底轨 = 整个控件矩形 `(0,0,W,H)`，
  内部可用宽 `W-2p`，每槽 `(W-2p)/N`，每项点击矩形与文字槽统一为 `(p+i*s, p, s, H-2p)`，
  统一间距 `kSegmentGap = 4`；绘制、标签、命中区共用同一对象，Painter 不再自行推算。
- 根因：0.05 的 `Row` 用 `desired` 自行算槽宽，而父级紧约束把 `SizedBox` 撑到实际宽度，
  Painter 用 `size.width` 另算一遍 → 蓝块与文字分属两套几何；`track` 还有 `y=4` 偏移、
  块宽 `slot-6`/块高 `height-6`、`pad=5` 等多套留白。
- 布局改为 `Align` 包裹以拿到松约束，声明宽度即实际宽度；`expand` 时等分宿主宽度
  （模型「预设/协议」「认证方式」已启用），窄容器按可用宽度压缩、文字省略。
- 动画：仍只移动/放大选中块，底轨与文字不动；峰值放大受 `kSegmentGap` 限制，绝不越出底轨
  或被裁平；快速反向从当前可见状态继续；点当前项不重复回调；禁止动画时直达终态。
- 颜色：块色改用统一 token（浅色/深色均为 `#3B6CF6`），不再硬编码 `0xff009bea`。

### 2. 按钮配色统一
- `TsPalette`/`TsColors` 新增按钮 token：`buttonFill #3B6CF6`、hover/pressed、`onButton` 白、
  `buttonDisabledFill` 灰、`onButtonDisabled`、`buttonFocus`；深色主题同样用深蓝 + 白字
  （浅色 accent `#7A9BFF` 仅用于文字/链接/描边，避免白字对比度不足）。
- 新增 `TsButtons`：`filled`（普通按钮）、`danger`（红）、`success`（绿）、`link`（行内文字链）、
  `ghost`（横幅内低调图标）、`closeIcon`（上一轮半透明圆底关闭键）。
- 主题层统一 `Elevated/Filled/Outlined/Text/IconButton` = 深蓝实底白字 + 统一 hover/pressed/focus，
  禁用仍为灰且不可点；替换了设置页 `_compactButtonStyle`、`SettingsOutlinedButton`、
  存储页 `_buttonStyle`、确认对话框、告警条、输入区 + 号与发送键等散落的浅蓝/描边/强调色写法。
- 语义色保留：危险红、成功绿、禁用灰；导航/列表选中底色不变；状态文字不统一改蓝。

### 3. 日历排程（甘特图新增子模式）
- 新模型 `model/calendar.dart`：`CalendarSettings`（时区偏移、排程起始、规划范围、每周多段可用、
  日期例外、课程/活动/休息占用、吸附步长、分块时长、待确认备注）、`ScheduleSegment`
  （稳定 id、taskId、UTC 起止、auto/manual、暂定、revision）、`CalendarSchedule`。
- 新引擎 `state/calendar_planner.dart`（纯函数、可固定时钟）：可用区间展开（含跨午夜、扣占用）、
  确定性自动排程（依赖优先 → 最早截止 → 建议顺序 → 稳定 id；分块不跨不可用区间；
  容量不足只报剩余）、冲突检测（跨任务/自身重叠、不可用时段、依赖顺序、超过截止、
  依赖不确定、超出范围）、工时同步编辑（移动/改时长/拆分/新增/取消/重组）。
- 工时规则：`新预计工时 = 旧预计工时 + 本次片段时长变化量`；完整安排时等价于片段之和；
  「取消此段安排」只把工时退回未安排余额、不改预计工时。
- 控制器：`calendar`/`schedulingTasks()`/`applyCalendarEdit`（片段+工时+revision 一次原子提交，
  走 C 核心校验并落盘，失败保留原状）/`runAutoSchedule(keepManual)`/`ensureCalendarReady`/
  `applyCalendarSettings`；详情直接改工时时若已安排超出新工时，只提示不删片段。
- 版本继承：新版本只迁移仍存在任务的安排，删除任务的片段清理由 `inheritedBy` 完成。
- UI `ui/calendar_gantt.dart`：真实年月日 + 小时刻度、日/周尺度、缩放、今天/首个片段定位、
  横向滚动、每任务多片段分泳道、冲突描边与冲突列表定位、拖动信息条（日期/起止/时长/实时冲突预览）、
  边拖自动滚动、Esc 取消、右键拆分/精确编辑/取消安排、15 分钟吸附、松手一次提交。
- UI `ui/calendar_settings_dialog.dart`：排程范围/时区/吸附、每周多段、日期例外、课程/活动/休息占用、
  材料识别建议（勾选后应用，标注待确认）、无法结构化文本保留为待确认备注。
- UI `ui/segment_edit_dialog.dart`：键盘可用的精确起止编辑与「取消此段安排」。
- `ui/gantt_chart.dart` 新增 `GanttPanel`：外层「依赖图/甘特图」不变，甘特内新增「日历排程/相对工时」，
  子模式按会话持久化（`Conversation.ganttMode`，旧会话默认相对工时）。

### 4. 数据与兼容
- `PlanVersion.calendar` 为新增可选字段：旧版本文件缺该键时按「尚无日历数据」读取，
  不视为 24 小时可用；会话 schema 仍为 2（增量字段，旧构建忽略而非损坏）。
- 备份/恢复按整文件复制，自动覆盖新字段；会话 Markdown 导出新增「日历安排」小节。
- 未改变 C 核心与相对工时语义（`startHours/endHours` 未塞入日历时间戳）。

### 5. 验证（本轮真实执行）
- `flutter analyze` 无问题；`flutter test` 410 passed / 1 skipped（新增 68 项：几何/像素、
  按钮色、排程/冲突/工时、持久化与迁移、日历控件拖动与 Esc、深色/1.5 倍字号/150% DPI/窄窗）。
- `flutter build windows --release --no-tree-shake-icons` 成功；`scripts/make_flutter_release.ps1`
  重新构建 C 桥并运行 `ts_test_bridge` 后打包 0.06。
- 真机（本机 Windows，125% 缩放）脚本化运行 Release 版截图：日历自动安排、相对工时不变、
  拖动预览与提交、设置-模型分段控件与按钮、可用时间编辑器、0.05 旧数据迁移；
  见 `docs/screenshots/0_06/` 与 `docs/TASKSCHEDULER_0_06_ACCEPTANCE_REPORT.md`。
- 未执行：本机以外 DPI/系统主题环境、真实鼠标录屏（仅有逐帧截图）、真实模型请求。

---

## [0.05 UI polish] — 2026-10-18 — 七项界面优化

- 关于页删除更新服务/帮助/许可证/诊断的实现细节长句，压缩为状态/名称/入口；诊断改为紧凑 disclosure，不再留空卡片。
- 依赖图：同层节点共同中心轴、内容包围盒居中、非连续 level 用索引布局、resize 重新适配、用户平移不被 rebuild 抢回；小窗保持可读缩放。
- 任务浮窗关闭按钮移出滚动区，40×40 半透明圆底、固定右上、键盘与语义完整。
- 甘特图浮窗使用实际标签/条形矩形和来源视图锚点；切换图表关闭旧浮窗并清空旧锚点，滚动/定位后刷新。
- 全局 Microsoft YaHei 覆盖主题、TextTheme、输入 hint/label、Tooltip 与分段文字。
- 新增 `bezier_ui.dart`：共享三次贝塞尔路径、OutlinedBorder、InputBorder、Clipper、`ShapeDecoration`；替换产品内旧 BorderRadius/OutlineInputBorder/ClipRRect 等矩形圆角。
- 新增 `BezierSegments`：静止底轨 + 单一蓝色块 360ms 位移/放大再缩小；接入图表、侧栏模式、主题/视图/发送方式、模型协议/认证/思考强度、小时/分钟；支持禁用、Tab/Enter、Semantics、减少动态效果、快速反向。
- 验证：新增 DAG 布局/缩放、关闭按钮固定、甘特锚点、分段动画、主题字体、贝塞尔几何测试；全量 Flutter 342 passed / 1 skipped，CTest 15/15。
- 未执行：真机 100%/125% DPI、动画录屏、甘特浮窗截图；详见 `docs/UI_POLISH_ACCEPTANCE_REPORT.md`。

---

## [0.05] — 2026-10-18 — 会话生命周期、快捷键、任务/历史、迁移、通知与文档

产品版本 **0.05**，pubspec/构建版本 **0.0.5+5**；关于页 0.05，包与 VERSION 同时写明二者。

### 1. 会话数据与持久化
- 新增 `ConversationMeta`（自定义标题/置顶顺序/归档时间/删除时间），详情与索引同步；
  旧 JSON 缺字段安全默认；未来 schema 抛 `SessionFormatException`，不静默覆盖。
- `activityAt` 独立于视图切换，图表切换不再挤乱最近列表；普通按活动时间、置顶按 pinOrder。
- `SessionStore`：schema 2、墓碑 `tombstones.json`（防 .bak/索引复活）、永久删除清理
  主文件/.bak/.tmp、附件 GC 只删无人引用（正常/归档/回收均保护）、操作日志
  `operations.json`（当前覆盖永久删除并支持重启续做）。
- 控制器：重命名/置顶/归档/恢复/回收/恢复回收/永久删除/相邻打开/连续新建复用空会话；
  删除/归档运行中会话先取消并让迟到结果无法提交；附件重复添加拒绝。

### 2. 会话 UI 与搜索
- 侧栏搜索（自定义+自动标题）、全部/归档/回收切换、置顶/最近分区；行末 ⋯ 与右键菜单
  始终绑定目标 conversationId；重命名/置顶/归档/导出/移入回收/永久删除确认。
- 回收站支持恢复与永久删除；删除撤销/状态提示；归档恢复保留置顶状态。

### 3. 快捷键
- `AppCommands` 稳定动作注册表：发送/新建/设置/添加文件/Esc/定位输入/搜索会话/切换图/侧栏/停止分析。
- 设置页支持录制、清除、单项/全部恢复默认、搜索、分组、冲突拒绝；Esc 固定不可改；
  保护 Ctrl+C/V/X/A/Z/Y；持久化稳定 keyId+修饰键（`AppPreferences.shortcuts`），损坏配置不阻止启动。
- 发送组合键与 Enter 偏好统一，输入区提示即时同步；录制时原动作不执行；长按不重复。

### 4. 主界面/任务/历史
- “树状图”更名“依赖图”（wire 仍 `tree`）；图连线对比度提高，新增 100% 实际大小、
  适应全部、定位当前任务、缩放百分比。
- 任务列表搜索 + 全部/可开始/受阻/已完成过滤，显示隐藏数量；被过滤的关联任务临时显示并标注。
- 输入区保持折叠 4 行/原高度，新增手动展开（同 TextField、文本/选择/附件保留），Esc 收起。
- 任务编辑：日期选择器+手输+清空+严格 YYYY-MM-DD 校验；小时/分钟换算；前置任务搜索与成环阻止。
- 完成/任务编辑一级撤销，校验版本/修订，计划变化后拒绝并解释；文本 Ctrl+Z 保留。
- 版本差异按稳定任务 ID 展示新增/删除/名称/工时/截止/依赖/完成继承/复核；导出当前计划和全部历史。
- 关于页诊断信息折叠；检查更新保持原位置、真正禁用灰色、无网络。

### 5. 存储迁移 / 通知 / 文件
- 新增 `StorageMigrationService`：目标必须空目录、复制到 staging、逐文件长度+哈希校验、
  提升后写位置指针（下次启动生效），失败保留原数据；旧目录不删除；提示凭据命名空间变化需重输。
- 新增 C `ts_bridge_show_notification`（Windows 托盘气泡）与点击查询、Dart FFI/UI 开关；
  系统拒绝时应用内提示，不谎称已发送；120 秒提醒保持独立。
- 新增本地 PDF/DOCX/PPTX 文本提取（`archive` MIT、`xml` MIT、自写最小 PDF 解析器）；
  位置标注页码/段落/幻灯片，扫描 PDF 明确 `unsupported_ocr`，旧 .doc/.ppt 不支持；
  超限/加密/空/损坏/取消/部分成功结构化返回；文件选择过滤器扩展。

### 6. 验证
- C：`ts_test_settings` 160、`ts_test_probe` 211、其余 11 个 exit 0；CTest 15/15。
- Flutter：`flutter analyze` 0 issue；`flutter test` 328 passed / 1 skipped（opt-in 121 秒长等待）。
- 桌面：0.05 包实际启动，21 张截图覆盖搜索/菜单/过滤/展开/差异/7 页/快捷键/通知/存储/关于/主题重启。
- 真实云端与系统通知显示/点击、规模性能、完整 DPI/键盘矩阵未验证，详见
  `docs/TASKSCHEDULER_0_05_ACCEPTANCE_REPORT.md` §6。

---

## [0.0.4] — 2026-10-18 — 设置功能（账户安全 UI / 模型连接与凭据 / 主题 / 备份）

### 1. 设置窗口与草稿
- 左侧保留七项：账户安全 / 通用 / 模型 / 快捷键 / 通知 / 存储 / 关于；窗口最大 980×660，
  小窗口（宽<900 或高<600）自动收窄并允许滚动。
- 所有编辑写入 `SettingsController.draft`，切换分类不丢；关闭（X / Esc / 点遮罩）有未保存
  修改时询问「保存 / 放弃 / 继续编辑」；保存中禁用按钮并显示「正在保存…」，失败留在窗口并
  显示原因；账户页没有可保存配置时页脚只有「关闭」，不显示假成功。
- 账户安全页只做 UI：说明账户服务未接入，账号/密码/登录/修改密码全部禁用，不联网、不保存
  密码、不伪造登录身份；本地分析不受影响。

### 2. 模型配置、凭据与请求快照
- 新增 `settings.json`（schemaVersion 2，位于数据目录）：供应商 profile（稳定 `id`、递增
  `revision`、协议、完整 chat/models URL、认证方式、模型、思考、JSON 模式），**不含密钥**；
  原子保存（`.tmp` → `.bak` → 提升），失败保留旧设置；乐观 revision 冲突整体拒绝并返回当前值。
- 新增 Windows 凭据管理器存储（`TaskScheduler/model/<profileId>`），Dart 只有写入/删除接口，
  **没有读取密钥的 FFI 接口**；凭据与保存时的主机绑定，换地址后必须重新输入，不会把旧密钥
  发往新主机。旧 `config.json` 的内联 `api_key` 仅在首次迁移时导入一次，旧文件不删不改。
- 分析/探针在锁内深拷贝完整配置与凭据到 job 自有快照，工作线程只读快照：运行中保存、删除或
  切换模型不影响已发出的请求；不再读取/修改 `b->cfg` 或销毁 gateway 来切模型。
- 请求体按协议构造：DeepSeek 顶层 `thinking.type=enabled/disabled`，开启时才带
  `reasoning_effort=low/high/max`，关闭后不残留 effort；OpenAI 兼容连接默认省略这些专有字段。
  结果里的 `source` 记录 profileId/revision/modelId/协议/思考/端点 host（无密钥），失败不伪造来源。
- 新增模型发现（GET models URL）与响应测试（固定小型无私密 JSON 请求）异步可取消作业，
  与分析复用 poll/cancel/result/release，但 `jobType=probe` 不能提交为计划；探针有独立短超时
  （默认 30s），不改变正式分析的“无总超时 + 120 秒提醒”策略。
- 模型页：连接列表/新增/编辑/删除/设为默认、官方预设与自定义连接、基础地址与高级完整端点、
  Bearer/无认证、API Key 只写不读（已配置状态/替换/删除）、刷新模型列表、手动模型 ID、
  思考开关与强度、JSON 模式，以及获取列表/测试响应（明确提示会消耗少量额度、不使用当前文件）。
- 会话可单独选择后续请求模型（切换本身不生成计划）；全局默认只影响新会话。新版本记录
  `modelSource`，旧版本与旧会话缺来源时显示「来源未知」。

### 3. 其它设置页
- 通用：跟随系统/浅色/深色（亮暗两套调色板覆盖原硬编码浅色）、字号 0.85–1.30（整个界面
  缩放并带预览）、默认依赖视图、已完成任务显示（只影响任务清单，不影响图与计数）、发送方式。
- 快捷键：列出并注册 Ctrl+Enter 发送、Ctrl+N 新会话、Ctrl+, 设置、Ctrl+O 添加文件、Esc 关闭
  顶层浮层；输入法合成中回车不发送；本期不做任意重映射。
- 通知：应用内完成/失败提醒开关；120 秒「继续等待/取消」独立于通知静音，系统通知未实现
  因而不提供开关。
- 存储：显示实际目录/来源/持久化状态/大小，打开目录；无密钥单 JSON 备份（含会话、版本、
  完成状态、偏好与连接，排除密钥）；恢复先校验（结构/schema/大小/ID 冲突/分析中/未保存草稿）
  再暂存提交，失败回滚并保留原数据与 `.bak`；缓存清理只删应用自有 `<数据目录>/cache`
  中列出的缓存文件（有互斥锁，不按扩展名扫描用户目录），不删历史、附件、原文件。
- 关于：真实版本、许可证说明、帮助（打开程序目录 README）、脱敏诊断复制；无更新后端时
  明确「更新服务未配置」，不模拟检查成功。

### 4. 验收缺陷修复（2026-10-18）

- **删除连接协议**：`SettingsController._payload()` 现在发送 `deletedProfileIds`，`save()` 把
  暂存删除计为变更，保存成功后才清空；`validateDraft()` 要求“有连接必有默认、默认指向存在项、
  无连接则默认必须为空”。删除默认连接时 UI 提示显式重选，不会自动换供应商；`FakeSettingsBridge`
  复刻 C 的“基线→删除→合并”语义，并新增 3 项真实 DLL 删除契约测试。
- **会话模型绑定**：新增 `resolveSelectionForRequest()`；失效的显式绑定（删除/修订变化）明确
  阻止发送且不调用 `analyzeAsync`，不再回退全局默认；新会话在创建时绑定当时的默认选择；旧会话
  无绑定时一次性迁移并提示，之后不再随全局默认漂移；旧版本 `modelSource` 不被改写。
- **认证目标按最终 URL**：同一连接的 chat/models 必须同 origin（scheme+host+有效端口）；
  保存期拒绝 bearer/apiKeyEnv 的跨源 modelsUrl，运行期（含旧 settings.json、环境变量凭据）
  再按实际请求 URL 校验，跨源不建 job、不发请求、不回退旧密钥；`authMode=none` 允许跨源但
  永不发送 Authorization。跨源拒绝与 HTTPS→HTTP 降级均有 C 测试。
- **凭据命名空间**：凭据目标改为 `TaskScheduler/model/<data-space>/<profileId>`（数据目录
  路径 FNV-1a 64），两个便携副本的同名连接不再共用/覆盖；旧目标读取时复制迁移、删除时两者
  都删。部分成功返回 `partial:true`/`credentialConfigured`/`credentialHost`，Dart 刷新权威状态
  并按警告呈现；未保存/端点已修改时禁止写密钥；凭据立即生效、不随设置窗口取消回滚。
- **模型页一致性**：保存后继续编辑不会用旧 revision 撞冲突，放弃后表单/修订恢复磁盘值，删除
  默认连接有明确提示；探测只针对已保存配置（地址/认证方式未保存时禁用并说明原因）。
- **备份/缓存安全**：恢复暂存移到 `<数据目录>/cache/restore`，缓存清理只删自有缓存文件并与
  恢复互斥；恢复拒绝分析中、设置草稿未保存、同 ID 内容冲突的备份；恢复成功后刷新偏好与
  会话列表（无回调则如实要求重启），部分失败回滚并给出真实结果。
- **验证**：`ts_test_settings` 160 项、`ts_test_probe` 211 项全部通过；CTest 15/15；新增
  `settings_bridge_integration_test.dart`（9 项）用真实 ABI=2 DLL + Dart `HttpServer` 覆盖
  删除、模型/URL 切换、运行中快照、思考参数、探针非计划、跨源凭据、取消、120 秒阈值与失效
  绑定不发请求；Flutter 全量 256 项通过（另有 1 项 opt-in 121 秒用例单独实跑通过）。

### 5. 兼容与验证
- ABI 升至 2：新增 `ts_bridge_create_ex`、`settings_get/save`、`credential_set/delete`、
  `probe_async`；Dart 校验 ABI 并给出明确不匹配提示。旧 `config.json`、旧会话 JSON、
  旧完成状态继续可读；`endpoint_url` 仍按完整 URL 精确使用，不自动拼 `/v1`。
- 实测（真实执行，非推断）：
  - C：`scripts/build_flutter_bridge.ps1 -Clean` exit 0，13 个测试可执行文件全部通过，其中
    `ts_test_settings` 160 项、`ts_test_probe` 211 项（内置 winsock mock HTTP，覆盖请求形状、
    快照隔离、主机换绑拒发旧密钥、跨源凭据、revision 冲突、探针错误分类）；`scripts/build.ps1
    -Clean -Test -StaticChecks` exit 0；CTest 15/15。
  - Dart：`flutter analyze` 0 issue；`flutter test` 256 项通过、1 项 opt-in 跳过（含真实 ABI=2 DLL 的
    `bridge_live_test` 与 `settings_bridge_integration_test`、设置存储/控制器/备份/模型页/
    存储页/小窗口 1.5 倍字号等）。
  - `flutter build windows --release` 成功（见 `docs/SETTINGS_ACCEPTANCE_REPORT.md`）。
- **未验证**：真实 DeepSeek/OpenAI 服务调用（无密钥、不消耗额度），只用本地 mock 验证请求
  形状与错误分类；账户服务与系统通知本期未实现。

---

## [0.0.3] — 2026-10-17 — 界面细节修正

### 1. 左下角用户菜单位置与阴影
- 菜单原先用 `showMenu` + 估算矩形，结果浮在入口上方约 220px 处，还带着一大片投影。
  改为**自己插入 `OverlayEntry`**：左对齐用户入口、底边贴着入口上沿往下 6px 展开，
  `elevation: 0` 去掉阴影，只留一条发丝边框。
- 顺带统一了"无交互"的实现：意见反馈 / 退出登录 用 `IgnorePointer` 包住，
  浅灰文字、无 hover、无点击反馈（旧实现只是 `enabled: false`）。
- 修了一个坐标系 bug：定位原先用 `MediaQuery` 高度，而实际容器是 Overlay；
  两者不一致时菜单会被顶到屏幕外。现在统一用 Overlay 的 RenderBox 尺寸与坐标。

### 2. 树状图：状态不再被裁掉、整图靠左
- **节点高度 60 → 78**（宽度 210 → 220）：标题允许两行、状态行固定占据底部，
  两行标题时"状态 + 工时"不再被节点下边缘裁掉（`test/widget/ui_polish2_test.dart` 断言
  节点内所有文字都在节点矩形内）。
- **自动适应同时判断宽/高溢出**：竖向布局容易变高，之前只看宽度会漏判。
- **跳转不再居中整张图**：`_reveal` 改为"最小滚动"——只有当目标节点跑出可视区才平移，
  之前是把它强行移到视口中心，导致整张图看起来被推到中间。

### 3. 文件选择支持多选
- C 侧：`ts_bridge_pick_file` 加 `OFN_ALLOWMULTISELECT`，缓冲扩到 16K 宽字符。
- 多选时系统返回的是"目录 + 各文件名"的 NUL 序列，新增 `src/bridge/ts_file_list.c`
  把它还原成"每行一条完整路径"（单选原样返回）。
  纯逻辑单独成编译单元，新增 `tests/test_file_list.c`（13 项：单选/多选/尾部分隔符/
  中文路径/空输入/参数保护），全部通过。
- Dart 侧：`pickTextFiles()` 返回路径列表，`_addFile` 逐个添加并汇总结果
  （部分失败不影响已成功的文件，提示形如"已添加 2 个，1 个失败：xxx：不是 UTF-8"）。
- 已在打包后的 exe 里实测：对话框是系统多选样式（列表 + 名称/修改日期/类型），
  标题为"添加文本文件（TXT / MD，可多选）"。

### 4. 任务清单复选框居中
- 任务行由 `CrossAxisAlignment.start` 改为 `center`：两行标题时复选框不再贴着行顶，
  而是相对整行垂直居中（`test/widget/ui_polish2_test.dart` 断言偏差 < 6px）。

### 5. 全局字体改为微软雅黑
- `buildAppTheme()` 设置 `fontFamily: 'Microsoft YaHei'`，回退顺序
  `Microsoft YaHei UI → Segoe UI → SimSun`，并显式应用到 `textTheme`。
- 测试断言 `theme.textTheme.bodyMedium.fontFamily == 'Microsoft YaHei'`。

### 6. 版本号 0.0.3
- `pubspec.yaml` → `0.0.3+3`；`app_info.dart` → `0.0.3`；
  `make_flutter_release.ps1` 默认版本 → `0.0.3`；
  exe 资源版本实测 `FileVersion/ProductVersion = 0.0.3+3`；
  包目录 `dist\TaskScheduler-0.0.3-win64-x64\`（zip 同名）。
- 设置 → 关于 页显示 `TaskScheduler 0.0.3`。

### 验证
- `flutter analyze` 0 问题；`flutter test` **98 项全通过**（新增 `ui_polish2_test.dart` 6 项）；
  `ts_test_bridge` 78 项、`ts_test_file_list` **13 项**全通过。
- `MANIFEST.sha256` 18/18 匹配；密钥仍内联在包内 `config.json`（未打印）。
- 界面截图（用户菜单 / 设置弹窗 / 竖排树状图 / 多选对话框）均来自打包后的 exe 真实点击。

---

## [0.0.2] — 2026-10-17 — Flutter 界面首个可分发包

### 界面修订（第三轮评审）
1. **两条横线对齐**：任务清单与依赖视图的标题行合并进同一条固定高度（44px）的表头行，
   下面只画**一条通栏分隔线**。此前两个面板各自在标题下画线，两条线差几像素、还被分隔条断开。
   实现：`TaskListHeader` 从 `TaskListView` 中拆出，由 `app_shell` 与 `_ChartHeader`
   并排放进 `kPaneHeaderHeight` 行。
2. **树状图改为竖向排布**：层级从上到下（最上面第 1 层=最先执行，最下面=最后执行），
   同一层在同一行内左右并排；连线从父任务**下边**出发、进入子任务**上边**，箭头朝下。
   自动适应改为同时判断宽/高溢出，仍然"先保证字看得清，再容许平移"。
3. **左下角用户功能**：
   - 新增 `UserMenuButton`（头像 + `admin`），点击**向上**弹出菜单：**设置**（可用）、
     **意见反馈**、**退出登录**（浅灰、`enabled: false`，无任何交互反馈）；
   - 没有登录系统：只有一个本地账户名 `admin`，仅作为设置入口；
   - 新增 `SettingsDialog`：**居中的模态弹窗**，左栏 7 项
     账户安全 / 通用 / 模型 / 快捷键 / 通知 / 存储 / 关于；
     只有「关于」有内容（版本信息 + 检查更新、帮助 + 查看帮助、运行信息、协议链接、版权），
     其余页面为预设占位（明确写“尚未接入”）；
     关于页按钮**只画 UI、接口未做**，点击提示「该功能尚未接入」。
4. **修复左栏未选中项“部分加粗”**：未选中行用 `FontWeight.w500` 时，Windows 会对缺少
   中粗字重的中文做**伪粗体合成**，同一行里有些字粗有些字细。会话标题改为
   选中 `w600` / 未选中 `w400`；状态小标签也改用 `w400`。
5. **修复设置弹窗图标缺失**（自查发现）：release 构建的 icon tree-shaking 丢掉了
   5 个左栏图标字形，界面上只剩空白。构建脚本改为
   `flutter build windows --release --no-tree-shake-icons`（包体 +约 0.5 MB）。
   新增 `test/widget/settings_rail_test.dart` 守住“每一项都有图标”。

### 修复：全新会话下“添加文本文件”必然失败（用户提供 `<user-file>` 复现）
- 现象：点「+」选中文件后底部弹出「无法添加该文件」，文件没有被加入。
- 定位：该文件是合法 UTF-8（3817 字节），读取本身没问题。真正原因是
  **全新安装时没有任何会话**（`conversation == null`），`addTextFile()` 在第一步就
  `return false` 且**没有设置错误信息**，于是界面只能显示兜底文案。
  同理，此时在输入框里打字也只会停在 TextField 里（`updateDraft` 直接返回），发送按钮永远不可用。
- 修复（`state/app_controller.dart`）：
  - 新增 `ensureConversation()`：无会话时按需创建，并做了并发去重（连续输入不会创建多个会话）；
  - `addTextFile()` / `updateDraft()` / `startAnalysis()` 都先走它，新装即可直接添加文件、打字、发送；
  - 读取文件改为先读字节再判定：UTF-8 BOM 自动剥离、UTF-16 明确提示另存为 UTF-8、
    非 UTF-8（GBK/ANSI）给出针对性提示、空文件/超限/不支持的扩展名各有独立文案，
    不再出现“无法添加该文件”这种无信息兜底；
    被拒绝的扩展名不会留下空会话。
- 新增 `test/file_add_test.dart`（9 例，使用**真实文件与真实存储**）：
  其中一例直接用用户报错的 `<user-file>` 断言可添加成功。

### 界面（按评审意见）
- **去掉顶部报错条**：数据目录回退不再提示；`StorageRoot.notice` 现在只在整个磁盘都
  不可写（本次运行不保存历史）时返回内容。
- **默认数据目录改为程序目录**：`<exe>\TaskSchedulerData`（便携），
  `%LOCALAPPDATA%` 等只作为只读安装时的回退。
- **删除左下角提示**：去掉 `StorageFooter`（“历史与会话保存在…/原始文件可以移动或删除…”），
  原位换成无内容的 `SidebarBlankBand`，仅保留宽度与背景以保证底部带对齐。
- **修正背景色不一致**：任务清单列与图表列现在同为白色（此前清单列透出 Scaffold 灰底，
  两块看起来像不同面板）；`Scaffold` 底色改为白色，分隔条改为 1px 描边，
  只有左侧会话栏保留淡灰底色。
- 测试新增/调整：`test/widget/composer_test.dart` 增补底部带对齐断言；
  `test/storage_root_test.dart` 改为断言“便携目录优先”与“回退不产生提示”。

### 交互与布局修订（上一轮）
- **输入区重做**（`ui/composer.dart`）：
  - 选中的文件显示在输入框**上方**，用蓝色链接样式（文件图标 + 名称 + 可点击移除）；
  - 添加文件的「+」在输入框**内部左下角**，发送箭头在**内部右下角**；
  - 文本区固定 4 行高度（`kComposerTextLines`），超出后在框内滚动。
- **系统文件对话框**：新增 `ts_bridge_pick_file`（comdlg32 `GetOpenFileNameW`），
  替换 Flutter 自绘选择器（`ui/file_picker_dialog.dart` 已删除）；
  对话框以 Flutter 主窗口为 owner，带 TXT/MD 过滤器，取消返回空路径。
  已实测对话框真实弹出、过滤生效、标题正确（`docs/screenshots/07-native-file-dialog.png`）。
- **三带布局对齐**：顶带（会话标题栏 ｜ 摘要标题栏，同高 56）、中带、底带（左空白带 ｜ 输入框，同高），
  底带用 `IntrinsicHeight` 保证严格等高；顶部标题栏改为固定高度单行副标题。

### 修复：受限账户下启动即失败（`PathAccessException ... OS Error 5`）
- 数据目录曾写死为 `%LOCALAPPDATA%\TaskSchedulerFlutter` 且初始化异常被当成致命错误；
  现改为候选 + 探测 + 回退（见上），全部不可写时用内存存储继续运行。
- 启动失败信息按阶段区分（DLL 缺失 / 数据目录问题），不再一律显示“缺少 ts_bridge.dll”。

### 打包后实测
- 受限环境（`%LOCALAPPDATA%` 不可写）：正常启动，数据落在程序目录 `TaskSchedulerData\`，
  界面无任何提示（`docs/screenshots/08-fresh-start.png`）。
- 正常环境（`LOCALAPPDATA` 可写但程序目录优先）：数据落在 `TaskSchedulerData\`。
- 用户菜单、设置弹窗、竖向树状图、通栏横线，全部用打包后的 exe **真实鼠标点击**截图核对
  （`09-user-menu.png` / `10-settings.png` / `01-tree-view.png`）。
  （顺带修正了 `scripts/gui_probe.ps1` 的点击方式：Flutter 的绘制在引擎创建的**子窗口**里，
  往顶层窗口 PostMessage `WM_LBUTTON*` 不会产生点击，改用真实 `mouse_event`。）
- `manifest` 18/18 匹配；`flutter analyze` 0 问题；`flutter test` **92 项全通过**；
  `ts_test_bridge` **78 项全通过**。

### 其他
- 版本号 `0.0.2`（`FileVersion`/`ProductVersion` = `0.0.2+2`，`ProductName` = `TaskScheduler`）。
- 新增 `scripts/make_flutter_release.ps1`：组装 `dist\TaskScheduler-<版本>-win64-x64\` 与同名 zip。
- 新增 `flutter_app/packaging/README-package.txt`、`flutter_app/tool/check_config.dart`。
- 按需求把 API 密钥内联进包内 `config.json`；脚本不打印、不写日志。

---

## [1.1.0] — 2026-10-17 — Flutter 界面迁移（C 内核保持不变）

完整说明见 [MIGRATION.md](MIGRATION.md)。要点：

### 新增
- `flutter_app/`：Flutter 桌面界面（会话历史 / 一句话总结 / 任务清单 + 依赖树状图 + 相对工时甘特 /
  分节详情浮窗 / 待确认·受阻·假设卡片 / 底部附件与输入，无语音入口）。
- `src/bridge/ts_bridge.{h,c}` → `ts_bridge.dll`：Dart FFI 用的窄 ABI。
  异步分析在 C 自己的工作线程里跑，进度用**轮询**拉取，C 从不回调 Dart；
  所有返回缓冲区只能由 `ts_bridge_free` 释放；同一时刻只允许一个活动分析。
- `src/plan_local.{h,c}`：本地计划 JSON（camelCase，携带稳定任务 ID 与完成状态）编解码。
- `src/display.{h,c}`：展示快照生成。界面只吃这份数据，**物理上不含**分数/权重/公式/候选池，
  并负责“未知工时不给确定起止时间”“已完成任务不占剩余时间”。
- `src/export_user.{h,c}`：面向用户的 TXT 导出（不含评分），与结构化诊断导出
  （`ts_export_json`，走 `ts_bridge_export` 的 `format=diag`）明确分开。
- `tests/test_bridge.c`：76 项桥接 ABI 集成断言（异步、轮询、结果复制、释放、取消、迟到结果、关闭顺序）。
- `scripts/build_flutter_bridge.ps1`、`scripts/build_flutter_app.ps1`、`scripts/gui_probe.ps1`、
  `flutter_app/tool/seed_demo_data.dart`（演示会话数据 + 真实 GUI 截图）。
- `docs/screenshots/`：真实进程截图（首屏 / 固定详情 / 备注展开 / 甘特）。

### 变更
- 模型协议 schema `1.0` → `2.0`：新增 `summary`、`previous_task_id`、`notes[]`（含 `task_refs`）。
  `ts_plan_validate` 现在**同时接受** `1.0` 与 `2.x`，旧 fixture / 模拟服务无需改动。
- `ts_analyze_run` 增加带 `plan_context` 的 `ts_analyze_run_ex`（补充要求场景）；旧入口保留为包装。
- `tests/test_validate.c`：schema 用例改为“拒绝 3.x、接受 2.0”。

### 修复（本轮实际发现）
- Dart 侧把 `String.length`（UTF-16 码元）当作 UTF-8 字节数传给 C，中文请求会被截断 → 改用 UTF-8 字节数。
- `ts_bridge_export` 中 `format` 字符串指向已释放的 cJSON，导致诊断导出被写成日常 TXT。
- 界面只监听 `AppController` 而未监听 `TaskInteraction`，导致“点击固定详情”完全不生效。
- 详情浮窗遮挡图表头部（树状图/甘特图切换按钮），现避开头部区域。
- 本地编辑（改名/改步骤）未更新执行签名，会让下次分析误判“内容未变”。

---

## [1.0.1] — 2026-10-16

本轮目标：**定位并修复“鉴权失败：服务端返回 HTTP 401：Authentication Fails(governor)”**。
本轮不重构界面、不增加文档解析、不制作正式安装包。

### 定位到的根因（已证实）

- 本机 `DEEPSEEK_API_KEY` 在**进程 / User / Machine** 三个作用域**均不存在**；
  而配置里 `api_key_env = "DEEPSEEK_API_KEY"`。
- 旧代码在取不到密钥时把 `api_key` 留 `NULL`，而 `Authorization` 头**只在密钥非空时**才追加，
  于是请求**完全不带鉴权头**发给云端 → 服务端返回 401 `Authentication Fails(governor)`。
- 也就是说：这不是“密钥无效”，而是**本地没有可用的密钥，且程序把“取不到密钥”静默当成了“无需鉴权”**。
- 排除项：EXE 确实链接并启用了真实 libcurl；端点与模型名与上一轮成功记录一致
  （模型名错误只会返回 400，不会 401）。

### 修复：请求前鉴权预检（`src/analyze.c`）

- 配置**明确要求**密钥（`api_key_env` 为非空字符串）但当前进程取不到时，
  在**发出请求之前**就报配置错误，**不再发送无鉴权的云端请求**。
- 兼容性保持不变：`api_key_env` 未声明（字段缺失）或**显式写成空串**时，
  仍视为无需鉴权，不发送 `Authorization` —— 无鉴权本地服务照常可用。
- 新增 `ts_config_requires_auth()` 把“未声明”和“显式留空”区分开（`src/config.c` / `src/config.h`）。

### 修复：密钥格式检查（只检测，绝不改写、绝不回显）

- 新增 `ts_config_api_key_format_error()`：检测首尾空白、ASCII 控制字符、被一对引号包住。
- 命中时**在请求前停止**并说明是“哪一类字符问题”，
  **不截断、不替换、不修改密钥内容**，提示中也绝不出现密钥本身。

### 改进：鉴权失败诊断（`src/analyze.c` / `src/model.c`）

- 401/403 现在给出完整且脱敏的诊断：错误分类、HTTP 状态码、**实际配置文件路径**、
  **接口主机**、模型名、**密钥环境变量名**、**当前进程是否读取到密钥**、服务端错误正文、
  以及“本次不会自动重试”的说明。
- 服务端正文先**脱敏**再截断：`Authorization`/`Bearer` 凭证、敏感 JSON 字段值
  （`api_key`/`token`/`password` 等）、形如 `sk-` 或超长的 token 一律替换为占位符；
  HTTP 状态码、错误类型与请求 ID 保留，保证诊断仍然有用。
- 新增 `ts_model_sanitize_endpoint()`：端点摘要丢弃 userinfo 与查询串
  （避免把 `?api_key=...` 之类的敏感参数写进提示或导出）。
- 新增 `ts_model_diag_redact()`：诊断文本脱敏（就地）。
- `TsConfig` 新增 `config_path`（`src/config.c` / `src/config.h`），
  JSON 导出中新增 `config_path`（仍**不写入密钥**）。

### 修复：非交互验收模式在失败时静默挂起（`src/gui_win32.c`）

- 之前 `--input/--export` 模式下若分析失败，窗口会**一直开着且什么都不打印**（实测挂起 60 秒以上）。
- 现在失败时打印失败原因并关窗退出（实测 166~291 ms 退出），
  同时保留“失败时绝不生成导出文件”的正确行为。

### 修复：构建脚本编码（`scripts/build.ps1`）

- 本机 `pwsh` 实为 Windows PowerShell 5.1；它对**没有 UTF-8 BOM** 的 `.ps1` 按 ANSI 解析，
  导致脚本里的中文注释直接引发语法错误。
- 为 `scripts/build.ps1` 与新增的 `tests/run_auth_http_tests.ps1` 补上 UTF-8 BOM。

### 新增测试

- `tests/test_auth_offline.c` → `ts_test_auth_offline`（32 项断言，纯离线，已全部通过）：
  配置加载、是否需要鉴权、密钥格式检查、端点摘要脱敏、诊断文本脱敏。
- `tests/test_http_auth.c` → `ts_test_http_auth`（10 个场景 / 56 项断言，已全部通过）：
  密钥缺失/为空/格式异常时**不发请求**、无鉴权本地服务可用、
  **恰好一个** `Authorization: Bearer` 头、401/403 不重试且诊断脱敏、取消与正常请求回归。
  **全部使用测试自己构造的虚构密钥，绝不读取真实 `DEEPSEEK_API_KEY`。**
- `tests/mock_server.py`：请求旁路记录新增 `auth_header_count` 与
  `auth_bearer_shape_ok`（**只记数量与布尔值，绝不记录密钥值**）。
- `tests/run_auth_http_tests.ps1`：一键运行鉴权集成测试。
- `scripts/build.ps1 -Test` 的测试列表加入 `ts_test_auth_offline`。

### 文档

- 新增 `TODO.md`：记录**本轮不实施**的待办需求（PDF/Word/PPT 支持、
  左栏任务清单 + 右栏树状依赖视图/甘特图、正式安装包），含实施前必须评估的问题清单。
- `VERIFICATION.md`：新增 §3.3b 鉴权行为矩阵；
  §3.5 标注**本轮真实云端验收未执行**（本机无密钥），保留上一轮成功记录作对照。

### 修复：思考模式下输出被截断（finish_reason=length）

**根因（实测数据支持，非推测）**：思考模式下**思考 token 与正文共用 `max_tokens` 预算**，
而配置里硬编码了 `max_output_tokens: 8000`（代码总是发送 `max_tokens`）。
用 843 字节材料 + `reasoning_effort: high` 实测一次调用：
输入 1237 token、输出 6688 token，**其中思考占 4607 token（约 69%）**，
留给 JSON 正文的只有约 2080 —— 稍复杂的材料必然撞上 8000 的天花板。
官方文档同时确认：不发送 `max_tokens` 时服务端按模式取默认
（非思考 8K / 思考 64K / `reasoning_effort=max` 时 128K），上限 384K。

- **`max_tokens` 改为“只在显式给出正数时才发送”**（`src/prompt.c`）。
  默认 `max_output_tokens` 改为 **0 = 不发送**（`src/config.h`），
  由服务端按思考模式给默认 64K，比我们自己猜一个数字更稳。
- 校验规则随之调整：`max_output_tokens` 只能为 **0 或 [1, 393216]**（官方上限 384K），
  不再接受原先宽松的 1,000,000（`src/config.c`）。
- **新增 token 用量采集**（`src/model.c`）：解析 `usage` 段，含
  `prompt_tokens` / `completion_tokens` / **`completion_tokens_details.reasoning_tokens`** /
  `total_tokens`。此前这些字段被直接丢弃，导致只能靠猜。
- **截断报错现在带数字**：从“可能达到 max_tokens”改为
  “输出共 N token，其中思考 M token；输入 K token。思考 token 与正文共用 max_tokens 预算，
  请提高 max_output_tokens（或减少输入）”。
- **修复“无效的修复重试”**：此前截断后的第二次调用仍带同一个 `max_tokens`、
  提示词反而更长，等于必然再截断一次。现在截断场景会在修复提示词里附加
  **精简表达**要求（`steps` 压到 2~4 步、各类 `*_reason` 一句话、不复述材料原文），
  结构完整性要求不变（`src/prompt.c` 的 `truncated` 参数）。
- **导出 JSON 新增 `token_usage` 段**：`prompt_tokens` / `completion_tokens` /
  `reasoning_tokens` / `total_tokens` / `reasoning_effort` / `max_tokens_sent` /
  `attempts` / `truncated`。不含任何敏感内容（只有计数）。
  新增 `ts_export_json_usage` 与 `ts_export_plan_usage`；
  原有的 `ts_export_json` / `ts_export_plan` 保持原签名不变（内部转调）。

**实测结果**：同一份材料、`reasoning_effort: high`、`max_output_tokens: 0`，
一次调用完成，**不再截断**，7 个任务、顺序违规 0 项，耗时约 34~41 秒。

### 新增：配置内联 API Key（本轮新支持）

- 此前密钥**只能**来自环境变量（`api_key_env`），配置文件里没有可填密钥的字段。
  现在配置新增可选的 **`api_key`** 字段，优先级高于 `api_key_env`：
  填了就优先用配置里的值；留空或缺失则回退到环境变量。
- 本地无鉴权服务的兼容性**未变**：两者都未提供时仍视为无需鉴权，不发 `Authorization`。
- 诊断与 JSON 导出新增 `api_key_source`（`config_inline` / `env` / `none`），
  只报告**来源**，绝不写密钥内容；请求前预检的提示也同时给出两种设置方式。
- **安全提示（重要）**：内联密钥会把**明文密钥**写在 `config.json` 里。
  该文件可能被误提交到版本库、被随发布包分发、或被同机其它账户读取。
  建议：仅在“本机自用且接受风险”时使用，并收紧该文件的读取权限；
  共享/生产环境请改用 `api_key_env`。
  （本轮尝试自动收紧该文件 ACL 被沙箱拒绝，未能由代理完成，需用户手动处理。）

### 核实：可用的模型名（来自服务端原文，非文档推测）

- 用真实请求探测 `deepseek-v4.1-flash`，服务端返回 **HTTP 400** 并明确列出：
  > The supported API model names are **deepseek-flash, deepseek-v4-pro**,
  > but you passed deepseek-v4.1-flash.
- 因此 `deepseek-v4.1-flash` **不存在**，不能写入配置。
- 分别用 `deepseek-flash` 与 `deepseek-v4-pro` 配 `reasoning_effort: high`
  发最小请求，**两者均 HTTP 200 成功**（约 1.0s / 1.5s）。
- 最终配置采用 **`model: deepseek-flash` + `reasoning_effort: high`**
  （最快的受支持模型；`deepseek-v4-pro` 可用但更慢）。
- **模型名以服务端返回为准，不要凭推测填写**；填错只会得到 400，不是 401。

### 验证：内联密钥 + high 推理的真实端到端（已通过）

- 用**打包后的发布包 EXE** + 发布包内 `config.json`（内联密钥），
  **在环境变量 `DEEPSEEK_API_KEY` 完全不存在的前提下**实测成功：
  `api_key_source=config_inline`、`model=deepseek-flash`、`reasoning_effort=high`，
  7 个任务，耗时约 **34 秒**（对比 `none` 的约 8~9 秒）。
- 推荐顺序复算：**违规 0 项**；两条多前置边 `T5<-[T3,T4]`、`T6<-[T2,T5]` 完整保留。
- 导出中**不含** `sk-` 字面量、不含密钥任何片段（全仓库扫描确认：
  密钥仅存在于两个 `config.json`，其余文件均无）。
- `reasoning_effort: high` 的观察：紧迫性/影响力评分区分度更好（关键路径任务给到 5），
  且对材料没写的外部条件更保守（判为“待确认”而不是编造“受阻”）；
  代价是耗时约为 `none` 的 3~4 倍。

### 新增：便于设置密钥的启动脚本

- `scripts/run_with_key_env.ps1`：从命令行启动 GUI，并把 `DEEPSEEK_API_KEY`
  （或 `-KeyEnv` 指定的变量）显式读进**当前进程**再启动 exe，
  绕开“通过 `setx` 设置后、已打开的父进程没有新变量，导致双击 exe 读不到密钥”的坑。
  密钥只经**进程环境继承**传递，**不作为命令行参数**（避免出现在进程列表中），
  脚本本身也**不打印密钥内容**，只报告长度与格式是否可疑。
  密钥缺失时给出一次性设置命令并以退出码 3 结束（不启动程序）。

### 验证：真实 DeepSeek 云端端到端调用（已通过）

- 提供本机密钥后重跑，修复后的 1.0.1 EXE 成功完成：
  输入 → 请求构造 → HTTP → 正文提取 → JSON 解析 → 业务校验 → 排序 → JSON 导出，
  耗时约 8.2 秒。
- 用“内部报销审批系统移动端”样例（843 字节 / 7 项需求）验证：
  `T5←[T3,T4]`、`T6←[T2,T5]` 等**多前置被完整保留**，未退化为单父节点；
  逐一复算推荐顺序，**每个任务的全部前置都排在它之前（违规 0 项）**。
- 导出中**不含** `sk-` 字面量，也不含密钥任何片段。
- 该结果同时消除了本轮 401 的疑点：同一端点、同一模型调用成功，
  证明 401 与端点、模型名、请求构造无关，只与“本地当时没有密钥”有关。
- 证据文件：发布目录内 `CLOUD-ACCEPTANCE.txt`。

### 尚未完成

- 无（本轮范围内的代码修复、测试与真实云端验收均已完成）。
- 提醒：测试期间使用的密钥曾出现在对话中，**建议在 platform.deepseek.com 轮换**。

---

## [1.0.0] — 2026-10-15

本轮目标：**真实依赖构建 → 本地接口测试 → 云端接入 → 端到端验收 → 打包**。

### 新增：真实依赖（取代此前的声明桩）

- 引入 **cJSON v1.7.18**（逐字节使用上游 `cJSON.c`/`cJSON.h`）。
- 引入 **libcurl 8.23.0**（curl.se 官方 Windows x64 预编译包）：
  官方头文件、官方 `libcurl-x64.dll`、由官方 `.def` 用 MSVC `lib.exe` 生成的
  `libcurl.lib` 导入库。
- 随包引入 **TLS 根证书包** `third_party/curl/bin/cacert.pem`（curl.se 官方
  `curl-ca-bundle.crt`）。
- `scripts/fetch_deps.ps1` 重写：可重放获取上述依赖，支持内置 Python/Node/curl
  三种下载器（应对本机 schannel 出口受限），并生成 `third_party/DEPENDENCIES.txt`
  记录每个文件的字节数与 SHA-256。
- 新增 `scripts/build.ps1`：独立构建目录、真实依赖检查、可选跑测试与静态校验，
  并把编译器/架构/命令写入 `BUILD-INFO.txt`。

### 新增：TLS 根证书包支持（真实云端的必要前提）

- 配置新增 `ca_bundle_path`；新增 `src/model.c` 的证书包解析
  （配置 → `CURL_CA_BUNDLE`/`SSL_CERT_FILE` → exe 同目录 `cacert.pem`）。
- 找不到证书包时**明确报错**（`TS_MODEL_ERR_TLS`，提示放哪个文件），
  **绝不**通过 `CURLOPT_SSL_VERIFYPEER=0` 绕过校验。
- 构建时把 `cacert.pem` 复制到可执行文件目录。

### 新增：云端请求参数与官方文档对齐

- 配置新增 `reasoning_effort`（`none`/`low`/`high`/`max`，或 `null` = 不发送）。
  默认 `"none"`：官方文档说明 JSON 输出模式下思考模式可能让 `content` 被部分截断，
  且思考 token 会占用 `max_tokens`。
- `config.example.json` 按**当前官方文档**更新：
  `endpoint_url` = `https://api.deepseek.com/chat/completions`、
  `model` = `deepseek-flash`（旧值 `deepseek-chat` 已不在官方可选模型列表中）、
  `max_output_tokens` 提到 8000。

### 新增：非交互验收入口（便于自动化端到端验收）

- `TaskScheduler.exe --input <UTF-8 文本> --export <输出路径>`：
  启动即加载材料、分析、导出并退出（`--export` 按扩展名决定 TXT/JSON）。
  交互式使用不受影响。
- 新增 `ts_gui_run_ex()`；新增自定义消息 `TS_WM_AUTOSTART`。

### 新增：测试与验收工具

| 文件 | 作用 |
| --- | --- |
| `tests/test_model.c` | 响应外壳解析、`Retry-After` 解析、可重试状态码、取消语义（74 断言） |
| `tests/test_plan.c` | 真实 cJSON 下的必需字段/类型/取值拒绝路径（53 断言） |
| `tests/test_export_json.c` | JSON 导出运行期输出、得分等式、**不含密钥**（81 断言） |
| `tests/test_model_tls.c` | 真实 HTTPS/TLS 传输层（3 断言，需联网） |
| `tests/test_http_integration.c` | 本地模拟服务驱动的 HTTP 集成测试（29 场景 / 144 断言） |
| `tests/test_gui_accept.c` | 真实窗口 + 消息循环的 GUI 验收（32 断言） |
| `tests/mock_server.py` | 仅测试用的本地 OpenAI 兼容模拟服务（只监听回环） |
| `tests/run_http_tests.ps1` | 启动模拟服务并运行 HTTP 集成测试（结束后关闭服务） |
| `tests/gen_mock_responses.py` | 生成 HTTP 测试夹具（一次性，运行时不依赖） |
| `tests/run_business_samples.ps1` | 三类业务样例的端到端分析（A/B/C） |
| `tests/check_sample_result.py` | 只做“可确定验证”的结构与约束检查 |
| `scripts/make_release.ps1` | 生成便携 ZIP、许可证、清单与 SHA-256，并做打包前自检 |

### 修复：本轮发现并修掉的真实缺陷

1. **`analyze.c`：重试成功后诊断不记录“发生过重试”**
   现象：第一次 503、第二次成功的请求，`diag.network_retried` 仍为 0，
   服务端收到两次请求而诊断只显示一次成功调用，无法解释。
   修复：在“决定重试”处即置位，而不是等重试再次失败才置位。
   由 `ts_test_http` 的 `retry_then_success` 场景发现。

2. **`gui_win32.c`：非交互模式在 `WM_CREATE` 里启动分析导致通知丢失**
   现象：`--input/--export` 启动后分析其实跑完，界面永远不知道，进程挂起。
   根因：`ts_gui_run_ex` 是在 `CreateWindowExW` 返回后才把通知回调绑定到窗口句柄，
   而 `WM_CREATE` 发生在 `CreateWindowExW` 内部，后台线程的
   开始/进度/完成通知全部丢弃。
   修复：`WM_CREATE` 只发 `TS_WM_AUTOSTART`，等窗口创建完、回调绑定好再启动分析。

3. **`gui_win32.c`：`--export` 忽略扩展名，`.json` 被写成带 BOM 的 TXT**
   现象：`--export 分析结果.json` 产出的却是 TXT 内容且带 BOM，无法被 JSON 解析器读取。
   修复：非交互模式按扩展名判定格式（`.json` → JSON），与
   `ts_export_format_from_path` 的规则一致；交互模式仍按保存对话框的类型下拉框。

### 修复与校核（沿用上一轮，本轮以真实依赖复验）

- libcurl 初始化使用不写 `*Context` 的回调返回值写法（`InitOnce` 低位保留位）。
- 模型必需字段（`depends_on`/`preconditions`/`steps`/`estimated_hours`/…）缺失即协议错误。
- 取消是终态：结果到达时已取消则不采纳。
- 剩余关键链排除已完成任务。
- 文件大小上限在分配缓冲之前按文件大小拒绝。
- 排序解释写出实际权重与 `10×C/7×R/3×W`，与实际计算一致。
- 评分路径的分配失败全部检查。
- `Retry-After` 优先于默认退避，等待可取消，且只消耗同一份额外调用预算。

### 文档

- `VERIFICATION.md` 重写：区分**实测通过 / 失败 / 未执行**，并写明环境与复现命令。
- `README.md` 更新：真实依赖获取、构建、CA 证书包、模型切换、已知限制。
- 新增 `CHANGELOG.md`（本文件）与 `third_party/DEPENDENCIES.txt`（依赖清单与哈希）。
- `third_party/README.md` 重写：说明哪些是上游真实文件、导入库如何生成、
  DLL 的系统依赖已核实。

---

## 更早（2026-10 上旬，本轮之前）

- 阶段 1–7：设计文档、配置/输入/运行时、JSON 解析与业务校验、依赖图与调度、
  提示词与 libcurl multi 通信、Win32 GUI、TXT/JSON 导出。
- 外部独立校核提出的 8 项发现全部修复（2 项阻断级），详见 `VERIFICATION.md`。
- MSVC `/analyze` 静态分析：本项目源码告警清零；修掉 2 个真实缺陷。

