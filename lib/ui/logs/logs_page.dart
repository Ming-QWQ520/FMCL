import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dirs/app_dirs.dart';
import '../../core/logger/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common.dart';

/// 日志查看器（TODO.md #D-12）。
///
/// 汇总展示游戏日志（`logs/fmcl/`）与崩溃报告（`crash-reports/fmcl/`）：
/// - 列表 + 文件名/内容全文搜索
/// - 详情视图：行数 / 大小 / 修改时间 + 复制 + 删除
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final _search = TextEditingController();
  String _query = '';
  bool _includeContent = true;
  _LogDetail? _detail;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() => _query = _search.text.trim());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gameDir = ref.watch(appSettingsProvider).gameDirectory;
    return Scaffold(
      body: Column(
        children: [
          if (_detail != null)
            Expanded(child: _buildDetail(context, _detail!))
          else
            Expanded(child: _buildList(context, gameDir)),
        ],
      ),
    );
  }

  // ---------------- 列表视图 ----------------

  Widget _buildList(BuildContext context, String gameDir) {
    final files = _scanLogs(gameDir, _query, _includeContent);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: '搜索日志文件名或内容...',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusM),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 内容搜索开关（大目录全文扫描可能较慢）
              FilterChip(
                label: const Text('全文'),
                selected: _includeContent,
                onSelected: (v) => setState(() => _includeContent = v),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: '刷新',
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.article_outlined,
                        size: 52,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(80),
                      ),
                      const SizedBox(height: 10),
                      Text('暂无日志或崩溃报告', style: context.captionStyle),
                      const SizedBox(height: 6),
                      Text(
                        '启动游戏后，日志会汇总到 logs/fmcl 目录',
                        style: context.captionStyle,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  itemCount: files.length,
                  itemBuilder: (context, i) {
                    final f = files[i];
                    return _LogFileTile(
                      file: f,
                      onOpen: () async {
                        final d = await _loadDetail(f.file);
                        if (mounted) setState(() => _detail = d);
                      },
                      onDelete: () async {
                        try {
                          f.file.deleteSync();
                        } catch (e) {
                          AppLogger.error('Logs', '删除日志失败', e);
                        }
                        setState(() {});
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------- 详情视图 ----------------

  Widget _buildDetail(BuildContext context, _LogDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
          child: Row(
            children: [
              BackButton(onPressed: () => setState(() => _detail = null)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  d.file.path.split(Platform.pathSeparator).last,
                  overflow: TextOverflow.ellipsis,
                  style: context.sectionTitle,
                ),
              ),
              IconButton(
                tooltip: '复制全部',
                icon: const Icon(Icons.copy_rounded, size: 20),
                onPressed: () async {
                  // await 前捕获 messenger，避免跨 async 使用 BuildContext
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: d.content));
                  messenger.showSnackBar(
                    const SnackBar(content: Text('已复制到剪贴板')),
                  );
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            '${d.lineCount} 行 · ${_fmtSize(d.sizeBytes)} · ${_fmtTime(d.modified)}',
            style: context.captionStyle,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(AppTheme.radiusM),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                d.content,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.55,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- 工具方法 ----------------

  /// 扫描游戏日志与崩溃报告目录，按修改时间倒序。
  List<_LogFile> _scanLogs(String gameDir, String query, bool searchContent) {
    final dirs = <(String, Directory)>[
      // 启动器完整日志（exe 所在目录\FMCL\logs）
      ('启动器日志（FMCL）', Directory(AppDirs.logsDir)),
      ('游戏日志镜像（FMCL）', Directory(AppDirs.gameLogsDir)),
      ('启动器崩溃报告', Directory(AppDirs.crashReportsDir)),
      // 游戏目录日志
      if (gameDir.isNotEmpty) ...[
        ('游戏日志', Directory('$gameDir/logs/fmcl')),
        ('崩溃报告', Directory('$gameDir/crash-reports/fmcl')),
        ('崩溃报告（游戏）', Directory('$gameDir/crash-reports')),
      ],
    ];

    final out = <_LogFile>[];
    final q = query.toLowerCase();
    for (final (label, dir) in dirs) {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        if (q.isNotEmpty && !name.toLowerCase().contains(q)) {
          if (!searchContent) continue;
          // 内容搜索（限制单文件 2MB 以避免卡顿）
          try {
            if (f.lengthSync() > 2 * 1024 * 1024) continue;
            if (!f.readAsStringSync().toLowerCase().contains(q)) continue;
          } catch (_) {
            continue;
          }
        }
        final stat = f.statSync();
        out.add(
          _LogFile(
            kind: label,
            file: f,
            sizeBytes: stat.size,
            modified: stat.modified,
          ),
        );
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<_LogDetail> _loadDetail(File f) async {
    final stat = f.statSync();
    var content = '';
    try {
      content = f.readAsStringSync();
    } catch (e) {
      content = '<无法读取文件内容: $e>';
    }
    return _LogDetail(
      file: f,
      content: content,
      lineCount: content.isEmpty ? 0 : content.split('\n').length,
      sizeBytes: stat.size,
      modified: stat.modified,
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _LogFile {
  final String kind;
  final File file;
  final int sizeBytes;
  final DateTime modified;
  const _LogFile({
    required this.kind,
    required this.file,
    required this.sizeBytes,
    required this.modified,
  });
}

class _LogDetail {
  final File file;
  final String content;
  final int lineCount;
  final int sizeBytes;
  final DateTime modified;
  const _LogDetail({
    required this.file,
    required this.content,
    required this.lineCount,
    required this.sizeBytes,
    required this.modified,
  });
}

class _LogFileTile extends StatelessWidget {
  final _LogFile file;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _LogFileTile({
    required this.file,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isCrash = file.kind.contains('崩溃');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: onOpen,
        child: Row(
          children: [
            Icon(
              isCrash ? Icons.bug_report_rounded : Icons.description_rounded,
              size: 26,
              color: isCrash
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.file.path.split(Platform.pathSeparator).last,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${file.kind} · '
                    '${_LogsPageState._fmtSize(file.sizeBytes)} · '
                    '${_LogsPageState._fmtTime(file.modified)}',
                    style: context.captionStyle,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
