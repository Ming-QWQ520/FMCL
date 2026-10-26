import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../services/version/local_version_manager.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';
import '../tools/server_ping_dialog.dart';
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
          const CustomTitleBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              children: [
                Text('版本管理', style: context.titleStyle),
                const Spacer(),
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
                  onPressed: () => _openFolder(),
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
              child: Icon(Icons.sports_esports_rounded, color: loaderColor),
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
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(120)),
              onSelected: (action) async {
                final gameDir = ref.read(appSettingsProvider).gameDirectory;
                switch (action) {
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
                PopupMenuItem(value: 'open', child: Text('打开版本目录')),
                PopupMenuItem(value: 'settings', child: Text('版本设置（隔离 / Java / 内存）')),
                PopupMenuItem(value: 'delete', child: Text('删除版本')),
              ],
            ),
          ],
        ),
      ),
    );
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
