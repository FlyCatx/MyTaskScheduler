# TaskScheduler 设计文档（阶段 1）

## 1. 需求差异确认（旧版 vs 新版）

| 维度 | 旧版（TaskScheduler.py） | 新版（本实现） |
| --- | --- | --- |
| 语言/界面 | Python + Tkinter | C + Win32 Unicode API + Common Controls |
| 任务来源 | 人工逐条填写 | 选文件/贴文段 → 云端/本地模型自动拆解 |
| 依赖模型 | 单个前序任务（单父） | 多前序 `depends_on[]`，真正的 DAG |
| 排序 | 层内 `urgency*impact/effort` 固定公式 | 五维基础分 + 全局权衡（关键链/解锁/快速见效） |
| 可解释性 | 仅打印得分 | 保存各维度贡献、解锁任务、依据、快照 |
| 超时/取消 | 无 | 120 秒提醒阈值、主动取消、请求代号防迟到覆盖 |
| 模型切换 | 无 | 只改配置（OpenAI 兼容端点），不改业务代码 |
| 输出 | 固定文本 | 建议顺序 + 受阻/待确认分列 + TXT/JSON 导出 |

关键结论：旧版的“前序任务”与“固定公式”被废弃；新版“模型只分析、本地只规划与展示”，
“依赖边 A→B 表示 B 必须在 A 完成后执行”。

## 2. 项目结构

```
TaskScheduler/
├─ CMakeLists.txt
├─ README.md
├─ DESIGN.md
├─ VERIFICATION.md
├─ config.example.json
├─ scripts/
│  └─ fetch_deps.ps1
├─ src/
│  ├─ main.c          (阶段5：Win32 GUI 入口 wWinMain)
│  ├─ types.h/.c      (公共类型与生命周期)
│  ├─ mem.h           (带溢出检查的分配辅助，头文件内联)
│  ├─ text.h/.c       (UTF-8 校验 + UTF-8<->UTF-16 转换)   [小幅新增]
│  ├─ config.h/.c     (JSON 配置 + 环境变量 + 校验)
│  ├─ gui_win32.h/.c  (阶段5：窗口/控件/详情/提示框)
│  ├─ controller.h/.c (阶段5：后台任务/生命周期/请求代号/取消)
│  ├─ input.h/.c      (文件与文段读取、编码、大小、来源编号)
│  ├─ prompt.h/.c     (阶段4：system/user 提示词与请求构造)
│  ├─ model.h/.c      (HTTP 请求、响应外壳解析、正文提取)
│  ├─ analyze.h/.c    (阶段4：分析流程编排：构建→调用→解析→有限修复重试) [小幅新增]
│  ├─ plan.h          (JSON 协议与校验接口)
│  ├─ plan.c          (阶段3：JSON -> TsPlan；用 cJSON)
│  ├─ plan_validate.c (阶段3：业务校验；零 cJSON 依赖，可离线测试)
│  ├─ scheduler.h/.c  (阶段3：依赖图/分层/状态/评分/顺序/解释)
│  ├─ export.h        (导出接口 + 算法版本/协议版本常量)
│  ├─ export.c        (阶段6：UTF-8 TXT 导出；不依赖 cJSON，可离线测试)
│  ├─ export_json.c   (阶段6：JSON 导出 + 格式分派；用 cJSON)
│  ├─ export_internal.h (export.c 与 export_json.c 共享的内部工具)
│  └─ runtime.h/.c    (单调时钟 + 墙钟时间戳 + 线程安全取消状态)
├─ tests/
│  ├─ test_phase2.c            (配置/输入/模拟响应)
│  ├─ test_phase3.c            (调度算法，含后代去重)
│  ├─ test_phase4.c            (分析材料组装)
│  ├─ test_phase6.c            (TXT 导出，真实写文件并读回)
│  ├─ test_validate.c          (计划业务校验)
│  ├─ validate_mock.py / validate_prompt.py / validate_export.py
│  └─ data/sample_utf8.txt
└─ third_party/
   ├─ cJSON.c / cJSON.h   (v1.7.18，官方获取)
   └─ README.md
```

说明：`mem.h`、`text.h/.c` 为小幅合理调整（公共内存与编码工具，供
config/input/export/gui 复用），不增加 GUI 耦合，不引入额外第三方库。

## 3. 数据协议

### 3.1 模型输出 JSON 协议（analyze 结果）

```json
{
  "schema_version": "1.0",
  "tasks": [
    {
      "id": "T1",
      "name": "任务名称",
      "depends_on": ["T0"],
      "preconditions": [
        { "description": "外部条件描述", "status": "met" }
      ],
      "steps": ["步骤1", "步骤2"],
      "urgency": 4,
      "urgency_reason": "紧迫性依据",
      "impact": 5,
      "impact_reason": "影响力依据",
      "estimated_hours": 4.0,
      "estimate_reason": "工时依据",
      "deadline": "2025-03-01",
      "source_refs": ["文件1:段落1"]
    }
  ],
  "assumptions": ["假设..."],
  "questions": ["待确认问题..."],
  "suggested_order": ["T0", "T1"]
}
```

字段语义与约束（解析见 `plan.c`，校验见 `plan_validate.c`）：

**字段完整性（强制）**：下面列出的字段**必须全部出现**；“没有内容”必须显式写成
`[]` 或 `null`。缺失字段一律判为协议错误并触发一次修复请求。

> 为什么必须严格：如果把缺失当成空值，就无法区分“**确实没有**依赖/条件/步骤”与
> “**模型没有分析出来**”。后者会让一个其实被前置约束卡住的任务被错误地判为“可开始”，
> 属于安全性问题。因此 `depends_on`、`preconditions`、`steps`、`source_refs` 都要求显式给出
> （空则 `[]`），`estimated_hours`、`estimate_reason`、`deadline` 要求显式给出（未知则 `null`）。

- `schema_version`：字符串 `"major.minor"`，当前必须为 `1.0`。
- `tasks[].id`：必需，唯一、非空；供 `depends_on` 引用。
- `tasks[].name`：必需，非空。
- `tasks[].depends_on`：**必需数组**，没有前置任务时写 `[]`；元素必须指向已存在任务的 ID；
  禁止自依赖、重复依赖、循环依赖。
- `tasks[].preconditions`：**必需数组**，没有外部条件时写 `[]`；
  元素为 `{ "description": 非空字符串, "status": "met"|"unmet"|"unknown" }`。
- `tasks[].steps`：**必需数组**，无法拆出步骤时写 `[]`。
- `tasks[].urgency` / `tasks[].impact`：必需，1～5 整数。
- `tasks[].urgency_reason` / `tasks[].impact_reason`：必需字符串。
- `tasks[].estimated_hours`：**必需字段**，正数或 `null`（未知）；非法数值被拒绝，
  `null` **绝不**当作 0。
- `tasks[].estimate_reason`：**必需字段**，字符串或 `null`。
- `tasks[].deadline`：**必需字段**，ISO 日期字符串或 `null`（未知）。
- `tasks[].source_refs`：**必需数组**，没有可引用来源时写 `[]`。
- `assumptions` / `questions` / `suggested_order`：可选；
  `suggested_order` 仅作参考，最终顺序由本地算法产生。

### 3.2 请求 JSON 协议（OpenAI 兼容 Chat Completions，阶段 4）

```json
{
  "model": "deepseek-chat",
  "messages": [
    { "role": "system", "content": "…" },
    { "role": "user", "content": "…" }
  ],
  "temperature": 0.2,
  "max_tokens": 4000,
  "stream": false
}
```

`json_mode=true` 时追加 `"response_format": { "type": "json_object" }`。
响应外壳解析只读取 `choices[0].message.content` 与 `usage`。

### 3.3 配置 JSON 协议

见 `config.example.json` 与 `config.h` 默认值。要点：

- `endpoint_url`：**完整** Chat Completions 地址，程序不自动拼接 `/v1`。
- `api_key_env`：保存 Key 的**环境变量名**，绝不把 Key 写进源码/示例/日志。
  无鉴权的本地服务可省略，此时不发送 `Authorization` 头。
- `request_timeout_ms`：`0` = 禁用总超时（云端默认禁用，不通过低速超时变相终止）。
- `connect_timeout_ms`：连接超时（保留合理值）。
- `wait_prompt_ms`：120 秒提醒阈值，仅弹窗提醒，不中断请求。
- `max_retry_attempts`：网络/结构修复共用的额外调用上限（0 或 1）。
- `weights`：五维基础权重，必须 ∈ [0,1] 且和为 1。
- `mock_mode`：`true` 时返回内置模拟响应（用于离线验证）。

## 4. 公共类型（types.h 摘要）

- `TsPrecondStatus`：`TS_PRECOND_UNKNOWN / MET / UNMET`。
- `TsActualStatus`：`TS_ACTUAL_TODO / DONE`（用户维护，模型不得标记完成）。
- `TsTask`：任务全字段 + `has_estimated_hours` 标志 + 用户实际状态。
- `TsPlan`：schema 版本、任务数组、假设、待确认问题、参考顺序。
- 生命周期：`ts_*_init` 置零，`ts_*_free` 递归释放且 NULL 安全，失败后对象仍可安全释放。

## 5. 接口清单（对应需求第十四节）

| 需求接口 | 本实现接口 | 归属 |
| --- | --- | --- |
| load_config() | `ts_config_load()` / `ts_config_validate()` | config |
| read_inputs() | `ts_inputs_add_file()` / `ts_inputs_add_text()` | input |
| build_model_request() | `ts_prompt_build_request()`（阶段4） | prompt |
| call_model() | `ts_model_call(cfg, request, cancel, gen, out)` | model |
| parse_plan() | `ts_plan_parse()`（阶段3） | plan |
| validate_plan() | `ts_plan_validate()`（阶段3） | plan |
| build_schedule() | `ts_schedule_build(plan, sort_cfg)`（阶段3，不改用户状态） | scheduler |
| export_plan() | `ts_export_txt()` / `ts_export_json()` / `ts_export_plan()`（阶段6） | export / export_json |
| —（流程编排） | `ts_analyze_run()`（阶段4，GUI 无关，网络重试与修复共用一次预算） | analyze |

内存/错误约定：调用方拥有入参，被调函数不持有点入参；输出对象由被调函数分配、
调用方用对应 `*_free` 释放；错误返回非 0 并通过 `err` 缓冲区报告；失败后输出对象
仍可安全 `free`。

## 6. 排序算法（本地实现，阶段 3）

- **DAG 校验**：Kahn 算法；发现循环即整体报错，不擅自删边“修好”。
- **分层**：无前置 `level=0`，其余 `level = 1 + max(前置 level)`；层级仅用于展示，
  不强制整层完成。
- **硬约束**：每条依赖边 + 外部条件；`unmet`/`unknown` 条件使任务受阻/待确认，
  并传播到后继（后继不得显示为“当前可执行”）。
- **五维基础分**：`Base = 100*(0.35U + 0.30I + 0.20B + 0.10Q + 0.05D)`
  - `U=(urgency-1)/4`，`I=(impact-1)/4`
  - `B = 去重未完成后代数 / max(1, 集合最大未完成后代数)`
  - `Q = reference_hours/(reference_hours+estimated_hours)`；未知工时 `Q=0.5` 并标记待确认
  - `D = 向后最长依赖边数 / max(1, 集合最大后续依赖边数)`
- **全局分**：`Final = Base + 10C + 7R + 3W`
  - `C` 关键链推进：按**实际未完成状态**逆拓扑计算**剩余**工时链
    `rem(t) = hours(t) + max(rem(直接后继))`。**已完成任务自身不再计工时**
    （但仍沿依赖边向后看，因为它的后继可能尚未完成）；
    按全体“未完成且链完整”者的最大值归一化；链上出现未知工时则不提供确定加分并标记
    “估计不完整”。注意 `C` 不是层数，也不代表单人串行总完成时间。
  - 展示约束：解释里必须写出**实际权重与乘积**，让用户能按等式复算出 `Final`；
    不得写成 `Base = 100×(U+I+B+Q+D)` 这类对不上的等式。
  - `R` 立即解锁：该候选完成后立刻可执行的直接后继数量，按候选集合归一化，全零时 `R=0`。
  - `W = I*Q` 快速见效。
- **生成**：从未完成任务建规划副本，收集“前置已满足且外部条件就绪”的候选，选最高分加入顺序，
  在副本中视为完成，更新候选池重复；受阻/待确认任务单独列出。
- **确定性**：同分依次按紧迫性、影响力、任务 ID 排序；归一化参考集合随当前候选集合重算，
  保证可复现。

## 7. 构建方案

- 编译器：MSVC（Visual Studio 2022/2026，C11 `/std:c11`）；CMake ≥ 3.16。
- 依赖：cJSON v1.7.18（`third_party/`），libcurl 8.x（vcpkg 或官方 Windows 预编译包）。
- 命令：见 `README.md`。未找到 libcurl 时仍可构建，但仅支持 `mock_mode`。

## 8. 默认假设（必要时可调整）

1. `schema_version` 采用字符串 `"1.0"`。
2. 依赖/评分/工时/条件在本地编辑后即时重新校验与排序，不重新调用模型；
   只有重新分析材料才调用模型。
3. 首版不实现资源级调度、上下文切换优化与复杂连线图。
4. 云端默认不设请求总硬超时；仅保留连接超时与响应大小上限。
5. 120 秒为“提醒阈值”，弹窗期间原请求继续，用户不操作/关闭提示框均继续等待。

## 9. GUI 与线程模型（阶段 5）

**职责划分**

- 主线程：窗口、控件、列表、详情、提示框；只有主线程读写控件。
- 工作线程：只运行 `ts_analyze_run()`（提示词/HTTP/解析/调度都在其中），
  不接触任何 GUI 控件。
- `controller`：持有配置、输入、当前计划、调度结果与状态视图；
  管理工作线程、请求代号（generation）、取消与结果发布。

**数据移交规则**

- 工作线程完成后把 `TsAnalyzeResult` 发布到 controller（临界区保护）；
  若其代号已被更新的请求取代（`ts_cancel_gen != gen`），结果被丢弃，防止迟到结果覆盖新结果。
- 通知只通过回调 → `PostMessageW(hwnd, TS_WM_NOTIFY, event, 0)`，
  主线程在消息处理中才读取结果、`adopt_result()` 并刷新界面。
- 分析进行中禁用「添加文件/输入文段/本地编辑」等会与工作线程共享数据的操作，
  避免数据竞争；「取消」始终可用。

**取消与关闭窗口**

- 取消是协作式的：设置 `TsCancel` 标志；libcurl multi 循环每 200ms 轮询一次，
  提示词与解析阶段的循环入口也会检查，因此取消响应及时。
- **取消是终态**：一旦某次请求被取消，即使完整结果已经拿到，也**不采纳**。
  检查点共四处，确保“接收完成 → 结果提交”这段窗口内的取消不会被忽略：
  1. 模型调用返回成功、进入解析之前；
  2. 解析成功、提交计划之前；
  3. 工作线程发布结果之前（`ts_cancel_is_requested`）；
  4. GUI 调用 `ts_controller_adopt_result()` 采纳之前。
  这样“取消与完成竞争”时不会把结果当成成功并覆盖已有计划。
- 重试退避（429 / 网络错误）在等待期间同样可被取消；429 优先遵从服务器的
  `Retry-After`，无提示时使用 500ms 短暂退避，上限 30 秒，且仍只消耗那一次预算。
- 不使用 `TerminateThread`。关闭窗口时若有活动请求：先询问，确认后先取消，
  等待工作线程退出（上限 10 秒）；超时则不释放 controller 而直接退出进程，
  以免工作线程访问已释放内存。

**120 秒提醒**

- 定时器（200ms）刷新状态区并检查阈值；`wait_prompt_ms` 只是提醒阈值，不中断请求。
- 提示框为**非模态**窗口（主窗口保持可用，用户随时可点“取消”）。
- 每个请求代号只提示一次：选择“继续等待”或关闭提示框后不再重复。
- 结果到达时关闭过期提示框，再展示结果。

**本地编辑**

- 编辑任务字段、多前置依赖、外部条件状态、完成状态，全部只在本机
  `ts_plan_validate` → `ts_schedule_build` → `ts_schedule_status` 重算，
  不重新调用模型；依赖非法（自依赖/重复/缺失/循环）会明确报错并保留原有界面数据。

**界面结构**

顶部操作区 / 状态区 / 下一步卡片 / 左侧任务列表 / 右侧详情与关联跳转 /
底部受阻·待确认·受影响·假设与问题；状态一律“颜色 + 文字”双通道表达；
支持按依赖层级分组查看。主视图以顺序列表为主，不把多前置 DAG 强改为单父树。

## 10. 内存与所有权约定

| 规则 | 说明 |
| --- | --- |
| 入参所有权 | 所有函数**不持有**入参指针，也不修改 `const` 入参；返回后调用方可立即释放入参 |
| 出参所有权 | 通过 `char **out` / 结构体出参返回的对象由被调函数分配，**调用方负责释放** |
| 释放函数 | 每类对象都有对应释放函数：`ts_plan_free` / `ts_schedule_result_free` / `ts_status_view_free` / `ts_model_result_free` / `ts_analyze_result_free` / `ts_inputs_free` / `ts_config_free` / `ts_task_free` / `ts_buf_free`；`ts_free()` 等价于 `free()`，对 `NULL` 安全 |
| 错误返回 | 统一：成功返回 `0`，失败返回非 `0`，并通过 `char *err, size_t err_sz` 写出**可读原因**（不做 `assert`/`abort`） |
| 失败后可释放 | 所有“半成品”对象都被初始化为全零状态，因此**失败后对象仍可安全 `*_free`**（例如 `ts_plan_parse` 失败后仍可 `ts_plan_free`） |
| 分配失败 | 所有分配都检查返回值；`mem.h` 提供带溢出检查的 `ts_mul_overflow` / `ts_add_overflow` / `ts_calloc` |
| 字符串缓冲 | `TsBuf`（`mem.h`）所有 append 失败返回非 0，缓冲本身始终以 NUL 结尾且仍可用 |
| GUI/工作线程移交 | 工作线程**只**写 `controller` 内的结果（临界区保护）与进度字符串；**不接触任何控件**。主线程收到 `PostMessage` 后调用 `ts_controller_adopt_result()` 取走结果（所有权移交给 `plan`，`result.plan` 被置零避免重复释放） |
| 迟到结果 | 结果发布前比较请求代号：`ts_cancel_gen(&cancel) != gen` 时**丢弃**，防止旧结果覆盖新结果 |
| 运行期共享数据 | 分析进行中禁用会与工作线程共享数据的操作（添加文件/输入文段/本地编辑）；取消标志与进度字符串用临界区/原子操作保护 |

## 11. 实现状态对照

| 需求条目 | 实现位置 |
| --- | --- |
| 选文件/文段输入、编码与大小检查、来源与段落编号 | `input.c`（`ts_inputs_add_file` / `ts_inputs_add_text` / `ts_inputs_build_material`） |
| JSON 配置、环境变量读 Key、权重校验 | `config.c` |
| 运行时 system/user 提示词、分离用户要求与材料、日期时区 | `prompt.c` |
| 只用 OpenAI 兼容结构、cJSON 构造请求、不自动拼 `/v1`、可省略鉴权 | `prompt.c` / `model.c` |
| 取消、连接超时、TLS 校验、响应大小限制、不设低速超时 | `model.c`（libcurl multi，200ms 轮询取消） |
| 错误分类、有限重试与一次性修复共用预算、取消后不重试 | `model.c`（分类）+ `analyze.c`（预算编排） |
| JSON 合法性、字段类型、必需字段、schema 版本、数量上限 | `plan.c` |
| ID 唯一、依赖存在/自依赖/重复/循环、范围、工时、枚举 | `plan_validate.c` |
| Kahn DAG、层级、硬约束、外部条件传播、完成状态 | `scheduler.c` |
| 五维基础分、全局权衡（C/R/W）、同分稳定排序 | `scheduler.c` |
| 可解释性（贡献、候选快照、解锁、依据、不确定信息） | `scheduler.c`（`TsScheduleStep`）+ `gui_win32.c`（详情展示） |
| 建议顺序、受阻/待确认/受影响分列、不走单父树 | `scheduler.c` + `gui_win32.c` |
| 状态颜色 + 文字、编辑与即时重算、跳转详情、层级分组 | `gui_win32.c` + `controller.c` |
| 120 秒提醒（非模态、不中断、不重复提示、结果到达即关闭） | `gui_win32.c`（`MaybeShowWaitPrompt` / `WaitPromptProc`） |
| 关窗时处理活动请求、不强制终止线程 | `gui_win32.c`（`WM_CLOSE`）+ `controller.c`（`ts_controller_destroy`） |
| 线程模型与请求代号 | `controller.c`（`TsCancel` + 临界区 + `PostMessage`） |
| TXT/JSON 导出、受阻单独列出、不含 API Key、失败不破坏数据 | `export.c` / `export_json.c` |
| 构建与依赖获取 | `CMakeLists.txt`、`scripts/fetch_deps.ps1`、`third_party/README.md` |

