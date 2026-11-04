# Flutter Windows 界面

`flutter_app/` 包含 TaskScheduler 的 Flutter 桌面界面。界面通过 `ts_bridge.dll` 调用 C 内核处理分析、数据校验和计划操作；Dart 代码负责窗口、视图、交互、时间表编辑和本地状态协调。

## 主要组成

- `lib/src/model/`：界面和业务间使用的数据模型。
- `lib/src/state/`：应用状态、时间表规划、持久化和分析流程协调。
- `lib/src/ui/`：主窗口、甘特图、时间表编辑器和设置页面。
- `windows/runner/`：Windows 窗口集成与原生消息处理。
- `test/`：Dart 单元测试、组件测试和集成回归测试。

## 构建

在项目根目录准备 C 内核依赖和 Flutter SDK 后，运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
```

发布包由 `scripts/make_flutter_release.ps1` 生成。Flutter 程序需要与对应版本的 `ts_bridge.dll` 及运行依赖一起分发。

## 配置与数据

模型连接和凭据在应用设置中管理。密钥由 Windows 凭据管理器保护；本地配置、用户数据和构建产物不属于源代码提交内容。
