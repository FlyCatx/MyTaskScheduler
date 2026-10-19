# C 源码目录（0.1.0）

本目录按**源码依赖方向**分层，而不是按文件数量摆放。箭头表示“上游可以调用下游”：

```
app  →  bridge  →  domain  →  state  →  util
                      │          │
                      └──────────┴──→  platform  →  util
```

- 下层不得反向依赖上层；`platform` 只依赖 `util`，不包含业务判断。
- `platform` 的调用方是 `domain` / `state` **以及最上层的 `app` / `bridge`**；
  "只被 domain/state 调用"是不成立的绝对表述，见下文"仍然存在的平台调用"。
- 旧 Win32 入口（`gui_win32.c`）原位保留：它直接链接 `ts_core`，不走 DLL 支路。
- 所有头文件名在全仓唯一，构建时把下列目录都作为 include 根（见 CMakeLists.txt 的
  `TS_INCLUDE_RELS`），因此源码里只需写 `#include "plan.h"`。新增目录要在此登记；
  代价是"名字唯一"这一约定必须人工守住，`check_layers.ps1` 会报告重名头文件。

## 目录与职责

| 目录 | 职责 | 主要文件 | 允许依赖 |
| --- | --- | --- | --- |
| `app/` | 入口与生命周期装配 | `main.c`、`controller.c/.h` | bridge、domain、state、util、platform |
| `bridge/` | 唯一公开 C ABI（ABI 2，不透明句柄 + 轮询） | `ts_bridge.h/.c`、`ts_file_list.h/.c` | domain、state、util、platform |
| `domain/` | 领域数据契约 | `types.h/.c` | state、util |
| `domain/input/` | 输入来源收集与材料组装 | `input.h/.c` | platform、util |
| `domain/plan/` | 模型输出解析、本地计划编解码、业务校验 | `plan.*`、`plan_local.*`、`plan_validate.c` | domain（types）、state、util |
| `domain/schedule/` | 依赖图、分层、就绪状态、评分与建议顺序 | `scheduler.h/.c` | domain（types）、state、platform、util |
| `domain/analysis/` | 模型调用、提示词、分析流程、日历约束识别 | `model.*`、`prompt.*`、`analyze.*`、`constraints.*` | domain、state、platform、util |
| `domain/present/` | 展示快照（只含用户可见事实） | `display.h/.c` | domain、state、util |
| `domain/export/` | TXT / JSON 导出与格式分派 | `export.*`、`export_json.c`、`export_user.*` | domain、state、util |
| `state/` | 配置、供应商 profile、settings.json 持久化 | `config.*`、`profile.*`、`profile_store.*` | platform、util |
| `platform/` | Windows 底层服务：编码转换、时钟/取消、凭据、文件读取 | `text.*`、`runtime.*`、`credential.*`、`file_io.*` | util |
| `util/` | 不含业务的基础能力 | `mem.h` | 标准库 |
| （根） | 旧 Win32 界面 | `gui_win32.c/.h` | app、domain、state、platform、util |

## 头文件依赖约定

- `bridge/ts_bridge.h` 是唯一对外公开的头文件，只暴露不透明句柄与固定宽度类型。
- `domain/` 内部头文件可以引用 `state/`、`platform/`、`util/`；反之不允许。
- `app/`、`bridge/` 可以调用 `platform/` 的服务（它们是最上层）；`platform/` 只使用 `util/`。
- 依赖方向由脚本检查，不靠人工判断：

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts/check_layers.ps1   # 退出码 0 = 没有向上依赖
  ```

  当前允许的例外只有一条：`app/main.c` 需要包含 `gui_win32.h`（进程入口要启动这个窗口），
  而旧 Win32 界面按约定留在 `src/` 根目录。

## 仍然存在的平台调用（如实记录，不是"都已下沉"）

`platform/` 集中了编码转换、单调时钟/取消、凭据与整文件读取，但以下几处仍在其他层直接使用
Win32 / CRT API。它们是**已知例外**，迁移前必须先证明不改变行为：

| 文件 | 实际调用 | 现状原因 | 迁移前提 |
| --- | --- | --- | --- |
| `state/profile_store.c` | `CreateFileW`、`GetFileAttributesW`、`MoveFileExW`、`DeleteFileW` | settings.json 的原子保存（tmp → .bak → 提升）与损坏文件判定依赖这些语义 | 先在 `platform/` 提供同名语义的一次性封装，并保持失败时"旧文件不被破坏" |
| `domain/analysis/model.c` | `GetFileAttributesA`、`GetModuleFileNameA` | 判断 `config.json` 是否存在、发现可执行文件所在目录 | 需要和 `file_io.h` 的可执行路径/存在性判定一起设计 |
| `domain/analysis/prompt.c` | `GetLocalTime` | 提示词里需要本地日期/时区（当前时区偏移也由此得出） | 移到 `platform/runtime` 后必须保证时区与夏令时行为不变 |
| `domain/export/export.c` | `ts_utf8_to_wide` + `_wfopen`/`_wremove` | 导出写盘（UTF-8 路径、BOM、失败删除半成品）；`export_user.c` 已改为复用这一实现 | 若下沉到 `platform/file_io`，需同时覆盖"失败删除半成品"与 BOM 两个契约 |
| `bridge/ts_bridge.c` | `CreateThread`、`WaitForSingleObject`、`InterlockedExchange`、`GetOpenFileNameW`、`Shell_NotifyIconW`、`GetFileAttributesW` | 作业工作线程、文件对话框、通知与数据目录判定属于 ABI 适配层的职责 | 拆分前必须先固定作业生命周期与取消终态（见 `ts_bridge.h`） |
| `gui_win32.c` | 全部 Win32 界面 API | 旧界面本身 | 保留，不改 |

## 文件头注释的边界

每个文件开头只写"文件职责 + 主要函数"，用于导航。线程模型、输入输出、内存所有权、
失败与取消契约写在对应头文件的函数注释里（例如 `bridge/ts_bridge.h`、`bridge/ts_bridge.c`
的线程说明），文件头不能替代它们。

## 构建与测试

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1   # C 核心 + ts_bridge.dll + C 测试
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1      # 上述 + Flutter analyze/test/build
powershell -ExecutionPolicy Bypass -File scripts/check_layers.ps1           # 分层依赖检查
```

