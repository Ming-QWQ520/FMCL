/// 日志页：实时启动器日志 + 日志文件浏览（完整日志位于 exe\FMCL\logs\）。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  bool _viewFileMode = false;
  String? _viewingFile;
  final ScrollController _scroll = ScrollController();

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(recentLogsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = ref.watch(appInfoProvider).value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '日志',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 12),
              PclTag('exe\\FMCL\\logs'),
              const Spacer(),
              PclButton(
                text: '实时日志',
                primary: !_viewFileMode,
                height: 30,
                fontSize: 12.5,
                onTap: () async {
                  setState(() {
                    _viewFileMode = false;
                    _viewingFile = null;
                  });
                  await ref.read(recentLogsProvider.notifier).reloadDisk();
                },
              ),
              const SizedBox(width: 8),
              PclButton(
                text: '打开日志目录',
                primary: false,
                height: 30,
                fontSize: 12.5,
                onTap: () async {
                  if (info != null) {
                    await rust.openPath(path: info.logsDir);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 文件列表
          if (_viewFileMode)
            SizedBox(
              height: 92,
              child: _LogFileList(
                onOpen: (meta) async {
                  setState(() => _viewingFile = meta.path);
                  await ref
                      .read(recentLogsProvider.notifier)
                      .loadFile(meta.path);
                },
                current: _viewingFile,
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: PclPanel(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: Text(
                      _viewFileMode
                          ? (_viewingFile == null
                                ? '选择一个日志文件查看'
                                : _viewingFile!
                                      .split(Platform.pathSeparator)
                                      .last)
                          : '实时日志（Rust 落盘 exe\\FMCL\\logs\\latest.log）',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: logs.isEmpty
                        ? const EmptyView(
                            icon: Icons.article_outlined,
                            text: '暂无日志',
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) => false,
                            child: ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              itemCount: logs.length,
                              itemBuilder: (context, i) {
                                final e = logs[i];
                                final color = e.level == 'ERROR'
                                    ? Colors.red
                                    : e.level == 'WARN'
                                    ? Colors.orange
                                    : isDark
                                    ? Colors.white70
                                    : Colors.black87;
                                return SelectableText(
                                  e.time.isEmpty
                                      ? e.message
                                      : '[${e.time}] [${e.level}] [${e.module}] ${e.message}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.45,
                                    fontFamilyFallback: const [
                                      'Consolas',
                                      'monospace',
                                    ],
                                    color: color,
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 日志文件列表（latest.log + 轮转 + 按天归档）
class _LogFileList extends StatefulWidget {
  final void Function(LogFileMeta) onOpen;
  final String? current;

  const _LogFileList({required this.onOpen, this.current});

  @override
  State<_LogFileList> createState() => _LogFileListState();
}

class _LogFileListState extends State<_LogFileList> {
  List<LogFileMeta>? _files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = await rust.listLogFiles();
    if (mounted) setState(() => _files = files);
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    if (files == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return PclPanel(
      padding: const EdgeInsets.all(6),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: files.length,
        itemBuilder: (context, i) {
          final f = files[i];
          final isCurrent = widget.current == f.path;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: HoverTile(
              onTap: () => widget.onOpen(f),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    f.name == 'latest.log'
                        ? Icons.bolt_rounded
                        : Icons.description_outlined,
                    size: 15,
                    color: isCurrent ? kAccent : null,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    f.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                      color: isCurrent ? kAccent : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatBytes(f.sizeBytes),
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white30
                          : Colors.black26,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
