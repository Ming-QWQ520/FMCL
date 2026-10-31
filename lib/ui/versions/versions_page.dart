import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../data/sources/download_source.dart';
import '../../providers/install_task_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/version/local_version_manager.dart';
import '../../services/launch/launch_service.dart';
import '../../widgets/common.dart';
import '../../widgets/loader_icons.dart';
import '../tools/server_ping_dialog.dart';
import 'import_version_dialog.dart';
import 'modpack_import_dialog.dart';
import 'version_settings_dialog.dart';

/// 版本管理页。
class VersionsPage extends ConsumerStatefulWidget {
  const VersionsPage({super.key});

  @override
  ConsumerState<VersionsPage> createState() => _VersionsPageState();
}

class _VersionsPageState extends ConsumerState<VersionsPage> {
  List<LocalVersion> _versions = [];
  bool _loading = true;
  final Map<String, int> _sizeCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final versions = await LocalVersionManager.I.listVersions(gameDir);
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _loading = false;
    });
    // 异步统计大小
    for (final v in versions) {
      final size = await directorySize(p.dirname(v.jsonPath));
      if (!mounted) return;
      setState(() => _sizeCache[v.id] = size);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              children: [
                Text('版本管理', style: context.titleStyle),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => showImportVersionDialog(context, ref),
                  icon: const Icon(Icons.file_download_rounded, size: 18),
                  label: const Text('导入版本'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => showModpackImport(context),
                  icon: const Icon(Icons.inventory_2_rounded, size: 18),
                  label: const Text('导入整合包'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => showServerPing(context),
                  icon: const Icon(Icons.dns_rounded, size: 18),
                  label: const Text('查询服务器'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _openFolder,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('打开目录'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _versions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_rounded,
                                size: 52,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withAlpha(70)),
                            const SizedBox(height: 12),
                            Text('暂无已安装版本', style: context.captionStyle),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: _versions.length,
                        itemBuilder: (context, i) {
                          final v = _versions[i];
                          return _VersionTile(
                            version: v,
                            sizeBytes: _sizeCache[v.id],
                            onRefresh: _load,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  void _openFolder() {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final dir = Directory('$gameDir/versions');
    if (Platform.isWindows) {
      Process.run('explorer', [dir.path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [dir.path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [dir.path]);
    }
  }
}

class _VersionTile extends ConsumerWidget {
  final LocalVersion version;
  final int? sizeBytes;
  final VoidCallback onRefresh;

  const _VersionTile({
    required this.version,
    this.sizeBytes,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (loader, gameVer) = version.loaderInfo;
    final loaderLabel = switch (loader) {
      'vanilla' => '原版',
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'neoforge' => 'NeoForge',
      'quilt' => 'Quilt',
      _ => loader,
    };
    final loaderColor = switch (loader) {
      'vanilla' => const Color(0xFF16A34A),
      'fabric' => const Color(0xFFC9B458),
      'forge' => const Color(0xFFE88A5A),
      'neoforge' => const Color(0xFFFFA24D),
      'quilt' => const Color(0xFF9B7BDE),
      _ => Colors.grey,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: loaderColor.withAlpha(26),
                borderRadius: BorderRadius.circular(AppTheme.radiusM),
              ),
              child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: LoaderIcons.icon(loader, size: 26),
                ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          version.id,
                          style: const TextStyle(
                              fontSize: 15.5, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: loaderColor.withAlpha(24),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          loaderLabel,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: loaderColor),
                        ),
                      ),
                      if (version.id != version.dirName) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: '目录名：${version.dirName}',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey.withAlpha(24),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '外部导入',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.blueGrey.shade300),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (gameVer != null && gameVer != version.id)
                        '基于 $gameVer',
                      if (sizeBytes != null) formatBytes(sizeBytes!),
                      version.jarPath == null ? '缺少 jar（不完整）' : null,
                    ]
                        .whereType<String>()
                        .join(' · '),
                    style: context.captionStyle,
                  ),
                ],
              ),
            ),
            if (!version.hasJar)
              TextButton.icon(
                onPressed: () => _repair(context, ref),
                icon: const Icon(Icons.build_circle_outlined, size: 18),
                label: const Text('修复'),
              ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(120)),
              onSelected: (action) async {
                final gameDir = ref.read(appSettingsProvider).gameDirectory;
                switch (action) {
                  case 'launch':
                    _launch(context, ref);
                  case 'repair':
                    await _repair(context, ref);
                  case 'export':
                    await _export(context, ref, gameDir);
                  case 'settings':
                    await showVersionSettings(context, version.id);
                  case 'delete':
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除版本'),
                        content: Text('确定删除 ${version.id} 吗？\n此操作不可恢复。'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除')),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await LocalVersionManager.I.removeVersion(
                          gameDir, version.id);
                      onRefresh();
                    }
                  case 'open':
                    _openDir(p.dirname(version.jsonPath));
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'launch', child: Text('启动此版本')),
                PopupMenuItem(value: 'open', child: Text('打开版本目录')),
                PopupMenuItem(value: 'repair', child: Text('修复版本（补全 json / jar）')),
                PopupMenuItem(value: 'export', child: Text('导出为 zip')),
                PopupMenuItem(value: 'settings', child: Text('版本设置（隔离 / Java / 内存）')),
                PopupMenuItem(value: 'delete', child: Text('删除版本')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _launch(BuildContext context, WidgetRef ref) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在启动 ${version.id}，可在「启动」页查看进度')));
    ref.read(launchServiceProvider).launch(version.id).catchError((Object e) {
      if (!context.mounted || e is CancelledException) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('启动失败: ${e is AppException ? e.userMessage : e}'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    });
  }

  Future<void> _repair(BuildContext context, WidgetRef ref) async {
    final task = ref.read(installTaskProvider.notifier);
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final source = DownloadSources.of(
        ref.read(appSettingsProvider).downloadSourceIndex == 1
            ? DownloadSourceKind.official
            : DownloadSourceKind.bmclapi);
    task.begin('修复版本 ${version.id}');
    try {
      await LocalVersionManager.I.repairVersion(
        gameDir,
        version.id,
        onProgress: task.update,
        downloadManager: ref.read(downloadManagerProvider),
        source: source,
      );
      task.end();
      onRefresh();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('版本 ${version.id} 修复完成')));
    } catch (e) {
      task.end(failed: true);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('修复失败: ${e is AppException ? e.userMessage : e}'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      Future.delayed(const Duration(seconds: 3), () {
        ref.read(installTaskProvider.notifier).clear();
      });
    }
  }

  Future<void> _export(
      BuildContext context, WidgetRef ref, String gameDir) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '导出版本为 zip',
      fileName: '${version.id}.zip',
    );
    if (savePath == null || !context.mounted) return;
    try {
      await LocalVersionManager.I.exportVersion(
          gameDir, version.id, savePath);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出到 $savePath')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('导出失败: ${e is AppException ? e.userMessage : e}'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  void _openDir(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    }
  }
}
