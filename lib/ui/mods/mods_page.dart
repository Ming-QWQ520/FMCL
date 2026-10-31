import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../services/mod/modrinth_service.dart';
import '../../services/resource/resource_service.dart';
import '../../services/version/local_version_manager.dart';
import '../../widgets/common.dart';

/// 资源中心（借鉴 HMCL「资源下载」：模组 / 光影 / 资源包 / 地图）。
///
/// 资源按版本隔离规则安装到生效游戏目录的对应子目录；
/// 模组保留启停与前置依赖解析能力。
class ModsPage extends ConsumerStatefulWidget {
  const ModsPage({super.key});

  @override
  ConsumerState<ModsPage> createState() => _ModsPageState();
}

class _ModsPageState extends ConsumerState<ModsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  ResourceKind _kind = ResourceKind.mod;
  String? _selectedVersion;

  // 在线搜索
  final _searchCtrl = TextEditingController();
  List<ModrinthSearchHit> _hits = [];
  bool _searching = false;
  bool _installingResource = false;
  String _loaderFilter = 'fabric';

  // 本地内容
  List<LocalResourceEntry> _local = [];
  bool _loadingLocal = true;

  @override
  void initState() {
    super.initState();
    _initVersion();
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _initVersion() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final versions = await LocalVersionManager.I.listVersions(gameDir);
    if (!mounted) return;
    setState(() {
      _selectedVersion = versions.firstOrNull?.id;
    });
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final v = _selectedVersion;
    if (v == null) {
      setState(() => _loadingLocal = false);
      return;
    }
    final settings = ref.read(appSettingsProvider);
    final list = await ref.read(resourceInstallServiceProvider).listLocal(
          global: settings,
          gameDir: settings.gameDirectory,
          versionId: v,
          kind: _kind,
        );
    if (!mounted) return;
    setState(() {
      _local = list;
      _loadingLocal = false;
    });
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    try {
      final gameVer =
          ResourceInstallService.guessGameVersion(_selectedVersion ?? '');
      final hits = await ModrinthService.I.search(
        query: _searchCtrl.text.trim(),
        loader: _kind == ResourceKind.mod ? _loaderFilter : '',
        gameVersion: _kind == ResourceKind.mod ? gameVer : null,
        projectType: _kind.apiType,
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('搜索失败: $e')),
      );
    }
  }

  Future<void> _installResource(ModrinthSearchHit hit) async {
    final versionId = _selectedVersion;
    if (versionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在顶部选择目标版本')));
      return;
    }
    setState(() => _installingResource = true);
    try {
      final gameVer = ResourceInstallService.guessGameVersion(versionId);
      final message = await ref.read(resourceInstallServiceProvider).install(
            hit: hit,
            kind: _kind,
            versionId: versionId,
            gameVersion: gameVer,
            loader: _loaderFilter,
            onProgress: (m) {
              if (!mounted) return;
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(SnackBar(content: Text(m),
                    duration: const Duration(seconds: 1)));
            },
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      _loadLocal();
    } on AppException catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('安装失败: $e')));
    } finally {
      if (mounted) setState(() => _installingResource = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('资源中心', style: context.titleStyle),
                    const Spacer(),
                    // 版本选择
                    FutureBuilder<List<LocalVersion>>(
                      future: LocalVersionManager.I.listVersions(
                          ref.read(appSettingsProvider).gameDirectory),
                      builder: (context, snap) {
                        final versions = snap.data ?? const <LocalVersion>[];
                        if (versions.isEmpty) {
                          return Text('无版本', style: context.captionStyle);
                        }
                        return DropdownButton<String>(
                          value: _selectedVersion,
                          underline: const SizedBox.shrink(),
                          items: versions
                              .map((v) => DropdownMenuItem(
                                    value: v.id,
                                    child: Text(v.id,
                                        style:
                                            const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _selectedVersion = v;
                              _loadingLocal = true;
                            });
                            _loadLocal();
                          },
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 资源类别选择（HMCL 式分类）
                SegmentedButton<ResourceKind>(
                  segments: [
                    for (final k in ResourceKind.values)
                      ButtonSegment(
                        value: k,
                        label: Text(k.label),
                        icon: Icon(_iconOf(k), size: 17),
                      ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) {
                    setState(() {
                      _kind = s.first;
                      _loadingLocal = true;
                      _hits = [];
                    });
                    _loadLocal();
                  },
                ),
                TabBar(
                  controller: _tab,
                  tabs: const [
                    Tab(text: '在线安装 (Modrinth)'),
                    Tab(text: '本地管理'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildOnline(),
                _buildLocal(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconOf(ResourceKind k) => switch (k) {
        ResourceKind.mod => Icons.extension_rounded,
        ResourceKind.shader => Icons.auto_awesome_rounded,
        ResourceKind.resourcepack => Icons.palette_rounded,
        ResourceKind.world => Icons.public_rounded,
      };

  // ---------------- 在线安装 ----------------

  Widget _buildOnline() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '搜索${_kind.label}（Modrinth）',
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              if (_kind == ResourceKind.mod) ...[
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _loaderFilter,
                  underline: const SizedBox.shrink(),
                  items: const ['fabric', 'forge', 'neoforge', 'quilt']
                      .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _loaderFilter = v ?? 'fabric'),
                ),
              ],
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: Text(_searching ? '搜索中' : '搜索'),
              ),
            ],
          ),
        ),
        Expanded(
          child: !_searching
              ? (_hits.isEmpty
                  ? Center(
                      child: Text('输入关键词开始搜索${_kind.label}',
                          style: context.captionStyle))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      itemCount: _hits.length,
                      itemBuilder: (context, i) => _ResourceHitTile(
                        hit: _hits[i],
                        busy: _installingResource,
                        onInstall: _installResource,
                      ),
                    ))
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }

  // ---------------- 本地管理 ----------------

  Widget _buildLocal() {
    if (_loadingLocal) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_selectedVersion == null) {
      return Center(child: Text('请先安装一个版本', style: context.captionStyle));
    }
    if (_local.isEmpty) {
      return Center(
          child: Text('该版本暂无本地${_kind.label}',
              style: context.captionStyle));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _local.length,
      itemBuilder: (context, i) {
        final item = _local[i];
        final isMod = _kind == ResourceKind.mod;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AppCard(
            child: Row(
              children: [
                Icon(
                  item.isDirectory
                      ? Icons.public_rounded
                      : _iconOf(_kind),
                  color: (isMod && !item.enabled)
                      ? Colors.grey
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          decoration:
                              (isMod && !item.enabled)
                                  ? TextDecoration.lineThrough
                                  : null,
                        ),
                      ),
                      Text(
                        [
                          formatBytes(item.sizeBytes),
                          if (item.isDirectory && !item.valid) '缺少 level.dat',
                          if (isMod && !item.enabled) '已停用',
                        ].join(' · '),
                        style: context.captionStyle,
                      ),
                    ],
                  ),
                ),
                if (isMod && !item.isDirectory)
                  Switch(
                    value: item.enabled,
                    onChanged: (v) async {
                      await ref
                          .read(resourceInstallServiceProvider)
                          .setEnabled(item, v);
                      _loadLocal();
                    },
                  ),
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded,
                      color:
                          Theme.of(context).colorScheme.error.withAlpha(160)),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('删除${_kind.label}'),
                        content: Text(
                            '确定删除「${item.displayName}」吗？此操作不可恢复。'),
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
                      await ref
                          .read(resourceInstallServiceProvider)
                          .deleteLocal(item);
                      _loadLocal();
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ResourceHitTile extends StatelessWidget {
  final ModrinthSearchHit hit;
  final bool busy;
  final ValueChanged<ModrinthSearchHit> onInstall;

  const _ResourceHitTile({
    required this.hit,
    required this.busy,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: Row(
          children: [
            if (hit.iconUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusM),
                child: Image.network(
                  hit.iconUrl!,
                  width: 44,
                  height: 44,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.extension_rounded),
                ),
              )
            else
              const Icon(Icons.extension_rounded),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hit.title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    hit.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.captionStyle,
                  ),
                  Text(
                    '${hit.downloads} 次下载'
                    '${hit.categories.isEmpty ? '' : ' · ${hit.categories.take(3).join(' / ')}'}',
                    style: context.captionStyle,
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : () => onInstall(hit),
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('安装'),
            ),
          ],
        ),
      ),
    );
  }
}
