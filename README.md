# TaskScheduler

TaskScheduler 是一款 Windows 桌面任务规划工具，可从文字和文档中提取任务，编辑依赖关系与可用时间，并展示排程结果。模型连接由用户自行配置；应用在本地校验生成的计划。

## 当前源码版本

0.5.0（Windows x64）。已发布的程序包见 [GitHub Releases](https://github.com/FlyCatx/MyTaskScheduler/releases)，各版本变化见 [更新日志](CHANGELOG.md)。

## 主要功能

- 任务、前置关系、周时间表与跨日时段编辑；支持撤销、重做和预留时段绑定。
- 排程冲突说明及经过本地校验的调整建议，甘特图和其他计划视图。
- 本地 ICS 日历只读导入，并将外部占用计入可用时间。
- 任务执行计时、暂停、手工补记、异常退出恢复、耗时回顾和 CSV 导出。
- 执行截止提醒：到达计划截止后待处理，5 分钟后再提醒，仍未回应则自动完成；支持延长截止。
- 全局共享日程：可关联一个会话仅用于导航；定时/全天、每日/每周重复、单次例外与运行期提醒；忙碌日程对所有会话的排程生效；侧栏提供一周时间轴与小月历导航。
- 本地离线 OCR，支持扫描 PDF、混合 PDF、PNG 和 JPEG 的逐页识别与校对。
- 长材料分块分析，在生成计划前预估请求量并预览结果。
- Windows 自绘窗口、设置、应用数据保存和备份。

## 项目结构

- `src/`：C 业务逻辑与本机接口。
- `flutter_app/`：Flutter Windows 桌面界面。
- `tools/ocr_host/`：本地离线 OCR 辅助程序源码。
- `tests/`：C 业务逻辑回归测试。
- `scripts/`：构建与打包脚本。

## Windows 构建

需要 Visual Studio C/C++ 工具、CMake、Flutter SDK，以及用于 OCR 辅助程序的 .NET Framework 4.8 开发工具。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Test
powershell -ExecutionPolicy Bypass -File scripts/build_ocr_host.ps1
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
powershell -ExecutionPolicy Bypass -File scripts/make_flutter_release.ps1 -Version 0.5.0 -NoApiKey
```

Flutter 应用通过 `ts_bridge.dll` 调用 C 内核。界面说明见 [Flutter README](flutter_app/README.md)。

## 配置与数据

首次使用时在应用设置中配置模型服务地址、模型名称和凭据。本地设置、密钥、用户数据和构建产物不应提交到仓库。
