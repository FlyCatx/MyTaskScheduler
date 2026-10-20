# Flutter 桌面界面

`flutter_app` 提供 TaskScheduler 的 Flutter Windows 界面。应用通过 FFI 调用 `ts_bridge.dll`，由共享 C 内核完成模型请求、时间表校验、任务依赖分析和结果处理。

界面包含会话与任务视图、模型连接设置、甘特图和时间表编辑器。桌面窗口由 Windows runner 承载，标题栏和窗口控制与 Flutter 界面保持一致。

## 目录说明

- `lib/src/model/`：任务、会话、设置和时间表的数据模型。
- `lib/src/state/`：应用状态、持久化、迁移与备份逻辑。
- `lib/src/ui/`：主界面、设置、甘特图、时间表编辑器和菜单组件。
- `lib/src/ffi/`：Flutter 与 C 桥接库之间的接口。
- `windows/runner/`：Windows 窗口创建、标题栏和原生窗口消息处理。
- `test/`：模型、状态和界面交互的自动化测试。

接口密钥由本机配置或环境变量提供。不要将个人配置文件或密钥提交到版本库。
