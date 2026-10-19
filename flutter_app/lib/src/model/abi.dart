/// 与 C 侧 ts_bridge.dll 的 ABI 契约常量（模型层数据契约，不含任何 FFI 绑定）。
///
/// 界面与状态层需要展示/校验 ABI 版本时引用这里，而不是导入 ffi 实现。
library;

/// 本 Dart 代码期望的 ABI 版本，必须等于 C 侧的 `TS_BRIDGE_ABI_VERSION`。
///
/// ABI 2 增加了 `ts_bridge_create_ex`（数据目录）、设置/凭据访问与探针作业接口；
/// 版本不一致时给出明确错误，而不是静默调用错误的函数。
const int kExpectedAbiVersion = 2;

