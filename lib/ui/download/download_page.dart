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
import '../../services/download/http_service.dart';
import '../../services/install/fabric_quilt_installer.dart';
import '../../services/install/forge_installer.dart';
import '../../services/install/installer_base.dart';
import '../../services/install/rust_install_service.dart';
import '../../services/mod/modrinth_service.dart';
import '../../services/modpack/modpack_service.dart';
import '../../services/resource/resource_service.dart';
import '../../services/version/local_version_manager.dart';
import '../../services/version/version_repository.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';

/// 下载页 —— 全部仿照 PCL2 的 UI 与处理方式。
///
/// 左侧分类导航（参考上传项目的下载界面）：
/// - 原版游戏：Minecraft（草方块图标配）——加载器（Fabric / Forge / NeoForge /
///   Quilt / OptiFine）包含在原版下载流程中：选版本 → 选加载器 → 开始下载
/// - 资源：Mod / 资源包 / 光影包（Modrinth 在线获取，安装到版本隔离感知目录）
/// - 整合包：Modrinth 整合包一键安装（.mrpack）
class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

/// 页签（对应左侧分类）
enum _Tab {
  minecraft('原版游戏'),
  mod('Mod'),
  resourcepack('资源包'),
  shader('光影包'),
  modpack('整合包');

  final String label;
  const _Tab(this.label);
}

class _DownloadPageState extends ConsumerState<DownloadPage> {
  VersionManifest? _manifest;
  bool _loading = true;
  String? _error;
  _Tab _tab = _Tab.minecraft;

  /// 懒构建并缓存各页签内容（PCL2 式：切页不丢状态）
  final Map<_Tab, Widget> _cachedViews = {};

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
        _cachedViews.clear(); // 清单刷新后重建各页签
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
                Text('下载', style: context.titleStyle),
                const SizedBox(width: 10),
                Text('安装新版本 · 获取资源（PCL2 式）',
                    style: context.captionStyle),
                const Spacer(),
                Builder(builder: (context) {
                  final src =
                      ref.watch(appSettingsProvider).downloadSourceIndex == 1
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
                                  width: 200, child: _LeftNav(_tab, _select)),
                              const VerticalDivider(width: 1),
                              Expanded(child: _content()),
                            ],
                          )
                        : Column(
                            children: [
                              _NavChips(_tab, _select),
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

  void _select(_Tab t) => setState(() => _tab = t);

  Widget _content() {
    // 懒构建 + IndexedStack 保持各页签状态
    _cachedViews.putIfAbsent(_tab, () => _buildView(_tab));
    return IndexedStack(
      index: _Tab.values.indexOf(_tab),
      children: [
        for (final t in _Tab.values) _cachedViews[t] ?? const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildView(_Tab t) {
    final manifest = _manifest!;
    return switch (t) {
      _Tab.minecraft => _MinecraftInstallView(manifest: manifest),
      _Tab.mod => _ResourceView(
          key: const ValueKey('res-mod'),
          kind: ResourceKind.mod,
          manifest: manifest),
      _Tab.resourcepack => _ResourceView(
          key: const ValueKey('res-rp'),
          kind: ResourceKind.resourcepack,
          manifest: manifest),
      _Tab.shader => _ResourceView(
          key: const ValueKey('res-shader'),
          kind: ResourceKind.shader,
          manifest: manifest),
      _Tab.modpack => const _ModpackView(),
    };
  }
}

// =====================================================================
// 左侧分类导航（PCL2 式：分组标题 + 方块选中态；原版使用草方块图片）
// =====================================================================

class _LeftNav extends StatelessWidget {
  final _Tab current;
  final ValueChanged<_Tab> onSelect;

  const _LeftNav(this.current, this.onSelect);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1A1B1E)
          : const Color(0xFFF6F7F9),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        children: [
          _sectionLabel(context, '原版游戏'),
          _minecraftItem(context),
          const SizedBox(height: 12),
          _sectionLabel(context, '资源'),
          _item(context, _Tab.mod, Icons.extension_rounded),
          _item(context, _Tab.resourcepack, Icons.palette_rounded),
          _item(context, _Tab.shader, Icons.wb_sunny_rounded),
          const SizedBox(height: 12),
          _sectionLabel(context, '整合包'),
          _item(context, _Tab.modpack, Icons.inventory_2_rounded),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(110),
          ),
        ),
      );

  /// 「Minecraft」分类项：使用草方块像素画图片（原版图片 = 草方块）
  Widget _minecraftItem(BuildContext context) {
    final selected = current == _Tab.minecraft;
    return _navContainer(
      context,
      selected: selected,
      onTap: () => onSelect(_Tab.minecraft),
      leading: Image.asset(
        'assets/img/grass_block.png',
        width: 22,
        height: 22,
        filterQuality: FilterQuality.none,
      ),
      label: 'Minecraft',
    );
  }

  Widget _item(BuildContext context, _Tab tab, IconData icon) {
    return _navContainer(
      context,
      selected: current == tab,
      onTap: () => onSelect(tab),
      leading: Icon(
        icon,
        size: 19,
        color: current == tab
            ? Colors.white
            : Theme.of(context).colorScheme.onSurface.withAlpha(150),
      ),
      label: tab.label,
    );
  }

  Widget _navContainer(
    BuildContext context, {
    required bool selected,
    required VoidCallback onTap,
    required Widget leading,
    required String label,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected
            ? (isDark
                ? Theme.of(context).colorScheme.primary
                : AppTheme.brandPrimary)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusM),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
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
  final _Tab current;
  final ValueChanged<_Tab> onSelect;

  const _NavChips(this.current, this.onSelect);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        children: [
          for (final t in _Tab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(t.label),
                selected: current == t,
                onSelected: (_) => onSelect(t),
              ),
            ),
        ],
      ),
    );
  }
}

// =====================================================================
// 原版安装（参考上传项目的下载界面 UI）
// 左：原版版本列表（正式版 / 快照版 / 远古版 / 全部）
// 右：版本名称 + 加载器卡片（Fabric / Forge / NeoForge / Quilt / OptiFine）
// 加载器包含在原版下载中：一次安装完成 原版 + 加载器
// =====================================================================

class _MinecraftInstallView extends ConsumerStatefulWidget {
  final VersionManifest manifest;

  const _MinecraftInstallView({required this.manifest});

  @override
  ConsumerState<_MinecraftInstallView> createState() =>
      _MinecraftInstallViewState();
}

class _MinecraftInstallViewState extends ConsumerState<_MinecraftInstallView> {
  String _filter = 'release'; // release | snapshot | old | all
  String _search = '';
  VersionEntry? _selected;
  final TextEditingController _nameCtrl = TextEditingController();

  // ---- 加载器选择状态 ----
  String _loaderType = ''; // '' | fabric | forge | neoforge | quilt | optifine
  String? _loaderVersion;
  _OptiFineEntry? _optifineEntry;
  List<String> _fabricList = [];
  List<String> _forgeList = [];
  List<String> _neoforgeList = [];
  List<String> _quiltList = [];
  List<_OptiFineEntry> _optifineList = [];
  bool _loadingVersions = false;
  bool _installing = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  List<VersionEntry> get _filteredVersions {
    final all = widget.manifest.versions.where((v) {
      return switch (_filter) {
        'release' => v.isRelease,
        'snapshot' => v.isSnapshot,
        'old' => v.isOld,
        _ => true,
      };
    }).toList();
    if (_search.trim().isEmpty) return all;
    return all
        .where((v) => v.id.toLowerCase().contains(_search.trim().toLowerCase()))
        .toList();
  }

  String get _defaultName {
    final mc = _selected?.id ?? '';
    if (mc.isEmpty) return '';
    return switch (_loaderType) {
      'fabric' when _loaderVersion != null => '$mc-Fabric-$_loaderVersion',
      'forge' when _loaderVersion != null => '$mc-Forge-$_loaderVersion',
      'neoforge' when _loaderVersion != null => '$mc-NeoForge-$_loaderVersion',
      'quilt' when _loaderVersion != null => '$mc-Quilt-$_loaderVersion',
      'optifine' when _optifineEntry != null =>
        'OptiFine-${_optifineEntry!.mc}-${_optifineEntry!.type}-${_optifineEntry!.patch}',
      _ => mc,
    };
  }

  /// 当前加载器已选中的展示文本
  String get _selectedLoaderLabel {
    switch (_loaderType) {
      case 'fabric':
      case 'forge':
      case 'neoforge':
      case 'quilt':
        return _loaderVersion ?? '';
      case 'optifine':
        return _optifineEntry?.label ?? '';
      default:
        return '';
    }
  }

  bool _mcAtLeast(int major, int minor) {
    final mc = _selected?.id ?? '';
    final parts = mc.split('.');
    if (parts.length < 2) return false;
    final m = int.tryParse(parts[0]) ?? 0;
    final n = int.tryParse(parts[1]) ?? 0;
    if (m > major) return true;
    if (m == major && n >= minor) return true;
    return false;
  }

  bool get _allowFabric => _mcAtLeast(1, 14);
  bool get _allowQuilt => _mcAtLeast(1, 14);
  bool get _allowNeoForge => _mcAtLeast(1, 20);

  List<String> _listFor(String type) => switch (type) {
        'fabric' => _fabricList,
        'forge' => _forgeList,
        'neoforge' => _neoforgeList,
        'quilt' => _quiltList,
        _ => const [],
      };

  void _clearLoaderLists() {
    _fabricList = [];
    _forgeList = [];
    _neoforgeList = [];
    _quiltList = [];
    _optifineList = [];
  }

  void _selectVersion(VersionEntry v) {
    if (_installing) return;
    setState(() {
      _selected = v;
      _loaderType = '';
      _loaderVersion = null;
      _optifineEntry = null;
      _clearLoaderLists();
      _nameCtrl.text = v.id;
    });
  }

  void _selectLoader(String type) {
    if (_installing) return;
    setState(() {
      if (_loaderType == type) {
        _loaderType = '';
        _loaderVersion = null;
        _optifineEntry = null;
        _clearLoaderLists();
      } else {
        _loaderType = type;
        _loaderVersion = null;
        _optifineEntry = null;
        _clearLoaderLists();
        _loadLoaderVersions(type);
      }
      _nameCtrl.text = _defaultName;
    });
  }

  void _clearLoaderSelection() {
    setState(() {
      _loaderVersion = null;
      _optifineEntry = null;
      _nameCtrl.text = _defaultName;
    });
  }

  Future<void> _loadLoaderVersions(String type) async {
    final mc = _selected!.id;
    setState(() => _loadingVersions = true);
    try {
      switch (type) {
        case 'optifine':
          final raw = await HttpService.I.getJsonWithFallback(
              'https://bmclapi2.bangbang93.com/optifine/versionList');
          final list = (raw as List).cast<Map<String, dynamic>>();
          final entries = list
              .where((e) => e['mcversion'] == mc)
              .map(_OptiFineEntry.fromJson)
              .toList();
          if (!mounted) return;
          setState(() {
            _optifineList = entries;
            _optifineEntry = entries.firstOrNull;
            _nameCtrl.text = _defaultName;
          });
        case 'fabric' || 'quilt':
          final source = DownloadSources.of(
              ref.read(appSettingsProvider).downloadSourceIndex == 1
                  ? DownloadSourceKind.official
                  : DownloadSourceKind.bmclapi);
          final versions = await FabricQuiltInstaller(
                  ref, ref.read(downloadManagerProvider), source,
                  isQuilt: type == 'quilt')
              .fetchLoaderVersions(mc);
          if (!mounted) return;
          setState(() {
            if (type == 'fabric') _fabricList = versions;
            if (type == 'quilt') _quiltList = versions;
            _loaderVersion = versions.firstOrNull;
            _nameCtrl.text = _defaultName;
          });
        case 'forge' || 'neoforge':
          final source = DownloadSources.of(
              ref.read(appSettingsProvider).downloadSourceIndex == 1
                  ? DownloadSourceKind.official
                  : DownloadSourceKind.bmclapi);
          final versions = await ForgeInstaller(
                  ref, ref.read(downloadManagerProvider), source,
                  isNeoForge: type == 'neoforge')
              .fetchAllVersions(mc);
          if (!mounted) return;
          setState(() {
            if (type == 'forge') _forgeList = versions;
            if (type == 'neoforge') _neoforgeList = versions;
            _loaderVersion = versions.firstOrNull;
            _nameCtrl.text = _defaultName;
          });
      }
    } catch (e) {
      if (!mounted) return;
      _snack('获取 $type 版本列表失败: $e', error: true);
    } finally {
      if (mounted) setState(() => _loadingVersions = false);
    }
  }

  bool get _canInstall =>
      _selected != null &&
      !_installing &&
      (_loaderType == '' ||
          (_loaderType == 'optifine'
              ? _optifineEntry != null
              : _loaderVersion != null));

  Future<void> _startInstall() async {
    final mc = _selected!.id;
    final name =
        _nameCtrl.text.trim().isEmpty ? _defaultName : _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('请填写版本名称', error: true);
      return;
    }
    if (_loaderType != '' &&
        _loaderType != 'optifine' &&
        _loaderVersion == null) {
      _snack('当前选择的加载器暂无可用版本，请先选择其它加载器或版本', error: true);
      return;
    }

    // PCL 处理方式：同名版本先确认覆盖
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    if (Directory(p.join(gameDir, 'versions', name)).existsSync()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('版本已存在'),
          content: Text('版本「$name」已存在，继续安装将覆盖该版本目录。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('覆盖安装')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;

    setState(() => _installing = true);
    final task = ref.read(installTaskProvider.notifier);
    task.begin('安装 $name');
    try {
      final entry = _optifineEntry;
      await ref
          .read(rustInstallServiceProvider)
          .create(RustInstallParams(
            gameVersion: mc,
            instanceName: name,
            requiredJavaMajor: javaMajorFor(mc),
            fabricVersion:
                _loaderType == 'fabric' ? _loaderVersion : null,
            quiltVersion: _loaderType == 'quilt' ? _loaderVersion : null,
            forgeVersion: _loaderType == 'forge' ? _loaderVersion : null,
            neoforgeVersion:
                _loaderType == 'neoforge' ? _loaderVersion : null,
            optifine: (_loaderType == 'optifine' && entry != null)
                ? SimpleOptiFine(
                    inherit: entry.mc,
                    displayName: '${entry.mc} ${entry.type} ${entry.patch}',
                    fileName: entry.filename,
                    isPreview: entry.filename.startsWith('preview_'),
                  )
                : null,
          ))
          .install(onProgress: task.update);
      task.end();
      _snack('$name 安装完成，可在「版本」页查看');
    } catch (e) {
      task.end(failed: true);
      _snack('安装失败: ${e is AppException ? e.userMessage : e}', error: true);
    } finally {
      if (mounted) setState(() => _installing = false);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) ref.read(installTaskProvider.notifier).clear();
      });
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _topBar(context),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: _versionList(context)),
              const VerticalDivider(width: 1),
              Expanded(flex: 4, child: _configPane(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Text('原版版本',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withAlpha(200))),
          const SizedBox(width: 14),
          SizedBox(
            width: 200,
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索版本…',
                hintStyle: TextStyle(
                    fontSize: 12.5, color: scheme.onSurface.withAlpha(90)),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: scheme.onSurface.withAlpha(110)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
              ),
            ),
          ),
          const Spacer(),
          _chip('正式版', 'release'),
          _chip('快照版', 'snapshot'),
          _chip('远古版', 'old'),
          _chip('全部', 'all'),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: _filter == value,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => setState(() => _filter = value),
      ),
    );
  }

  Widget _versionList(BuildContext context) {
    final versions = _filteredVersions;
    if (versions.isEmpty) {
      return Center(
          child: Text('没有符合条件的版本',
              style: context.captionStyle));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      itemCount: versions.length,
      itemBuilder: (context, i) {
        final v = versions[i];
        final sel = _selected?.id == v.id;
        final scheme = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.only(bottom: 3),
          decoration: BoxDecoration(
            color: sel
                ? scheme.primary.withAlpha(26)
                : scheme.surfaceContainerHighest.withAlpha(50),
            borderRadius: BorderRadius.circular(8),
            border: sel
                ? Border.all(color: scheme.primary.withAlpha(80))
                : Border.all(color: Colors.transparent),
          ),
          child: ListTile(
            dense: true,
            leading: Image.asset(
              'assets/img/grass_block.png',
              width: 20,
              height: 20,
              filterQuality: FilterQuality.none,
            ),
            title: Text(v.id,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight:
                        sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel
                        ? scheme.primary
                        : scheme.onSurface.withAlpha(210))),
            subtitle: Text(_typeLabel(v.type),
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withAlpha(100))),
            trailing: sel
                ? Icon(Icons.check_rounded,
                    size: 18, color: scheme.primary)
                : null,
            onTap: () => _selectVersion(v),
          ),
        );
      },
    );
  }

  Widget _configPane(BuildContext context) {
    if (_selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/img/grass_block.png',
              width: 40,
              height: 40,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(height: 8),
            Text('请先在左侧选择一个原版版本',
                style: context.captionStyle),
          ],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _nameCtrl,
                  enabled: !_installing,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: '版本名称',
                    hintText: _defaultName,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 18),
                Text('选择加载器（可留空，仅安装原版）',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface.withAlpha(200))),
                const SizedBox(height: 10),
                if (_allowFabric)
                  _loaderCard('Fabric', Icons.auto_fix_high_rounded, 'fabric'),
                _loaderCard(
                    'Forge', Icons.local_fire_department_rounded, 'forge'),
                if (_allowNeoForge)
                  _loaderCard(
                      'NeoForge', Icons.emoji_objects_rounded, 'neoforge'),
                if (_allowQuilt)
                  _loaderCard('Quilt', Icons.layers_rounded, 'quilt'),
                _loaderCard(
                    'OptiFine', Icons.high_quality_rounded, 'optifine'),
              ],
            ),
          ),
        ),
        // 底部：开始下载（PCL2 式主按钮）
        Container(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          decoration: BoxDecoration(
            border:
                Border(top: BorderSide(color: scheme.outlineVariant.withAlpha(60))),
          ),
          child: SizedBox(
            height: 44,
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _canInstall ? _startInstall : null,
              icon: _installing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: scheme.onPrimary))
                  : const Icon(Icons.download_rounded, size: 18),
              label: Text(_installing ? '安装中…' : '开始下载'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _loaderCard(String title, IconData icon, String type) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _loaderType == type;
    final hasSel = _selectedLoaderLabel.isNotEmpty && _loaderType == type;
    final active = expanded || hasSel;
    final titleText =
        (!expanded && hasSel) ? '$title ${_selectedLoaderLabel}' : title;
    final list = type == 'optifine' ? null : _listFor(type);
    final count = type == 'optifine' ? _optifineList.length : list!.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withAlpha(14)
            : scheme.surfaceContainerHighest.withAlpha(50),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color:
                active ? scheme.primary.withAlpha(80) : scheme.outlineVariant.withAlpha(70)),
      ),
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: Icon(icon,
                size: 20,
                color: active ? scheme.primary : scheme.onSurface.withAlpha(130)),
            title: Text(titleText,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: active ? scheme.primary : scheme.onSurface.withAlpha(210))),
            trailing: (!expanded && hasSel)
                ? InkWell(
                    onTap: _clearLoaderSelection,
                    borderRadius: BorderRadius.circular(12),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: scheme.onSurface.withAlpha(140)))
                : Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 20, color: scheme.onSurface.withAlpha(110)),
            onTap: () => _selectLoader(type),
          ),
          if (expanded) _loaderVersionList(type, count),
        ],
      ),
    );
  }

  Widget _loaderVersionList(String type, int count) {
    final scheme = Theme.of(context).colorScheme;
    if (_loadingVersions) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (count == 0) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('该游戏版本暂无可用的 $type 版本',
            style: context.captionStyle),
      );
    }
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          itemCount: count,
          itemBuilder: (context, i) {
            final String label;
            if (type == 'optifine') {
              label = _optifineList[i].label;
            } else {
              label = _listFor(type)[i];
            }
            final sel = type == 'optifine'
                ? _optifineEntry?.label == label
                : _loaderVersion == label;
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: sel
                          ? scheme.primary
                          : scheme.onSurface.withAlpha(210),
                      fontWeight:
                          sel ? FontWeight.w600 : FontWeight.w400)),
              trailing: sel
                  ? Icon(Icons.check_rounded, size: 16, color: scheme.primary)
                  : null,
              onTap: () {
                setState(() {
                  if (type == 'optifine') {
                    _optifineEntry = _optifineList[i];
                  } else {
                    _loaderVersion = label;
                  }
                  _nameCtrl.text = _defaultName;
                });
              },
            );
          },
        ),
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

String _typeLabel(String type) => switch (type) {
      'release' => '正式版',
      'snapshot' => '快照版',
      'old_beta' => 'Beta',
      'old_alpha' => 'Alpha',
      _ => type,
    };

// =====================================================================
// 资源获取（Mod / 资源包 / 光影包，Modrinth 在线搜索 + 安装到指定版本）
// =====================================================================

class _ResourceView extends ConsumerStatefulWidget {
  final ResourceKind kind;
  final VersionManifest manifest;

  const _ResourceView({
    super.key,
    required this.kind,
    required this.manifest,
  });

  @override
  ConsumerState<_ResourceView> createState() => _ResourceViewState();
}

class _ResourceViewState extends ConsumerState<_ResourceView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _loaderFilter = 'fabric';
  String _gameVer = '';
  List<ModrinthSearchHit> _hits = [];
  bool _searching = false;
  String? _installingId;
  List<LocalVersion> _locals = [];
  String? _target;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final locals = await LocalVersionManager.I.listVersions(gameDir);
    if (!mounted) return;
    setState(() {
      _locals = locals;
      _target = locals.firstOrNull?.id;
    });
    _search();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    try {
      final hits = await ModrinthService.I.search(
        query: _searchCtrl.text.trim(),
        projectType: widget.kind.apiType,
        loader: _loaderFilter,
        gameVersion: _gameVer.isEmpty ? null : _gameVer,
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
    final target = _target;
    if (target == null) {
      _snack('请先在「下载 → 原版游戏」安装一个版本', error: true);
      return;
    }
    final task = ref.read(installTaskProvider.notifier);
    setState(() => _installingId = hit.projectId);
    task.begin('安装${widget.kind.label}「${hit.title}」');
    try {
      final msg = await ref.read(resourceInstallServiceProvider).install(
            hit: hit,
            kind: widget.kind,
            versionId: target,
            gameVersion: ResourceInstallService.guessGameVersion(target),
            loader: _loaderFilter,
            onProgress: (m) =>
                task.update(InstallProgress('download', m)),
          );
      task.end();
      _snack(msg);
    } catch (e) {
      task.end(failed: true);
      _snack('安装失败: ${e is AppException ? e.userMessage : e}', error: true);
    } finally {
      if (mounted) setState(() => _installingId = null);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) ref.read(installTaskProvider.notifier).clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMod = widget.kind == ResourceKind.mod;
    final releaseVersions = widget.manifest.versions
        .where((v) => v.isRelease)
        .take(40)
        .map((v) => v.id)
        .toList();
    return Column(
      children: [
        // 搜索栏
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onSubmitted: (_) => _search(),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: '搜索${widget.kind.label}…',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _searching ? null : _search,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 14)),
                child: Text(_searching ? '搜索中…' : '搜索'),
              ),
            ],
          ),
        ),
        // 筛选栏
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
          child: Row(
            children: [
              Text('安装到版本',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurface.withAlpha(140))),
              const SizedBox(width: 8),
              _targetDropdown(),
              const SizedBox(width: 18),
              Text('游戏版本',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurface.withAlpha(140))),
              const SizedBox(width: 8),
              _gameVerDropdown(releaseVersions),
              if (isMod) ...[
                const SizedBox(width: 18),
                Text('加载器',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurface.withAlpha(140))),
                const SizedBox(width: 8),
                _loaderDropdown(),
              ],
              const Spacer(),
              Text('${_hits.length} 个结果',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurface.withAlpha(80))),
            ],
          ),
        ),
        Expanded(
          child: _searching && _hits.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _hits.isEmpty
                  ? Center(
                      child: Text('输入关键词搜索${widget.kind.label}',
                          style: context.captionStyle))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                      itemCount: _hits.length,
                      itemBuilder: (context, i) =>
                          _resourceCard(context, _hits[i]),
                    ),
        ),
      ],
    );
  }

  Widget _targetDropdown() {
    if (_locals.isEmpty) {
      return Tooltip(
        message: '请先安装一个游戏版本',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('尚无版本',
              style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(110))),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withAlpha(80)),
      ),
      child: DropdownButton<String>(
        value: _target,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        style: const TextStyle(fontSize: 12.5),
        items: _locals
            .map((v) => DropdownMenuItem(
                value: v.id,
                child: Text(v.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5))))
            .toList(),
        onChanged: (v) => setState(() => _target = v),
      ),
    );
  }

  Widget _gameVerDropdown(List<String> releases) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withAlpha(80)),
      ),
      child: DropdownButton<String>(
        value: _gameVer,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        style: const TextStyle(fontSize: 12.5),
        items: [
          const DropdownMenuItem(value: '', child: Text('全部')),
          for (final v in releases)
            DropdownMenuItem(value: v, child: Text(v)),
        ],
        onChanged: (v) {
          setState(() => _gameVer = v ?? '');
          _search();
        },
      ),
    );
  }

  Widget _loaderDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withAlpha(80)),
      ),
      child: DropdownButton<String>(
        value: _loaderFilter,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        style: const TextStyle(fontSize: 12.5),
        items: const [
          DropdownMenuItem(value: 'fabric', child: Text('Fabric')),
          DropdownMenuItem(value: 'forge', child: Text('Forge')),
          DropdownMenuItem(value: 'quilt', child: Text('Quilt')),
          DropdownMenuItem(value: 'neoforge', child: Text('NeoForge')),
        ],
        onChanged: (v) {
          setState(() => _loaderFilter = v ?? 'fabric');
          _search();
        },
      ),
    );
  }

  Widget _resourceCard(BuildContext context, ModrinthSearchHit hit) {
    final busy = _installingId == hit.projectId;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(50),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withAlpha(70)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: scheme.onSurface.withAlpha(12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: hit.iconUrl != null && hit.iconUrl!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        hit.iconUrl!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => Icon(
                            _kindIcon,
                            color: scheme.onSurface.withAlpha(70),
                            size: 22),
                      ),
                    )
                  : Icon(_kindIcon,
                      color: scheme.onSurface.withAlpha(70), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(hit.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.captionStyle),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(Icons.download_rounded,
                          size: 12,
                          color: scheme.onSurface.withAlpha(90)),
                      const SizedBox(width: 4),
                      Text(_fmtCount(hit.downloads),
                          style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.onSurface.withAlpha(110))),
                      const SizedBox(width: 8),
                      ...hit.categories
                          .take(3)
                          .map((c) => Container(
                                margin:
                                    const EdgeInsets.only(right: 5),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withAlpha(16),
                                  borderRadius:
                                      BorderRadius.circular(6),
                                ),
                                child: Text(_fmtCategory(c),
                                    style: TextStyle(
                                        fontSize: 9.5,
                                        color:
                                            scheme.onSurface.withAlpha(150))),
                              )),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonal(
              onPressed: busy ? null : () => _install(hit),
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12)),
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('安装', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }

  IconData get _kindIcon => switch (widget.kind) {
        ResourceKind.mod => Icons.extension_rounded,
        ResourceKind.resourcepack => Icons.palette_rounded,
        ResourceKind.shader => Icons.wb_sunny_rounded,
        ResourceKind.world => Icons.public_rounded,
      };

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}

String _fmtCategory(String c) {
  if (c == 'neoforge') return 'NeoForge';
  if (c.isEmpty) return c;
  return c[0].toUpperCase() + c.substring(1);
}

String _fmtCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}m';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return n.toString();
}

// =====================================================================
// 整合包（Modrinth 在线安装，.mrpack 一键安装）
// =====================================================================

class _ModpackView extends ConsumerStatefulWidget {
  const _ModpackView();

  @override
  ConsumerState<_ModpackView> createState() => _ModpackViewState();
}

class _ModpackViewState extends ConsumerState<_ModpackView> {
  final _searchCtrl = TextEditingController();
  List<ModrinthSearchHit> _hits = [];
  bool _searching = false;
  final Set<String> _installing = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onSubmitted: (_) => _search(),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '搜索 Modrinth 整合包（如 RLCraft / Fabulously Optimized）',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: Text(_searching ? '搜索中…' : '搜索'),
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
