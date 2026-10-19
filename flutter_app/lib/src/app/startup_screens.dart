// 启动期界面：加载中与致命错误两屏，只根据 [StartupFailure] 展示原因与提示。
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets/bezier_ui.dart';
class StartupFailure {
  final String title;
  final String summary;
  final String detail;
  final List<String> hints;

  const StartupFailure({
    required this.title,
    required this.summary,
    required this.detail,
    this.hints = const [],
  });
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            Text('正在加载…', style: TextStyle(fontSize: 12, color: TsColors.textFaint)),
          ],
        ),
      ),
    );
  }
}

class FatalScreen extends StatelessWidget {
  final StartupFailure failure;

  const FatalScreen({super.key, required this.failure});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.report_problem_outlined,
                        color: TsColors.blocked),
                    const SizedBox(width: 8),                    Text(failure.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(failure.summary,
                    style: const TextStyle(fontSize: 12.5, height: 1.6)),
                if (failure.hints.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final h in failure.hints)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.chevron_right,
                              size: 16, color: TsColors.textFaint),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(h,
                                style: const TextStyle(
                                    fontSize: 12, height: 1.5)),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: bezierDecoration(
                    color: TsColors.background,
                    radius: 8,
                    border: Border.all(color: TsColors.border),
                  ),
                  child: SelectableText(
                    failure.detail,
                    style: TextStyle(
                        fontSize: 11.5, color: TsColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

