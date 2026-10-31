/// 主页（对齐 PCL2）：启动区 + 快捷入口 + 日志条。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../dialogs/install_task_dialog.dart';
import '../dialogs/version_settings_dialog.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);
    final sessions = ref.watch(launchSessionsProvider);
    final active = sessions.where((s) => s.isActive).toList();
    final logs = ref.watch(recentLogsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---------- 启动区 ----------
          PclPanel(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '启动游戏',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (selected.isNotEmpty)
                      PclTag(selected, color: kAccent, filled: true),
                    const Spacer(),
                    PclButton(
                      text: '版本选择',
                      primary: false,
                      icon: Icons.list_alt_rounded,
                      onTap: () => _openSelector(context),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _LaunchButton(
                      enabled: selected.isNotEmpty && active.isEmpty,
                      onTap: () => _launch(context, ref, selected),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SelectedVersionCard(
                            selected: selected,
                            versions: versions.value ?? const [],
                          ),
                          for (final s in active) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: kAccent,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${s.versionId} · ${s.message}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                PclButton(
                                  text: '终止',
                                  danger: true,
                                  height: 26,
                                  fontSize: 12,
                                  onTap: () => ref
                                      .read(launchSessionsProvider.notifier)
                                      .terminate(s.id),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 快捷入口 ----------
          Row(
            children: [
              Expanded(
                child: _QuickCard(
                  icon: Icons.folder_open_rounded,
                  title: '游戏文件夹',
                  subtitle: '打开 .minecraft 目录',
                  onTap: () => _openGameDir(ref),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickCard(
                  icon: Icons.build_circle_outlined,
                  title: '补全文件',
                  subtitle: '校验并补全当前版本',
                  onTap: () => _completeVersion(context, ref, selected),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickCard(
                  icon: Icons.tune_rounded,
                  title: '版本设置',
                  subtitle: '隔离 / 内存 / Java',
                  onTap: () => _openVersionSettings(context, selected),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickCard(
                  icon: Icons.download_for_offline_outlined,
                  title: '下载游戏',
                  subtitle: '新版本 / 模组 / 整合包',
                  onTap: () => ref.read(pageIndexProvider.notifier).set(1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ---------- 日志条 ----------
          Expanded(
            child: PclPanel(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '启动器日志',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      PclButton(
                        text: '查看全部',
                        primary: false,
                        height: 26,
                        fontSize: 12,
                        onTap: () =>
                            ref.read(pageIndexProvider.notifier).set(3),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: logs.isEmpty
                        ? const EmptyView(
                            icon: Icons.article_outlined,
                            text: '暂无日志',
                          )
                        : ListView.builder(
                            itemCount: logs.length.clamp(0, 120),
                            itemBuilder: (context, i) {
                              final start = (logs.length - 120).clamp(
                                0,
                                logs.length,
                              );
                              final e = logs[start + i];
                              final isDark =
                                  Theme.of(context).brightness ==
                                  Brightness.dark;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 1,
                                ),
                                child: Text(
                                  '[${e.level}] [${e.module}] ${e.message}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontFamilyFallback: const [
                                      'Consolas',
                                      'monospace',
                                    ],
                                    color: e.level == 'ERROR'
                                        ? Colors.red
                                        : e.level == 'WARN'
                                        ? Colors.orange
                                        : isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                ),
                              );
                            },
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

  void _launch(BuildContext context, WidgetRef ref, String versionId) async {
    if (versionId.isEmpty) return;
    try {
      await ref.read(launchSessionsProvider.notifier).launch(versionId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: kDanger));
      }
    }
  }

  void _openSelector(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _VersionSelectorDialog(),
    );
  }

  void _openGameDir(WidgetRef ref) async {
    final dir = ref.read(gameDirProvider);
    try {
      await Directory(dir).create(recursive: true);
      await rust.openPath(path: dir);
    } catch (_) {}
  }

  void _completeVersion(BuildContext context, WidgetRef ref, String versionId) {
    if (versionId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择版本')));
      return;
    }
    final settings = ref.read(settingsProvider);
    final task = ref.read(installTaskProvider.notifier);
    task.complete(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
      bmclapiFirst: settings.downloadSourceIndex == 0,
      concurrency: settings.concurrency,
    );
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const InstallTaskDialog(),
    );
  }

  void _openVersionSettings(BuildContext context, String versionId) {
    if (versionId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择版本')));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => VersionSettingsDialog(versionId: versionId),
    );
  }
}

/// 大启动按钮（PCL2 风格）
class _LaunchButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _LaunchButton({required this.enabled, required this.onTap});

  @override
  State<_LaunchButton> createState() => _LaunchButtonState();
}

class _LaunchButtonState extends State<_LaunchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            color: widget.enabled
                ? (_hover ? kAccentDeep : kAccent)
                : (isDark
                      ? Colors.white.withAlpha(10)
                      : Colors.black.withAlpha(6)),
            borderRadius: BorderRadius.circular(18),
            boxShadow: widget.enabled
                ? [
                    BoxShadow(
                      color: kAccent.withAlpha(_hover ? 90 : 50),
                      blurRadius: _hover ? 18 : 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.play_arrow_rounded,
                size: 44,
                color: widget.enabled ? Colors.white : Colors.white30,
              ),
              Text(
                '启动',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: widget.enabled ? Colors.white : Colors.white30,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中版本信息卡
class _SelectedVersionCard extends ConsumerWidget {
  final String selected;
  final List<LocalVersionInfo> versions;

  const _SelectedVersionCard({required this.selected, required this.versions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = versions.where((x) => x.id == selected).firstOrNull;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return HoverTile(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const _VersionSelectorDialog(),
      ),
      child: Row(
        children: [
          VersionIcon(loader: v?.loader ?? 'vanilla', size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selected.isEmpty ? '尚未选择版本' : selected,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  v == null
                      ? '点击选择或前往下载页安装'
                      : '${loaderLabel(v.loader)}${v.loaderVersion.isEmpty ? '' : ' ${v.loaderVersion}'} · ${formatBytes(v.sizeBytes)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: isDark ? Colors.white30 : Colors.black26,
          ),
        ],
      ),
    );
  }
}

/// 版本快速选择弹窗
class _VersionSelectorDialog extends ConsumerWidget {
  const _VersionSelectorDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '选择版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  PclButton(
                    text: '安装新版本',
                    primary: false,
                    height: 30,
                    fontSize: 12.5,
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(pageIndexProvider.notifier).set(1);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: versions.when(
                  data: (list) => list.isEmpty
                      ? const EmptyView(text: '尚未安装任何版本')
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final v = list[i];
                            final isSelected = v.id == selected;
                            return Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? kAccent
                                      : Colors.transparent,
                                ),
                              ),
                              child: HoverTile(
                                onTap: () {
                                  ref
                                      .read(selectedVersionProvider.notifier)
                                      .select(v.id);
                                  Navigator.of(context).pop();
                                },
                                child: Row(
                                  children: [
                                    VersionIcon(loader: v.loader),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        v.id,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    PclTag(loaderLabel(v.loader)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyView(text: '加载失败: $e'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快捷入口卡
class _QuickCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QuickCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PclPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: kAccent.withAlpha(22),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 20, color: kAccent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
