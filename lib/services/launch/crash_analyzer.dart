import 'dart:io';

import '../../core/error/app_exception.dart';

/// 游戏崩溃分析器（借鉴 PCL2 的错误报告思想）。
///
/// 从游戏日志尾部 / 崩溃报告 / 退出码推断故障原因，
/// 生成用户可读的解释与一键修复建议。
class CrashAnalyzer {
  const CrashAnalyzer._();

  /// 已知崩溃模式库（按优先级排序）
  static final List<CrashPattern> _patterns = [
    CrashPattern(
      id: 'java_version',
      title: 'Java 版本不兼容',
      matchers: [
        'UnsupportedClassVersionError',
        'has been compiled by a more recent version of the Java Environment',
        'class file version',
        'IncompatibleClassChangeError',
      ],
      explanation: '当前使用的 Java 版本与该 Minecraft 版本不匹配。\n'
          '• 1.20.5+ 需要 Java 21\n• 1.18~1.20.4 需要 Java 17\n'
          '• 1.17 需要 Java 16/17\n• 1.12~1.16 需要 Java 8/11',
      suggestions: [
        const FixSuggestion(
          '切换 Java 版本',
          '在启动设置中选择与游戏版本匹配的 Java，或安装对应版本。',
          actionId: 'open_java_settings',
        ),
      ],
    ),
    CrashPattern(
      id: 'out_of_memory',
      title: '内存不足',
      matchers: [
        'OutOfMemoryError',
        'java.lang.OutOfMemory',
        'Could not reserve enough space',
        'Failed allocating',
      ],
      explanation: '游戏内存分配不足或系统可用内存不够。',
      suggestions: [
        const FixSuggestion(
          '增大内存分配',
          '在 设置 → 启动 中调大「最大内存」（建议 4096MB 以上）。',
          actionId: 'open_memory_settings',
        ),
      ],
    ),
    CrashPattern(
      id: 'mod_error',
      title: '模组导致崩溃',
      matchers: [
        'FabricLoader',
        'ExceptionInInitializerError',
        'ModConstructionException',
        'LoadingException',
        'NoSuchMethodError',
        'NoClassDefFoundError',
      ],
      explanation: '日志中检测到模组相关异常。常见原因：\n'
          '• 模组与游戏版本不匹配\n• 缺少前置模组（Fabric API / Forge 前置）\n'
          '• 两个模组冲突',
      suggestions: [
        const FixSuggestion(
          '查看崩溃详情',
          '根据日志中提到的模组名称，在模组管理中移除或更新对应模组。',
          actionId: 'open_mods',
        ),
      ],
    ),
    CrashPattern(
      id: 'missing_assets',
      title: '游戏资源缺失',
      matchers: [
        'Unable to load assets',
        'MissingResourceException',
        'Failed to download',
        'asset index',
      ],
      explanation: '游戏资源文件缺失或损坏（可能因下载中断）。',
      suggestions: [
        const FixSuggestion(
          '补全游戏文件',
          '在版本管理中对该版本执行「补全文件」，FMCL 会重新校验并下载缺失资源。',
          actionId: 'repair_version',
        ),
      ],
    ),
    CrashPattern(
      id: 'natives',
      title: '本地库(natives)异常',
      matchers: [
        'UnsatisfiedLinkError',
        'no lwjgl in java.library.path',
        'java.library.path.natives',
        'Failed to load library',
      ],
      explanation: '平台本地库加载失败，可能是 natives 解压不完整或显卡驱动问题。',
      suggestions: [
        const FixSuggestion(
          '重建 natives',
          '在版本管理中执行「补全文件」，FMCL 会重新解压本地库。',
          actionId: 'repair_version',
        ),
        const FixSuggestion(
          '更新显卡驱动',
          'LWJGL 依赖 OpenGL 3.2+，请确保显卡驱动为最新版本。',
        ),
      ],
    ),
    CrashPattern(
      id: 'graphics',
      title: '显卡/驱动问题',
      matchers: [
        'GLX',
        'glfwInit',
        'OpenGL',
        'dxdiag',
        'Failed to create window',
      ],
      explanation: '图形初始化失败。常见于远程桌面、虚拟机或驱动过旧。',
      suggestions: [
        const FixSuggestion(
          '检查运行环境',
          '请在物理机 + 最新显卡驱动环境运行；远程桌面/虚拟机可能不支持 OpenGL。',
        ),
      ],
    ),
  ];

  /// 分析崩溃并给出结论
  static CrashReport analyze({
    required String logTail,
    required int exitCode,
    String? versionId,
  }) {
    // 正常退出
    if (exitCode == 0 && !logTail.contains('Exception')) {
      return const CrashReport(
        kind: 'normal',
        title: '游戏已正常退出',
        explanation: '',
        suggestions: [],
        exitCode: 0,
      );
    }

    for (final pattern in _patterns) {
      for (final m in pattern.matchers) {
        if (logTail.contains(m)) {
          return CrashReport(
            kind: pattern.id,
            title: pattern.title,
            explanation: pattern.explanation,
            suggestions: pattern.suggestions,
            exitCode: exitCode,
            matchedKeyword: m,
          );
        }
      }
    }

    // 无法识别
    return CrashReport(
      kind: 'unknown',
      title: '游戏异常退出（代码 $exitCode）',
      explanation: 'FMCL 未能自动识别该崩溃的具体原因。\n'
          '可尝试以下通用方案，或将完整日志提交到项目仓库反馈。',
      suggestions: const [
        FixSuggestion(
          '补全游戏文件',
          '文件缺失/损坏是未明崩溃的常见原因，建议先执行「补全文件」。',
          actionId: 'repair_version',
        ),
        FixSuggestion(
          '查看完整日志',
          '在 设置 → 关于 中打开日志目录，查看 latest.log 与 crash-reports。',
          actionId: 'open_logs',
        ),
      ],
      exitCode: exitCode,
    );
  }

  /// 从 hs_err / crash report 文件提取关键行
  static String extractKeyLines(String log) {
    final lines = log.split('\n');
    final keys = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.contains('Exception') ||
          l.contains('Error') ||
          l.contains('Caused by')) {
        keys.add(l);
        // 带上随后 3 行上下文
        for (var j = 1; j <= 3 && i + j < lines.length; j++) {
          keys.add(lines[i + j]);
        }
      }
    }
    return keys.take(60).join('\n');
  }
}

class CrashPattern {
  final String id;
  final String title;
  final List<String> matchers;
  final String explanation;
  final List<FixSuggestion> suggestions;

  const CrashPattern({
    required this.id,
    required this.title,
    required this.matchers,
    required this.explanation,
    this.suggestions = const [],
  });
}

class CrashReport {
  final String kind;
  final String title;
  final String explanation;
  final List<FixSuggestion> suggestions;
  final int exitCode;
  final String? matchedKeyword;

  const CrashReport({
    required this.kind,
    required this.title,
    required this.explanation,
    required this.suggestions,
    required this.exitCode,
    this.matchedKeyword,
  });

  bool get isNormalExit => kind == 'normal';
}

/// 平台无关的日志文件定位
Future<String?> findLatestCrashReport(String gameDir) async {
  final dir = Directory('$gameDir/crash-reports');
  if (!dir.existsSync()) return null;
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.txt'))
      .toList()
    ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return files.firstOrNull?.path;
}
