// 分块分析弹窗：0.3.0 标题行/关闭规则与文案精简。
//
// 验收点：
//   * 与执行回顾/OCR 主弹窗一致的标题行（间距、图标、右侧关闭）与分隔线；
//   * 关闭按钮贴卡片右端，底部“关闭/取消本次分析”与右上角关闭遵守同一规则：
//     运行中先取消任务，不直接丢弃；
//   * “并发上限”只写实际并发数，不再写“默认低并发”，但保留预算与联网发送提示。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/analysis/chunked_job.dart';
import 'package:taskscheduler_flutter/src/state/analysis/chunked_run_models.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/analysis/chunked_analysis_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

/// 让 startChunkedAnalysis 挂起，用于验证“运行中关闭=取消”规则。
class _HangingChunkController extends AppController {
  _HangingChunkController({required super.engine, required super.store});

  final Completer<ChunkedRunResult> result = Completer<ChunkedRunResult>();
  int cancelCalls = 0;

  @override
  Future<ChunkedRunResult> startChunkedAnalysis({
    void Function(JobProgress progress)? onProgress,
  }) {
    return result.future;
  }

  @override
  void cancelChunkedAnalysis() {
    cancelCalls++;
  }
}

const ChunkedEstimateView _estimate = ChunkedEstimateView(
  chunkCount: 4,
  estimatedExtractionRequests: 3,
  estimatedMergeRequestsMax: 2,
  maxTotalRequests: 5,
  maxConcurrentRequests: 2,
  maxMergeLayers: 1,
  estimatedMaterialTokens: 18000,
  materialBytes: 72000,
  singleRequestUtf8Bytes: 24000,
  documentCount: 2,
  pageCoverage: <String>['文档A: 2/2 页', '文档B: 1/2 页'],
  missingPages: <String>['文档B 第 2 页'],
  costNotice: '费用未知：按实际请求次数与所用模型计费，不虚构金额。',
  needsChunking: true,
);

class _Harness {
  _Harness(this.controller);

  final _HangingChunkController controller;

  Widget build() => MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open-chunked'),
                onPressed: () => ChunkedAnalysisDialog.show(
                  context,
                  controller: controller,
                  estimate: _estimate,
                ),
                child: const Text('打开分块分析'),
              ),
            ),
          ),
        ),
      );
}

void main() {
  testWidgets('标题行与右上角关闭贴右端，文案精简但保留次数/预算/缺页/联网提示',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TsColors.apply(Brightness.light);
    addTearDown(() => TsColors.apply(Brightness.light));

    final controller = _HangingChunkController(
      engine: FakeScheduleEngine(),
      store: InMemorySessionRepository(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Harness(controller).build());
    await tester.tap(find.byKey(const Key('open-chunked')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chunked-analysis-dialog')), findsOneWidget);
    expect(find.text('分块分析'), findsOneWidget);
    expect(find.byKey(const Key('chunked-close-icon')), findsOneWidget);

    // 关闭按钮贴卡片右端（标题行右内边距以内），不是飘在中间。
    final card = tester.getRect(find.byKey(const Key('chunked-analysis-card')));
    final close = tester.getRect(find.byKey(const Key('chunked-close-icon')));
    expect(card.right - close.right, lessThanOrEqualTo(20));
    expect(close.right, lessThan(card.right));

    // 并发上限：实际次数保留，“默认低并发”字样删除。
    expect(find.textContaining('同时最多 2 个请求'), findsOneWidget);
    expect(find.textContaining('默认低并发'), findsNothing);
    // 预算、缺页、联网发送提示仍然可见（不会被精简掉）。
    expect(find.textContaining('费用未知'), findsOneWidget);
    expect(find.textContaining('缺页'), findsOneWidget);
    expect(find.byKey(const Key('chunked-network-boundary')), findsOneWidget);
    expect(find.textContaining('分块后的材料会分别发送给当前配置的模型'), findsOneWidget);
    expect(find.byKey(const Key('chunked-start')), findsOneWidget);

    // 未运行：右上角关闭直接关闭弹窗。
    await tester.tap(find.byKey(const Key('chunked-close-icon')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chunked-analysis-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('运行中所有关闭入口都先取消任务，不丢弃进行中的分析', (tester) async {
    final controller = _HangingChunkController(
      engine: FakeScheduleEngine(),
      store: InMemorySessionRepository(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_Harness(controller).build());
    await tester.tap(find.byKey(const Key('open-chunked')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chunked-start')));
    await tester.pump();
    // 运行中：两个关闭入口文案一致，开始按钮消失。
    expect(find.text('取消本次分析'), findsWidgets);
    expect(find.byKey(const Key('chunked-start')), findsNothing);

    await tester.tap(find.byKey(const Key('chunked-close-icon')));
    await tester.pump();
    expect(controller.cancelCalls, 1);
    expect(find.byKey(const Key('chunked-analysis-dialog')), findsOneWidget,
        reason: '运行中关闭只能取消，不能直接丢弃弹窗');

    await tester.tap(find.byKey(const Key('chunked-cancel')));
    await tester.pump();
    expect(controller.cancelCalls, 2);
    expect(find.byKey(const Key('chunked-analysis-dialog')), findsOneWidget);

    // 协调器回报失败后，弹窗仍展示失败原因（没有被静默关闭）。
    controller.result.complete(
      const ChunkedRunResult(ok: false, message: '分块分析被取消，未生成正式计划。'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未生成正式计划'), findsOneWidget);
    // 结束后关闭入口回到普通“关闭”，不再展示开始按钮（失败不当作可提交）。
    expect(find.byKey(const Key('chunked-start')), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
