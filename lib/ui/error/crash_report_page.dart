import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../services/launch/launch_service.dart';
import '../../widgets/common.dart';

/// 错误报告页（PCL2 式"启动器知道哪里错了"）。
class CrashReportPage extends ConsumerWidget {
  const CrashReportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(launchStateProvider).crashReport;
    final logs = ref.watch(launchStateProvider).recentLogs;

    return Scaffold(
      body: Column(
        children: [
          if (report == null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sentiment_satisfied_rounded, size: 52),
                    const SizedBox(height: 10),
                    Text('一切正常，没有崩溃报告', style: context.captionStyle),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () => context.go(AppRoutes.home),
                      child: const Text('返回主页'),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  // ---------- 顶部结论 ----------
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error.withAlpha(20),
                      borderRadius: BorderRadius.circular(AppTheme.radiusL),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error.withAlpha(70),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.bug_report_rounded,
                                color: Theme.of(context).colorScheme.error),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                report.title,
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (report.explanation.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            report.explanation,
                            style: const TextStyle(
                                fontSize: 13.5, height: 1.7),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ---------- 修复建议 ----------
                  if (report.suggestions.isNotEmpty) ...[
                    const SectionHeader('建议操作'),
                    ...report.suggestions.map((s) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AppCard(
                            child: Row(
                              children: [
                                Icon(Icons.build_circle_rounded,
                                    color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(s.title,
                                          style: const TextStyle(
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 2),
                                      Text(s.description,
                                          style: context.captionStyle),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  onPressed: () =>
                                      _executeFix(context, ref, s.actionId),
                                  child: const Text('执行'),
                                ),
                              ],
                            ),
                          ),
                        )),
                    const SizedBox(height: 18),
                  ],

                  // ---------- 关键日志 ----------
                  const SectionHeader('日志末尾（用于反馈）'),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF141619)
                          : const Color(0xFF1E2228),
                      child: SelectableText(
                        logs.length > 60
                            ? logs.sublist(logs.length - 60).join('\n')
                            : logs.join('\n'),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.5,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white70
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => context.go(AppRoutes.home),
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: const Text('返回主页'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _executeFix(BuildContext context, WidgetRef ref, String? actionId) {
    if (actionId == null) return;
    if (actionId.startsWith('goto_')) {
      // 格式: goto_download:1.20.1 → 取冒号前路由段
      final route = actionId.substring(5).split(':').first;
      context.go('/$route');
      return;
    }
    switch (actionId) {
      case 'open_java_settings':
      case 'open_memory_settings':
        context.go(AppRoutes.settings);
      case 'open_mods':
        context.go(AppRoutes.mods);
      case 'open_logs':
        final gameDir = ref.read(appSettingsProvider).gameDirectory;
        final logs = '$gameDir/logs';
        if (Platform.isWindows) {
          Process.run('explorer', [logs]);
        } else if (Platform.isMacOS) {
          Process.run('open', [logs]);
        } else if (Platform.isLinux) {
          Process.run('xdg-open', [logs]);
        }
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请在对应页面手动执行：$actionId')),
        );
    }
  }
}
