// 分块分析模块的公共入口。长材料在这里被拆成有界请求，候选事实经本地账本校验
// 后才允许进入计划；作业流程见 chunked_coordinator.dart 的文件头说明。

export 'analysis_budget.dart';
export 'chunked_coordinator.dart';
export 'chunked_job.dart';
export 'fact_ledger.dart';
export 'material_chunker.dart';
export 'model_output_parser.dart';
