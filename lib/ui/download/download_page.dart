import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/version_manifest.dart';
import '../../data/sources/download_source.dart';
import '../../providers/install_task_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/install/fabric_quilt_installer.dart';
import '../../services/install/forge_installer.dart';
import '../../services/install/rust_install_service.dart';
import '../../services/mod/modrinth_service.dart';
import '../../services/modpack/modpack_service.dart';
import '../../services/version/version_repository.dart';
import '../../services/download/http_service.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';

/// 下载中心（PCL2 式布局：左侧分类导航 + 右侧内容区）。
///
/// 分类对齐 PCL「自动安装」页与 HMCL「下载」页：
/// 正式版 / 快照 / 远古版 / Fabric / Forge / NeoForge / Quilt / OptiFine / 整合包。
class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

/// 下载分类
enum _Cat {
  release('正式版', Icons.verified_rounded, _CatGroup.vanilla),
  snapshot('快照与预览版', Icons.bolt_rounded, _CatGroup.vanilla),
  oldBeta('远古版', Icons.history_rounded, _CatGroup.vanilla),
  fabric('Fabric', Icons.auto_fix_high_rounded, _CatGroup.loader),
  forge('Forge', Icons.local_fire_department_rounded, _CatGroup.loader),
  neoforge('NeoForge', Icons.emoji_objects_rounded, _CatGroup.loader),
  quilt('Quilt', Icons.layers_rounded, _CatGroup.loader),
  optifine('OptiFine', Icons.high_quality_rounded, _CatGroup.loader),
  modpack('整合包', Icons.inventory_2_rounded, _CatGroup.modpack);

  final String label;
  final IconData icon;
  final _CatGroup group;
  const _Cat(this.label, this.icon, this.group);
}

enum _CatGroup { vanilla, loader, modpack }

class _DownloadPageState extends ConsumerState<DownloadPage> {
  VersionManifest? _manifest;
  bool _loading = true;
  String? _error;
  _Cat _cat = _Cat.release;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await VersionRepository.I.fetchManifest();
      if (!mounted) return;
      setState(() {
        _manifest = VersionManifest.fromJson(data as Map<String, dynamic>);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '版本清单获取失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Row(
              children: [
                Text('下载中心', style: context.titleStyle),
                const SizedBox(width: 10),
                Text('安装与导入（PCL / HMCL 式）', style: context.captionStyle),
                const Spacer(),
                Builder(builder: (context) {
                  final src = ref.watch(appSettingsProvider).downloadSourceIndex == 1
                      ? '官方源'
                      : 'BMCLAPI';
                  return Tooltip(
                    message: '可在 设置 → 下载 中切换',
                    child: Chip(
                      avatar: Icon(Icons.cloud_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      label: Text(src, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: '刷新清单',
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 8),
                            FilledButton.tonal(
                                onPressed: _load, child: const Text('重试')),
                          ],
                        ),
                      )
                    : isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                  width: 218, child: _SideNav(_cat, _select)),
                              const VerticalDivider(width: 1),
                              Expanded(child: _content()),
                            ],
                          )
                        : Column(
                            children: [
                              _NavChips(_cat, _select),
                              Expanded(child: _content()),
                            ],
                          ),
          ),
          // 底部全局安装进度（PCL2 式）
          const _InstallProgressCard(),
        ],
      ),
    );
  }

  void _select(_Cat c) => setState(() => _cat = c);

  Widget _content() {
    switch (_cat) {
      case _Cat.release:
      case _Cat.snapshot:
      case _Cat.oldBeta:
        return _VanillaList(
          manifest: _manifest!,
          cat: _cat,
          onInstall: _installVanilla,
        );
      case _Cat.fabric:
      case _Cat.forge:
      case _Cat.neoforge:
      case _Cat.quilt:
      case _Cat.optifine:
        return _LoaderPanel(cat: _cat, manifest: _manifest);
      case _Cat.modpack:
        return const _ModpackPanel();
    }
  }

  // ---------------- 原版安装 ----------------

  void _installVanilla(VersionEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _InstallSheet(
        entry: entry,
        onConfirm: (versionId) async {
          Navigator.pop(context);
          final task = ref.read(installTaskProvider.notifier);
          task.begin('安装原版 ${entry.id}');
          try {
            final service = ref.read(rustInstallServiceProvider).create(
                  RustInstallParams(
                    gameVersion: entry.id,
                    instanceName: versionId,
                    requiredJavaMajor: javaMajorFor(entry.id),
                  ),
                );
            await service.install(onProgress: task.update);
            task.end();
            _snack('$versionId 安装完成，可在「版本」页查看');
          } catch (e) {
            task.end(failed: true);
            _snack('安装失败: ${e is AppException ? e.userMessage : e}',
                error: true);
          } finally {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) ref.read(installTaskProvider.notifier).clear();
            });
          }
        },
      ),
    );
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}

// =====================================================================
// 侧边分类导航（PCL2 式）
// =====================================================================

class _SideNav extends StatelessWidget {
  final _Cat current;
  final ValueChanged<_Cat> onSelect;

  const _SideNav(this.current, this.onSelect);

  @override
  Widget build(BuildContext context) {
    final groups = <_CatGroup, List<_Cat>>{};
    for (final c in _Cat.values) {
      groups.putIfAbsent(c.group, () => []).add(c);
    }
    const groupLabels = {
      _CatGroup.vanilla: '原版游戏',
      _CatGroup.loader: '模组加载器',
      _CatGroup.modpack: '整合包',
    };

    return Container(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1A1B1E)
          : const Color(0xFFF6F7F9),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        children: [
          for (final g in _CatGroup.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
              child: Text(
                groupLabels[g]!,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(110),
                ),
              ),
            ),
            for (final c in groups[g]!) _buildNavItem(context, c, current == c, onSelect),
          ],
        ],
      ),
    );
  }

  Widget _buildNavItem(
      BuildContext context, _Cat c, bool selected, ValueChanged<_Cat> onSelect) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected
            ? (Theme.of(context).brightness == Brightness.dark
                ? Theme.of(context).colorScheme.primary
                : AppTheme.brandPrimary)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusM),
          onTap: () => onSelect(c),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  c.icon,
                  size: 19,
                  color: selected
                      ? Colors.white
                      : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(150),
                ),
                const SizedBox(width: 10),
                Text(
                  c.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withAlpha(200),
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

/// 窄屏分类 chips
class _NavChips extends StatelessWidget {
  final _Cat current;
  final ValueChanged<_Cat> onSelect;

  const _NavChips(this.current, this.onSelect);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        children: [
          for (final c in _Cat.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c.label),
                selected: current == c,
                onSelected: (_) => onSelect(c),
              ),
            ),
        ],
      ),
    );
  }
}

// =====================================================================
// 原版版本列表
// =====================================================================

class _VanillaList extends StatefulWidget {
  final VersionManifest manifest;
  final _Cat cat;
  final void Function(VersionEntry) onInstall;

  const _VanillaList({
    required this.manifest,
    required this.cat,
    required this.onInstall,
  });

  @override
  State<_VanillaList> createState() => _VanillaListState();
}

class _VanillaListState extends State<_VanillaList> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final versions = widget.manifest.versions.where((v) {
      final typeOk = switch (widget.cat) {
        _Cat.release => v.isRelease,
        _Cat.snapshot => v.isSnapshot,
        _Cat.oldBeta => v.isOld,
        _ => true,
      };
      return typeOk && v.id.contains(_search);
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
          child: TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: const InputDecoration(
              hintText: '搜索版本（如 1.20.1）',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisExtent: 84,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: versions.length,
            itemBuilder: (context, i) => _VersionCard(
              entry: versions[i],
              onInstall: () => widget.onInstall(versions[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 版本卡片
class _VersionCard extends StatelessWidget {
  final VersionEntry entry;
  final VoidCallback onInstall;

  const _VersionCard({required this.entry, required this.onInstall});

  Color get _typeColor {
    if (entry.isRelease) return const Color(0xFF16A34A);
    if (entry.isSnapshot) return const Color(0xFF4A9FF5);
    return const Color(0xFFFF9F43);
  }

  String get _typeLabel {
    if (entry.isRelease) return '正式版';
    if (entry.isSnapshot) return '快照';
    return '远古版';
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onInstall,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _typeColor.withAlpha(28),
              borderRadius: BorderRadius.circular(AppTheme.radiusM),
            ),
            child: Icon(
              entry.isRelease
                  ? Icons.verified_rounded
                  : entry.isSnapshot
                      ? Icons.bolt_rounded
                      : Icons.history_rounded,
              color: _typeColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.id,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  entry.releaseTime?.split('T').first ?? _typeLabel,
                  style: context.captionStyle,
                ),
              ],
            ),
          ),
          Icon(
            Icons.add_circle_outline_rounded,
            color: _typeColor,
          ),
        ],
      ),
    );
  }
}

/// 安装确认底部弹窗
class _InstallSheet extends StatelessWidget {
  final VersionEntry entry;
  final ValueChanged<String> onConfirm;

  const _InstallSheet({required this.entry, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(text: entry.id);
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        top: 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('安装 ${entry.id}', style: context.sectionTitle),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '版本目录名',
              helperText: '同目录名将覆盖；建议保留默认',
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => onConfirm(controller.text.trim()),
              icon: const Icon(Icons.download_rounded),
              label: const Text('开始安装（含原版文件，约 500MB）'),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// 加载器安装面板（每分类独立，PCL 式）
// =====================================================================

class _LoaderPanel extends ConsumerStatefulWidget {
  final _Cat cat;
  final VersionManifest? manifest;

  const _LoaderPanel({required this.cat, required this.manifest});

  @override
  ConsumerState<_LoaderPanel> createState() => _LoaderPanelState();
}

class _LoaderPanelState extends ConsumerState<_LoaderPanel> {
  final TextEditingController _gameVerCtrl = TextEditingController(text: '1.20.1');
  List<String> _loaderVersions = [];
  List<String> _releaseSuggestions = [];
  String? _selectedLoaderVersion;
  List<_OptiFineEntry> _optifineEntries = [];
  bool _loadingVersions = false;
  String _loader = 'fabric';

  @override
  void initState() {
    super.initState();
    _loader = switch (widget.cat) {
      _Cat.fabric => 'fabric',
      _Cat.forge => 'forge',
      _Cat.neoforge => 'neoforge',
      _Cat.quilt => 'quilt',
      _Cat.optifine => 'optifine',
      _ => 'fabric',
    };
    // 从清单取正式版作为游戏版本建议
    final releases = (widget.manifest?.versions ?? [])
        .where((v) => v.isRelease)
        .map((v) => v.id)
        .toList();
    _releaseSuggestions = releases;
  }

  @override
  void dispose() {
    _gameVerCtrl.dispose();
    super.dispose();
  }

  String get _gameVersion => _gameVerCtrl.text.trim();

  Future<void> _loadLoaderVersions() async {
    if (_gameVersion.isEmpty) {
      _snack('请先输入 Minecraft 版本', error: true);
      return;
    }
    setState(() => _loadingVersions = true);
    try {
      List<String> versions;
      switch (_loader) {
        case 'optifine':
          final raw = await HttpService.I.getJsonWithFallback(
              'https://bmclapi2.bangbang93.com/optifine/versionList');
          final list = (raw as List).cast<Map<String, dynamic>>();
          _optifineEntries = list
              .where((e) => e['mcversion'] == _gameVersion)
              .map(_OptiFineEntry.fromJson)
              .toList();
          versions = _optifineEntries.map((e) => e.label).toList();
        case 'fabric':
        case 'quilt':
          final source = DownloadSources.of(
              ref.read(appSettingsProvider).downloadSourceIndex == 1
                  ? DownloadSourceKind.official
                  : DownloadSourceKind.bmclapi);
          final dm = ref.read(downloadManagerProvider);
          versions = await FabricQuiltInstaller(ref, dm, source,
                  isQuilt: _loader == 'quilt')
              .fetchLoaderVersions(_gameVersion);
        case 'forge':
        case 'neoforge':
          final source = DownloadSources.of(
              ref.read(appSettingsProvider).downloadSourceIndex == 1
                  ? DownloadSourceKind.official
                  : DownloadSourceKind.bmclapi);
          final dm = ref.read(downloadManagerProvider);
          versions = await ForgeInstaller(ref, dm, source,
                  isNeoForge: _loader == 'neoforge')
              .fetchAllVersions(_gameVersion);
        default:
          versions = [];
      }
      if (!mounted) return;
      setState(() {
        _loaderVersions = versions;
        _selectedLoaderVersion = versions.firstOrNull;
        _loadingVersions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingVersions = false);
      _snack('获取版本列表失败: $e', error: true);
    }
  }

  Future<void> _install() async {
    final loaderVersion = _selectedLoaderVersion;
    if (loaderVersion == null) return;
    final task = ref.read(installTaskProvider.notifier);
    final loaderName = switch (_loader) {
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'neoforge' => 'NeoForge',
      'quilt' => 'Quilt',
      'optifine' => 'OptiFine',
      _ => _loader,
    };
    task.begin('安装 $loaderName $loaderVersion');
    try {
      final factory = ref.read(rustInstallServiceProvider);
      final String resultId;
      switch (_loader) {
        case 'optifine':
          final entry =
              _optifineEntries.firstWhere((e) => e.label == loaderVersion);
          final name = 'OptiFine-${entry.mc}-${entry.type}-${entry.patch}';
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: entry.mc,
            instanceName: name,
            optifine: SimpleOptiFine(
              inherit: entry.mc,
              displayName: '${entry.mc} ${entry.type} ${entry.patch}',
              fileName: entry.filename,
              isPreview: entry.filename.startsWith('preview_'),
            ),
            requiredJavaMajor: javaMajorFor(entry.mc),
          ))
              .install(onProgress: task.update);
        case 'fabric':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'fabric-loader-$loaderVersion-$_gameVersion',
            fabricVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: task.update);
        case 'quilt':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'quilt-loader-$loaderVersion-$_gameVersion',
            quiltVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: task.update);
        case 'forge':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'forge-$_gameVersion-$loaderVersion',
            forgeVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: task.update);
        case 'neoforge':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'neoforge-$_gameVersion-$loaderVersion',
            neoforgeVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: task.update);
        default:
          resultId = _gameVersion;
      }
      task.end();
      _snack('$resultId 安装完成，可在「版本」页查看');
    } catch (e) {
      task.end(failed: true);
      _snack('安装失败: ${e is AppException ? e.userMessage : e}', error: true);
    } finally {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) ref.read(installTaskProvider.notifier).clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final desc = switch (_loader) {
      'optifine' => 'OptiFine 提供高清修复与性能优化，依赖对应原版版本。',
      'forge' => 'Forge 是最主流的模组加载器，安装过程需执行官方处理器链（约 1~3 分钟）。',
      'neoforge' => 'NeoForge 是 Forge 的社区延续分支，1.20.1+ 推荐。',
      'quilt' => 'Quilt 兼容 Fabric 模组生态。',
      _ => 'Fabric 轻量模组加载器，兼容大量现代模组。',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader('安装 $_loader',
                  subtitle: desc),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 游戏版本输入 + 正式版快捷下拉
                  Expanded(
                    child: TextField(
                      controller: _gameVerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Minecraft 版本',
                        helperText: '如 1.20.1 / 1.21.4',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_releaseSuggestions.isNotEmpty)
                    DropdownButton<String>(
                      value: null,
                      underline: const SizedBox.shrink(),
                      hint: const Text('从正式版选择'),
                      items: _releaseSuggestions
                          .take(30)
                          .map((v) => DropdownMenuItem(
                                value: v,
                                child: Text(v,
                                    style: const TextStyle(fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _gameVerCtrl.text = v);
                        }
                      },
                    ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed:
                        _loadingVersions ? null : _loadLoaderVersions,
                    child: Text(_loadingVersions ? '获取中...' : '获取版本列表'),
                  ),
                ],
              ),
              if (_loadingVersions) ...[
                const SizedBox(height: 18),
                const LinearProgressIndicator(),
              ],
              if (_loaderVersions.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButton<String>(
                  value: _selectedLoaderVersion,
                  isExpanded: true,
                  hint: Text('选择 $_loader 版本'),
                  items: _loaderVersions
                      .map((v) => DropdownMenuItem(
                            value: v,
                            child: Text(v,
                                style: const TextStyle(fontSize: 14)),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _selectedLoaderVersion = v),
                ),
              ] else if (!_loadingVersions &&
                  _loader == 'optifine' &&
                  _gameVersion.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('若列表为空，说明 $_gameVersion 暂无 OptiFine 版本',
                    style: context.captionStyle),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selectedLoaderVersion == null ||
                          _loadingVersions
                      ? null
                      : _install,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    '安装 $_loader $_selectedLoaderVersion',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '提示：安装与导入均遵循 PCL / HMCL 的目录规范，文件保存在启动器目录下的 .minecraft 中；'
          '版本隔离可在「版本 → 版本设置」中调整。',
          style: context.captionStyle,
        ),
      ],
    );
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}

// =====================================================================
// 整合包（Modrinth 在线安装）
// =====================================================================

class _ModpackPanel extends ConsumerStatefulWidget {
  const _ModpackPanel();

  @override
  ConsumerState<_ModpackPanel> createState() => _ModpackPanelState();
}

class _ModpackPanelState extends ConsumerState<_ModpackPanel> {
  final _searchCtrl = TextEditingController();
  List<ModrinthSearchHit> _hits = [];
  bool _searching = false;
  final Set<String> _installing = {};

  Future<void> _search() async {
    setState(() => _searching = true);
    try {
      final hits = await ModrinthService.I.search(
        query: _searchCtrl.text.trim(),
        projectType: 'modpack',
        loader: '',
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      _snack('搜索失败: $e', error: true);
    }
  }

  Future<void> _install(ModrinthSearchHit hit) async {
    setState(() => _installing.add(hit.projectId));
    final task = ref.read(installTaskProvider.notifier);
    task.begin('安装整合包「${hit.title}」');
    try {
      // 1. 取最新版本的主文件（.mrpack）
      final versions =
          await ModrinthService.I.getVersions(projectId: hit.projectId);
      if (versions.isEmpty) {
        throw const NetworkException('该整合包暂无可下载版本');
      }
      final primary = versions.first.primaryFile;
      if (primary == null) {
        throw const NetworkException('整合包文件缺失');
      }

      // 2. 下载 .mrpack 到临时目录
      final tmpPath = p.join(
          Directory.systemTemp.path, 'fmcl_modpack_${primary.filename}');
      await ModrinthService.I.downloadMod(
          url: primary.url, savePath: tmpPath);

      // 3. 走统一整合包安装管线（含基础游戏 + 加载器 + 文件 + overrides）
      final versionId = await ref.read(modpackServiceProvider).install(
            mrpackPath: tmpPath,
            onProgress: task.update,
          );
      task.end();
      _snack('整合包已安装为版本「$versionId」');
      try {
        File(tmpPath).deleteSync();
      } catch (_) {}
    } catch (e) {
      task.end(failed: true);
      _snack('安装失败: ${e is AppException ? e.userMessage : e}', error: true);
    } finally {
      if (mounted) setState(() => _installing.remove(hit.projectId));
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) ref.read(installTaskProvider.notifier).clear();
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: '搜索 Modrinth 整合包（如 RLCraft / Fabric Essential）',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: Text(_searching ? '搜索中' : '搜索'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator())
              : _hits.isEmpty
                  ? Center(
                      child: Text('输入关键词搜索整合包（支持 .mrpack 一键安装）',
                          style: context.captionStyle))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      itemCount: _hits.length,
                      itemBuilder: (context, i) {
                        final hit = _hits[i];
                        final busy = _installing.contains(hit.projectId);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AppCard(
                            child: Row(
                              children: [
                                if (hit.iconUrl != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                        AppTheme.radiusM),
                                    child: Image.network(
                                      hit.iconUrl!,
                                      width: 44,
                                      height: 44,
                                      errorBuilder: (_, _, _) =>
                                          const Icon(Icons.inventory_2_rounded),
                                    ),
                                  )
                                else
                                  const Icon(Icons.inventory_2_rounded),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(hit.title,
                                          style: const TextStyle(
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 2),
                                      Text(
                                        hit.description,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.captionStyle,
                                      ),
                                      Text(
                                        '${hit.downloads} 次下载',
                                        style: context.captionStyle,
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed:
                                      busy ? null : () => _install(hit),
                                  child: busy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Text('安装'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}

// =====================================================================
// 全局安装进度卡（PCL2 式底部进度条）
// =====================================================================

class _InstallProgressCard extends ConsumerWidget {
  const _InstallProgressCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(installTaskProvider);
    if (!task.active) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    value: task.progress,
                    color: task.failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${task.title} · ${task.message}',
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: RustInstallService.cancelLast,
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 5,
                color: task.failed
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 依据 MC 版本推导所需 Java 主版本
int javaMajorFor(String mc) {
  final m = RegExp(r'^1\.([0-9]+)').firstMatch(mc);
  final minor = int.tryParse(m?.group(1) ?? '0') ?? 0;
  final rest = mc.split('.').skip(2).firstOrNull ?? '0';
  final patch = int.tryParse(rest) ?? 0;
  if (minor >= 21 || (minor == 20 && patch >= 5)) return 21;
  if (minor >= 18) return 17;
  if (minor == 17) return 16;
  return 8;
}

/// BMCLAPI OptiFine 版本条目
class _OptiFineEntry {
  final String mc;
  final String type;
  final String patch;
  final String filename;

  const _OptiFineEntry({
    required this.mc,
    required this.type,
    required this.patch,
    required this.filename,
  });

  factory _OptiFineEntry.fromJson(Map<String, dynamic> json) {
    return _OptiFineEntry(
      mc: json['mcversion'] as String? ?? '',
      type: json['type'] as String? ?? 'HD_U',
      patch: json['patch'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
    );
  }

  String get label => '$mc $type-$patch';
}
