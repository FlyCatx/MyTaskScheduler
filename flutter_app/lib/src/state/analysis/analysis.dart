// 分块分析模块的公共入口（方便 app_controller / UI 一行导入）。
//
// 目录内容对应第三轮 R3-L：
//   * analysis_budget.dart      分开的限额 + 保守 token 估算 + 序列化复核
//   * material_chunker.dart     结构优先分块 + 稳定片段 ID + 覆盖清单
//   * model_output_parser.dart  严格解析模型 JSON（来源 ID 必填）
//   * fact_ledger.dart          事实账本：来源校验/去重/矛盾/依赖
//   * chunked_job.dart          作业/块/尝试状态机与本地恢复
//   * chunked_coordinator.dart  有界协调器：waves/预算/归并/预览草稿
//
// 接线示例见 chunked_coordinator.dart 文件末尾注释。

export 'analysis_budget.dart';
export 'chunked_coordinator.dart';
export 'chunked_job.dart';
export 'fact_ledger.dart';
export 'material_chunker.dart';
export 'model_output_parser.dart';
