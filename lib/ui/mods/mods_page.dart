import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../services/mod/modrinth_service.dart';
import '../../services/version/local_version_manager.dart';
import '../../services/version/version_settings.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';

/// 模组页：本地模组管理 + Modrinth 在线安装。
class ModsPage extends ConsumerStatefulWidget {
  const ModsPage({super.key});

  @override
  ConsumerState<ModsPage> createState() => _ModsPageState();
}

class _ModsPageState extends ConsumerState<ModsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  List<LocalModEntry> _mods = [];
  bool _loadingMods = true;
  String? _selectedVersion;

  // Modrinth 搜索
  final _searchCtrl = TextEditingController();
  List<ModrinthSearchHit> _hits = [];
  bool _searching = false;
  String _loaderFilter = 'fabric';

  @override
  void initState() {
    super.initState();
    _initVersion();
  }

  Future<void> _initVersion() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final versions = await LocalVersionManager.I.listVersions(gameDir);
    if (!mounted) return;
    setState(() {
      _selectedVersion = versions.firstOrNull?.id;
    });
    _loadMods();
  }

  Future<void> _loadMods() async {
    final v = _selectedVersion;
    if (v == null) {
      setState(() => _loadingMods = false);
      return;
    }
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final modsDir = VersionSettingsService.I.modsDirFor(
        ref.read(appSettingsProvider), gameDir, v);
    final mods = await LocalModService.I.listMods(v, gameDir, modsDir: modsDir);
    if (!mounted) return;
    setState(() {
      _mods = mods;
      _loadingMods = false;
    });
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    try {
      final hits = await ModrinthService.I.search(
        query: _searchCtrl.text.trim(),
        loader: _loaderFilter,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('模组', style: context.titleStyle),
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
                                    child: Text(v.id, style: const TextStyle(fontSize: 13)),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _selectedVersion = v;
                              _loadingMods = true;
                            });
                            _loadMods();
                          },
                        );
                      },
                    ),
                  ],
                ),
                TabBar(
                  controller: _tab,
                  tabs: const [
                    Tab(text: '本地模组'),
                    Tab(text: '在线安装 (Modrinth)'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildLocalMods(),
                _buildModrinth(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalMods() {
    if (_loadingMods) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_selectedVersion == null) {
      return Center(child: Text('请先安装一个版本', style: context.captionStyle));
    }
    if (_mods.isEmpty) {
      return Center(child: Text('该版本尚未安装任何模组', style: context.captionStyle));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _mods.length,
      itemBuilder: (context, i) {
        final mod = _mods[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AppCard(
            child: Row(
              children: [
                Icon(
                  Icons.extension_rounded,
                  color: mod.enabled
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mod.fileName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          decoration: mod.enabled
                              ? null
                              : TextDecoration.lineThrough,
                        ),
                      ),
                      Text(
                        '${formatBytes(mod.sizeBytes)}'
                        '${mod.enabled ? '' : ' · 已停用'}',
                        style: context.captionStyle,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: mod.enabled,
                  onChanged: (v) async {
                    await LocalModService.I.setEnabled(mod, v);
                    _loadMods();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded,
                      color: Theme.of(context).colorScheme.error.withAlpha(160)),
                  onPressed: () async {
                    await LocalModService.I.delete(mod);
                    _loadMods();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildModrinth() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: '搜索模组名称（如 sodium / iris）',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _loaderFilter,
                underline: const SizedBox.shrink(),
                items: const ['fabric', 'forge', 'neoforge', 'quilt']
                    .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                    .toList(),
                onChanged: (v) => setState(() => _loaderFilter = v ?? 'fabric'),
              ),
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
                      child: Text('输入关键词开始搜索',
                          style: context.captionStyle))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      itemCount: _hits.length,
                      itemBuilder: (context, i) =>
                          _ModrinthHitTile(hit: _hits[i], onInstall: _installMod),
                    ))
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }

  Future<void> _installMod(ModrinthSearchHit hit) async {
    final versionId = _selectedVersion;
    if (versionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在顶部选择目标版本')));
      return;
    }
    try {
      // 1. 版本列表（按当前版本过滤）
      final gameVer = _guessGameVersion(versionId);
      final versions = await ModrinthService.I.getVersions(
        projectId: hit.projectId,
        loader: _loaderFilter,
        gameVersion: gameVer,
      );
      if (versions.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('没有找到适配 $gameVer ($_loaderFilter) 的版本')));
        return;
      }
      final modVersion = versions.first;
      final primary = modVersion.primaryFile;
      if (primary == null) return;

      // 2. 依赖解析
      final deps = await ModrinthService.I.resolveDependencyTree(
        version: modVersion,
        loader: _loaderFilter,
        gameVersion: gameVer,
      );

      // 3. 下载主文件 + 依赖
      final settings = ref.read(appSettingsProvider);
      final modsDir = VersionSettingsService.I.modsDirFor(
          settings, settings.gameDirectory, versionId);
      await ModrinthService.I.downloadMod(
        url: primary.url,
        savePath: '$modsDir/${primary.filename}',
      );
      for (final dep in deps) {
        await ModrinthService.I.downloadMod(
          url: dep.url,
          savePath: '$modsDir/${dep.fileName}',
        );
      }
      _loadMods();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '已安装 ${primary.filename}${deps.isEmpty ? '' : '（含 ${deps.length} 个前置依赖）'}'),
      ));
    } on AppException catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('安装失败: $e')));
    }
  }

  /// 从版本 id 猜测游戏版本（如 fmcl-fabric-1.20.1-0.15.11 → 1.20.1）
  String _guessGameVersion(String versionId) {
    final m =
        RegExp(r'(\d+\.\d+(\.\d+)?)').allMatches(versionId).toList();
    if (m.isNotEmpty) return m.first.group(1)!;
    return versionId;
  }
}

class _ModrinthHitTile extends StatelessWidget {
  final ModrinthSearchHit hit;
  final ValueChanged<ModrinthSearchHit> onInstall;

  const _ModrinthHitTile({required this.hit, required this.onInstall});

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
                  errorBuilder: (_, _, _) => const Icon(Icons.extension_rounded),
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
                    '${hit.downloads} 次下载 · ${hit.categories.take(3).join(' / ')}',
                    style: context.captionStyle,
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: () => onInstall(hit),
              child: const Text('安装'),
            ),
          ],
        ),
      ),
    );
  }
}
