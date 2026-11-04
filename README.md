# TaskScheduler

TaskScheduler 是一款 Windows 桌面任务规划工具。它可分析用户提供的文字材料，生成任务计划，并在本地校验依赖关系、安排顺序和展示结果。模型连接由用户配置；应用不会执行模型生成的命令。

## 当前版本

0.2.0（Windows x64）。请从 [GitHub Releases](https://github.com/FlyCatx/MyTaskScheduler/releases) 下载程序包。

## 主要功能

- 从文本和常见文档中提取任务信息。
- 编辑任务、前置关系、时间安排和可用时间表。
- 通过兼容 OpenAI API 的模型服务分析材料。
- 在本地校验计划并查看甘特图等视图。
- 使用本地应用数据保存设置和计划。

## 项目结构

- `src/`：C 业务逻辑与本机接口。
- `flutter_app/`：Flutter Windows 桌面界面。
- `tests/`：自动化回归测试与本地模拟服务。
- `scripts/`：依赖准备、构建和打包脚本。

## Windows 构建

需要 Visual Studio C/C++ 工具、CMake 和 Flutter SDK。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Test
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
```

Flutter 应用与 C 内核通过 `ts_bridge.dll` 协作。详细构建和目录说明见 [Flutter 部分说明](flutter_app/README.md)。

## 配置与数据

首次使用时在应用设置中配置模型服务地址、模型名称和凭据。不要将本地设置文件、API 密钥或用户数据提交到仓库。

版本说明：[0.1.2 到 0.2.0 更新](CHANGELOG-0.1.2-0.2.0.md)。
