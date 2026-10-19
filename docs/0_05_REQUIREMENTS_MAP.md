# TaskScheduler 0.05 需求 → 文件/测试映射

- 产品版本：**0.05**；构建/pubspec：**0.0.5+5**（`kAppVersion='0.05'`，`kAppVersionSemver='0.0.5'`）
- 更新日期：2026-10-18
- 状态说明：`通过` = 有真实运行证据；`部分` = 已实现但验收不完整；`未执行` = 未做，不冒充通过。

## 用户约束

| ID | 需求 | 实现/测试 | 状态 |
|---|---|---|---|
| U1 | 模型配置字段/默认值/校验/认证/发现/测试/思考/JSON/凭据/端点规则不变 | `settings_model_page.dart`、`settings_controller.dart`、C `profile.c`/`ts_bridge.c`；`settings_model_page_test.dart` 26 项、`settings_bridge_integration_test.dart`、C `ts_test_settings/probe` | 通过（本地/mock） |
| U2 | 模型页只删除开发汇报文案，保留配置说明 | `settings_model_page.dart` 文案；页测试断言“测试会消耗额度/完整端点”仍在 | 通过 |
| U3 | 输入框折叠态固定 4 行/原高度不变，仅手动展开 | `composer.dart`（`_expanded`、同 TextField、`kComposerTextLines`）；`composer_test.dart` 固定行数 + 展开/收起 | 通过 |
| U4 | `admin`、账户入口/未接入位置保留 | `app_info.dart`、`user_menu.dart`、`settings_account_page.dart`；页面测试 | 通过 |
| U5 | 检查更新按钮保留、真正禁用灰色、无网络 | `settings_about_page.dart` + `SettingsOutlinedButton(onPressed:null)`；`settings_pages_test`/`ui_polish_test` 断言 onPressed==null | 通过 |

## 会话生命周期与搜索

| ID | 需求 | 实现/测试 | 状态 |
|---|---|---|---|
| S1 | 右键/⋯/Shift+F10/菜单键共用菜单，绑定目标 id | `history_panel.dart`、`app_shell.dart`；`session_menu_test.dart` 验证非当前行菜单 | 通过（右键菜单在桌面截图，键盘菜单只按当前会话） |
| S2 | 重命名独立于自动标题；清空恢复 | `ConversationMeta`、`renameConversation`；`session_lifecycle_test`、`session_menu_test` | 通过 |
| S3 | 置顶/普通分区、稳定排序、不因视图切换乱序 | `ConversationMeta.pinOrder`、`SessionStore` 排序、`setChartMode` 不改 activity；`session_lifecycle_test` | 通过 |
| S4 | 搜索标题+归档、最近删除独立搜索、清空/无结果/键盘 | `searchSummaries`、侧栏搜索/全部/归档/回收；`session_menu_test`、桌面 `01b` | 通过（键盘选中未单独验收） |
| S5 | 归档保留数据、恢复保留置顶状态 | metadata + `restoreDeleted`；`session_lifecycle_test` | 通过 |
| S6 | 删除默认移入回收、撤销/恢复、永久删除确认 | `moveToTrash/restoreFromTrash/permanentlyDelete` + UI 菜单/确认；`session_lifecycle_test`、`session_menu_test` | 通过 |
| S7 | 分析中归档/删除先确认并取消，迟到结果不复活 | `cancelRunFor`、`_commitResult` 检查 meta；`settings_bridge_integration_test` 失效绑定、`session_lifecycle_test` 生命周期 | 通过（迟到结果 0 版本由集成测试覆盖） |
| S8 | 移除当前会话打开相邻/空白；连续新建复用空会话 | `_openAdjacentTo`、`createConversation(reuseBlank)`；`session_lifecycle_test`、`app_controller_test` | 通过 |
| P1 | 旧格式兼容、未来 schema 不覆盖 | `Conversation/Summary.fromJson` 默认值；`SessionStore` schema 检查；`session_lifecycle_test`、`session_store_test` | 通过 |
| P2 | 自定义标题/置顶/归档/删除时间，详情与索引一致 | `ConversationMeta`、`ConversationSummary.meta`；序列化测试 | 通过 |
| P3 | 按会话/存储串行化，统一并发策略 | 生命周期写入在 `_saveLifecycle` 内串行；**未实现通用按 id 锁/索引全局锁** | 部分（单 isolate + await 顺序，未做并发故障注入） |
| P4 | 永久删除主文件/.bak/.tmp/索引/无引用附件 | `SessionStore.deleteConversation`、`pruneAttachments`、tombstones；`session_lifecycle_test` | 通过 |
| P5 | 操作日志/崩溃恢复，每中断点 | `operations.json` + `recoverPendingOperations` 仅覆盖永久删除；归档/回收/重命名没有日志 | 部分 |
| P6 | 写入失败明确；重启能恢复/解释 | `_saveLifecycle` 抛错显示；`SessionFormatException`；未做每个 await 后崩溃注入 | 部分 |

## UI / 主界面 / 任务

| ID | 需求 | 实现/测试 | 状态 |
|---|---|---|---|
| M1 | “树状图”→“依赖图”，兼容 wire `tree` | `app_shell.dart` 标签；`app_shell_test` | 通过 |
| M2 | 依赖图文字/连线/选中对比度，保留全部边 | `dag_graph.dart` 连线 `textFaint`/2.4px；节点保留全部 predecessors | 通过（视觉对比未做像素量化） |
| M3 | 缩放百分比/实际大小/适应全部/定位当前 | `dag_graph.dart` 工具栏 + `dag-zoom-percent`；桌面 `01-main` 显示 100% 与按钮 | 通过（定位按钮桌面未点击） |
| M4 | 分隔线悬停提示、保存宽度、窄窗限制/恢复 | `_Splitter` Tooltip + 双击恢复；宽度仅内存，未持久化 | 部分 |
| M5 | 任务搜索/全部/可开始/受阻/已完成、隐藏数量、关联临时显示 | `task_list.dart`；`app_shell_test`；桌面 `01d` | 通过（键盘选中任务未单独验收） |
| M6 | 折叠态不变；展开编辑器复用文本/选择/附件/发送；Esc/小窗 | `composer.dart` 同 TextField + `expandedHeight`；`composer_test`；桌面 `01e` | 通过 |
| M7 | “待前置”→“等待前置任务”，“层级”辅助 | C `display.c/export.c/gui_win32.c` 文案；任务列表显示层级 | 通过（C 测试/构建） |
| M8 | 甘特明确相对累计工时/单人串行，不伪装日历/并行 | `gantt_chart.dart` 常驻横幅 | 通过 |
| M9 | 日期选择器+手输/清空/严格校验；小时/分钟；前置搜索+成环 | `task_edit_dialog.dart`；`task_edit_dialog_test` | 通过 |
| M10 | 完成/编辑/归档可撤销，校验版本/修订；文本框 Ctrl+Z 保留 | 完成/编辑撤销 `_rememberTaskUndo`；归档/删除撤销入口仅最近一次；Ctrl+Z 在保护列表 | 部分（无撤销 UI 自动化；归档撤销非 snackbar） |
| UI1 | 统一按钮/图标/焦点/语义/危险色/空状态 | 已做七项界面优化：共享贝塞尔圆角、微软雅黑、分段动画、浮窗关闭/锚点；细节见 [UI_POLISH_ACCEPTANCE_REPORT](UI_POLISH_ACCEPTANCE_REPORT.md) | 通过（Switch 轨道保留圆形语义） |

## 快捷键

| ID | 需求 | 实现/测试 | 状态 |
|---|---|---|---|
| K1 | 动作注册表，菜单/Tooltip/设置同源 | `model/shortcuts.dart` + `AppCommands` | 通过 |
| K2 | 自定义/取消/单项/全部恢复/搜索/分组 | `settings_shortcuts_page.dart`；`shortcuts_ui_test` | 通过 |
| K3 | 录制时原动作不执行、可取消、稳定键码 | Recorder `Focus.onKeyEvent`、`KeyChord(keyId+mods)`；`shortcuts_ui_test`、`shortcuts_test` | 通过 |
| K4 | 冲突检测并拒绝 | `findShortcutConflict`；`shortcuts_ui_test` | 通过 |
| K5 | 作用域/弹窗优先/保护复制粘贴与文本撤销/Esc 固定 | `scopesOverlap`、fixed Esc、保护 Ctrl+C/V/X/A/Z/Y；`shortcuts_test` | 通过（作用域只区分 application/composer/dialog） |
| K6 | 发送组合与 Enter 偏好统一，提示同步 | `SendShortcut(sendChord)` + `_sendHint`；`settings_bridge_integration_test` 思考/发送相关、桌面 footer | 通过（自定义发送组合桌面未点击） |
| K7 | 中文输入法 composition 不发送；长按不重复 | `_composing()`；`KeyChord.activator` includeRepeats false；旧测试 | 通过（IME 桌面实机未做） |
| K8 | 新增搜索/定位输入/切换图/侧栏/停止分析 | `AppCommands` + AppShell intents | 通过（桌面只验证原有 5 项） |
| K9 | 损坏配置可恢复、不阻止启动 | `AppPreferences.fromJson` 丢弃非法 chord；`shortcuts_test` | 通过 |

## 历史 / 设置 / 存储 / 通知 / 文件

| ID | 需求 | 实现/测试 | 状态 |
|---|---|---|---|
| H1 | 材料与补充记录，旧数据未知 | `_showMaterials`；消息/附件已有；失败/取消未持久化 | 部分 |
| H2 | 版本差异按稳定 id，旧版本只读 | `version_diff.dart` + `VersionDiffDialog` + summary bar 按钮；`version_diff_test` | 通过（桌面 diff 截图脚本坐标待修） |
| H3 | 导出当前/全部历史，范围明确 | `exportConversation/exportAllHistory` + 菜单；未做桌面点击 | 部分 |
| H4 | 关于页诊断折叠、检查更新灰色 | `ExpansionTile` + disabled button；测试 | 通过 |
| H5 | 只读设置无修改关闭为主；保存/放弃语义一致 | 现有 dialog 逻辑；测试 | 通过 |
| H6 | 长设置页滚动可发现、保存区不截断 | `_pageArea` scroll + footer；`settings_pages_test` 拖动 | 通过 |
| ST1 | 临时目录提示、选择长期位置/迁移、验证复制校验切换、失败保留 | `StorageMigrationService` + 存储页卡片；`storage_migration_test` | 通过（桌面迁移按钮未点击） |
| ST2 | 便携升级迁移、备份含元数据/快捷键/布局（无键） | `AppPreferences.shortcuts`、`Conversation.meta` 进入备份 JSON；备份测试覆盖；布局宽度未持久化 | 部分 |
| N1 | 系统通知完成/失败、权限反馈、点击定位、发布行为 | C `Shell_NotifyIcon` + `ts_bridge_show_notification` + AppShell poll/点击打开；集成测试只验证可调用，**桌面通知显示/点击未验证** | 部分 |
| N2 | 静音语义、120 秒规则不伪造 | 通知页说明；未实现 per-notification mute（依赖 Windows 通知设置） | 部分 |
| F1 | PDF/DOCX/PPTX 文本提取、位置、错误/取消/部分成功 | `document_extractor.dart` + 37 tests；app_controller 集成；C 文件过滤器 | 通过（本地） |
| F2 | 扫描 PDF 明确不支持 OCR；.doc/.ppt 不支持 | 提取器错误分类；测试 | 通过 |
| F3 | 文件大小/损坏/加密/空/重复/取消 | 提取器 + app_controller 重复检查；测试 | 通过 |
| T1 | 10/100/1000 会话、10/100/300 任务性能 | 未执行基准测量 | 未执行 |
| T2 | 真实 Release GUI 全键盘/主题/DPI/字号 | 部分桌面截图；未做 1280×720/100%/200%/纯键盘全流程 | 部分 |

## 关键测试/证据文件

- `flutter_app/test/session_lifecycle_test.dart`（9）
- `flutter_app/test/widget/session_menu_test.dart`（2）
- `flutter_app/test/widget/composer_test.dart`（7）
- `flutter_app/test/widget/task_edit_dialog_test.dart`（3）
- `flutter_app/test/shortcuts_test.dart`（6） + `shortcuts_ui_test.dart`（4）
- `flutter_app/test/storage_migration_test.dart`（3）
- `flutter_app/test/version_diff_test.dart`（3）
- `flutter_app/test/document_extractor_test.dart`（37）
- `docs/acceptance/005/` 桌面截图
- `docs/TASKSCHEDULER_0_05_ACCEPTANCE_REPORT.md` 逐项验收报告

