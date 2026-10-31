/// 下载页（对齐 PCL2 下载页结构）：
/// 新游戏（原版+加载器合并安装）/ 已安装 / 整合包 / 模组 / 资源包 / 光影 / 数据包。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../dialogs/install_task_dialog.dart';
import '../dialogs/version_settings_dialog.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';
import 'download_detail_page.dart';

class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends ConsumerState<DownloadPage> {
  int _tab = 0;

  static const _tabs = ['新游戏', '已安装', '整合包', '模组', '资源包', '光影', '数据包'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Segmented(
                items: _tabs,
                index: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildTab()),
        ],
      ),
    );
  }

  Widget _buildTab() {
    switch (_tab) {
      case 0:
        return const _NewGameTab();
      case 1:
        return const _InstalledTab();
      case 2:
        return const _ModpackTab();
      default:
        return _ContentTab(category: _categoryFor(_tab));
    }
  }

  static String _categoryFor(int tab) {
    switch (tab) {
      case 3:
        return 'mod';
      case 4:
        return 'resourcepack';
      case 5:
        return 'shaderpack';
      default:
        return 'datapack';
    }
  }
}

// ---------------------------------------------------------------------------
// 新游戏（布局 100% 借鉴参照项目 DownloadPage：左版本列表 + 右加载器卡片 +
// 底部「开始下载」按钮 → 全屏下载详情页）
// ---------------------------------------------------------------------------

class _NewGameTab extends ConsumerStatefulWidget {
  const _NewGameTab();

  @override
  ConsumerState<_NewGameTab> createState() => _NewGameTabState();
}

class _NewGameTabState extends ConsumerState<_NewGameTab> {
  /// 加载器（原版隐式：null = 不装加载器）
  static const _loaders = [
    'forge',
    'neoforge',
    'fabric',
    'quilt',
    'optifine',
  ];
  static const _loaderNames = [
    'Forge',
    'NeoForge',
    'Fabric',
    'Quilt',
    'OptiFine',
  ];

  String? _selectedMc;
  /// 选中的加载器（展开即选中，null = 原版）
  String? _selectedLoader;
  /// 展开的加载器卡片（与 _selectedLoader 联动）
  String? _expandedLoader;
  String? _selectedLoaderVer;
  final _nameController = TextEditingController();
  String _mcFilter = '';
  /// 版本过滤：release | snapshot | all（对齐参照项目 chips）
  String _versionFilter = 'release';

  String get _loaderNameOf => _selectedLoader == null
      ? '原版'
      : _loaderNames[_loaders.indexOf(_selectedLoader!)];

  String get _defaultName =>
      '${_selectedMc ?? ''}${_selectedLoader == null ? '' : '-$_loaderNameOf'}';

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteVersionsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subText = isDark ? Colors.white38 : Colors.black38;

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ==================== 左：版本列表（参照项目 flex 3） ====================
              Expanded(
                flex: 3,
                child: PclPanel(
                  padding: const EdgeInsets.all(10),
                  margin: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text('原版游戏', style: TextStyle(fontSize: 12.5, color: subText, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
                          const Spacer(),
                          Text('Minecraft', style: TextStyle(fontSize: 11.5, color: subText)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: '搜索版本...',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (v) => setState(() => _mcFilter = v.trim()),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: remote.when(
                          data: (list) {
                            final filtered = list.where((e) {
                              if (_mcFilter.isNotEmpty &&
                                  !e.id.toLowerCase().contains(
                                    _mcFilter.toLowerCase(),
                                  )) {
                                return false;
                              }
                              return switch (_versionFilter) {
                                'release' => e.versionType == 'release',
                                'snapshot' =>
                                  e.versionType == 'snapshot' ||
                                      e.versionType == 'old_beta' ||
                                      e.versionType == 'old_alpha',
                                _ => true,
                              };
                            }).toList();
                            return ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, i) {
                                final e = filtered[i];
                                final selected = _selectedMc == e.id;
                                return HoverTile(
                                  onTap: () => setState(() {
                                    _selectedMc = e.id;
                                    _selectedLoaderVer = null;
                                    _expandedLoader = null;
                                    _nameController.text =
                                        '${e.id}${_selectedLoader == null ? '' : '-$_loaderNameOf'}';
                                  }),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 2),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? kAccent.withAlpha(26)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: selected
                                            ? kAccent.withAlpha(66)
                                            : Colors.transparent,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                e.id,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: selected
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                  color: selected
                                                      ? kAccent
                                                      : null,
                                                ),
                                              ),
                                              Text(
                                                _typeLabel(e.versionType),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: subText,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (selected)
                                          const Icon(
                                            Icons.check_rounded,
                                            color: kAccent,
                                            size: 16,
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                          loading: () => const Center(
                            child: CircularProgressIndicator(),
                          ),
                          error: (e, _) => EmptyView(
                            icon: Icons.cloud_off_rounded,
                            text: '获取版本清单失败：$e',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // ==================== 右：加载器卡片（参照项目 flex 4） ====================
              Expanded(
                flex: 4,
                child: _selectedMc == null
                    ? PclPanel(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.arrow_back_rounded, size: 34, color: subText),
                              const SizedBox(height: 10),
                              Text('请先在左侧选择一个原版版本', style: TextStyle(color: subText)),
                            ],
                          ),
                        ),
                      )
                    : _buildRight(context, isDark, subText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRight(BuildContext context, bool isDark, Color subText) {
    return PclPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---------- 头部：版本标题 + 过滤 chips（参照项目头部） ----------
          Row(
            children: [
              VersionIcon(loader: _selectedLoader ?? 'vanilla', size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$_selectedMc ${_selectedLoader == null ? '原版' : '· $_loaderNameOf'}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _chip('正式版', 'release', isDark),
              const SizedBox(width: 6),
              _chip('快照版', 'snapshot', isDark),
              const SizedBox(width: 6),
              _chip('全部', 'all', isDark),
            ],
          ),
          Divider(height: 20, color: isDark ? Colors.white.withAlpha(16) : Colors.black.withAlpha(16)),
          // ---------- 版本名称 ----------
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: '版本名称',
              hintText: _defaultName,
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          Text('选择加载器（不选 = 纯原版）', style: TextStyle(fontSize: 13, color: subText)),
          const SizedBox(height: 8),
          // ---------- 加载器卡片（参照项目 _buildLoaderCard） ----------
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _loaders.length; i++)
                    _LoaderCard(
                      title: _loaderNames[i],
                      loader: _loaders[i],
                      mcVersion: _selectedMc!,
                      selectedVersion: _selectedLoader == _loaders[i]
                          ? _selectedLoaderVer
                          : null,
                      expanded: _expandedLoader == _loaders[i],
                      onToggle: () => _toggleLoader(_loaders[i]),
                      onClear: () => setState(() {
                        if (_selectedLoader == _loaders[i]) {
                          _selectedLoader = null;
                          _selectedLoaderVer = null;
                        }
                        _expandedLoader = null;
                      }),
                      onSelectVersion: (v) => setState(() {
                        _selectedLoader = _loaders[i];
                        _selectedLoaderVer = v;
                        _nameController.text = _defaultName;
                      }),
                    ),
                ],
              ),
            ),
          ),
          // ---------- 底部开始下载（参照项目底部按钮行） ----------
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text(
                '开始下载',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String filter, bool isDark) {
    final sel = _versionFilter == filter;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: (v) {
        if (v) setState(() => _versionFilter = filter);
      },
      visualDensity: VisualDensity.compact,
      selectedColor: kAccent.withAlpha(56),
      labelStyle: TextStyle(
        color: sel ? kAccent : (isDark ? Colors.white54 : Colors.black45),
        fontSize: 11.5,
      ),
      side: BorderSide(
        color: sel
            ? kAccent
            : (isDark ? Colors.white24 : Colors.black12),
      ),
      showCheckmark: false,
    );
  }

  void _toggleLoader(String loader) {
    setState(() {
      if (_expandedLoader == loader) {
        // 再次点击收起；若已选择该加载器则保持选中
        _expandedLoader = null;
        return;
      }
      _expandedLoader = loader;
      if (_selectedLoader != loader) {
        _selectedLoader = loader;
        _selectedLoaderVer = null;
      }
      _nameController.text = _defaultName;
    });
  }

  void _startDownload() {
    if (_selectedMc == null) return;
    final settings = ref.read(settingsProvider);
    final gameDir = ref.read(gameDirProvider);
    final loader = _selectedLoader;
    final name = _nameController.text.trim().isEmpty
        ? _defaultName
        : _nameController.text.trim();
    final task = ref.read(installTaskProvider.notifier);

    final request = rust.InstallRequest(
      gameDir: gameDir,
      instanceName: name,
      gameVersion: _selectedMc!,
      javaPath: settings.javaPath,
      useBmclapi: settings.downloadSourceIndex == 0,
      concurrency: settings.concurrency,
      sessionId: 'install-${DateTime.now().millisecondsSinceEpoch}',
      forgeVersion: loader == 'forge' ? _selectedLoaderVer : null,
      neoforgeVersion: loader == 'neoforge' ? _selectedLoaderVer : null,
      fabricVersion: loader == 'fabric' ? _selectedLoaderVer : null,
      quiltVersion: loader == 'quilt' ? _selectedLoaderVer : null,
      optifine: loader == 'optifine'
          ? rust.OptiFineEntry(
              inherit: _selectedMc!,
              displayName: _selectedLoaderVer ?? 'HD_U',
              fileName:
                  'OptiFine_${_selectedMc}_${_selectedLoaderVer ?? 'HD_U'}.jar',
              isPreview: false,
            )
          : null,
    );
    task.install(request, '安装 $name');
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => DownloadDetailPage(
              onRetry: () => task.install(request, '安装 $name'),
            ),
          ),
        )
        .then((_) {
          ref.read(localVersionsProvider.notifier).refresh();
          ref.read(installTaskProvider.notifier).reset();
        });
  }
}

/// 加载器卡片（100% 借鉴参照项目 _buildLoaderCard）：
/// 头部 ListTile（图标 + 标题 / 已选「Forge 47.2.0」+ 清除×），
/// 展开后为该加载器的版本列表（高度受限，内滚）。
class _LoaderCard extends ConsumerWidget {
  final String title;
  final String loader;
  final String mcVersion;
  final String? selectedVersion;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onClear;
  final ValueChanged<String> onSelectVersion;

  const _LoaderCard({
    required this.title,
    required this.loader,
    required this.mcVersion,
    required this.selectedVersion,
    required this.expanded,
    required this.onToggle,
    required this.onClear,
    required this.onSelectVersion,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasSel = selectedVersion != null;
    final dt = (!expanded && hasSel) ? '$title $selectedVersion' : title;
    final active = expanded || hasSel;
    final border = isDark ? Colors.white.withAlpha(16) : Colors.black.withAlpha(16);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: (!expanded && hasSel)
            ? kAccent.withAlpha(16)
            : (isDark ? Colors.white.withAlpha(8) : Colors.black.withAlpha(6)),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? kAccent.withAlpha(66) : border),
      ),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              leading: VersionIcon(loader: loader, size: 26),
              title: Text(
                dt,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? kAccent : null,
                ),
              ),
              trailing: (!expanded && hasSel)
                  ? InkWell(
                      onTap: onClear,
                      borderRadius: BorderRadius.circular(20),
                      child: const Icon(Icons.close_rounded, size: 18),
                    )
                  : Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: isDark ? Colors.white54 : Colors.black38,
                    ),
              onTap: onToggle,
            ),
          ),
          if (expanded) _buildVersionList(context, ref, isDark),
        ],
      ),
    );
  }

  Widget _buildVersionList(BuildContext context, WidgetRef ref, bool isDark) {
    final subText = isDark ? Colors.white38 : Colors.black38;
    // OptiFine 与原版同源（加载器清单按 mc 版本返回）
    final loaderVersions = ref.watch(
      loaderVersionsProvider((loader, mcVersion)),
    );
    return loaderVersions.when(
      data: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('暂无可用的 $title 版本', style: TextStyle(fontSize: 12.5, color: subText)),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final fv = list[i];
              final sel = selectedVersion == fv.version;
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  fv.version,
                  style: TextStyle(
                    fontSize: 13,
                    color: sel ? kAccent : null,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                subtitle: fv.isPreview
                    ? Text('测试版', style: TextStyle(fontSize: 11, color: subText))
                    : null,
                trailing: sel
                    ? const Icon(Icons.check_rounded, color: kAccent, size: 16)
                    : (fv.isRecommended
                          ? PclTag('推荐', color: Colors.green)
                          : null),
                onTap: () => onSelectVersion(fv.version),
              );
            },
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(22),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('获取 $title 版本失败：$e', style: const TextStyle(fontSize: 12.5, color: kDanger)),
      ),
    );
  }
}

String _typeLabel(String t) {
  switch (t) {
    case 'release':
      return '正式版';
    case 'snapshot':
      return '快照';
    case 'old_beta':
      return 'Beta';
    case 'old_alpha':
      return 'Alpha';
    default:
      return t;
  }
}

// ---------------------------------------------------------------------------
// 已安装
// ---------------------------------------------------------------------------

class _InstalledTab extends ConsumerWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);

    return Column(
      children: [
        Row(
          children: [
            PclButton(
              text: '导入外部版本',
              primary: false,
              icon: Icons.create_new_folder_outlined,
              onTap: () => _importExternal(context, ref),
            ),
            const SizedBox(width: 10),
            PclButton(
              text: '打开游戏目录',
              primary: false,
              icon: Icons.folder_open_rounded,
              onTap: () async {
                try {
                  await rust.openPath(path: ref.read(gameDirProvider));
                } catch (_) {}
              },
            ),
            const Spacer(),
            PclButton(
              text: '刷新',
              primary: false,
              icon: Icons.refresh_rounded,
              onTap: () => ref.read(localVersionsProvider.notifier).refresh(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: versions.when(
            data: (list) => list.isEmpty
                ? const EmptyView(
                    icon: Icons.videogame_asset_off_outlined,
                    text: '尚未安装任何版本，去「新游戏」安装或导入外部版本',
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final v = list[i];
                      final isSelected = v.id == selected;
                      return PclPanel(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            VersionIcon(loader: v.loader, size: 42),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          v.id,
                                          style: const TextStyle(
                                            fontSize: 14.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PclTag(loaderLabel(v.loader)),
                                      if (v.loaderVersion.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        PclTag(
                                          v.loaderVersion,
                                          color: Colors.deepPurple,
                                        ),
                                      ],
                                      if (!v.hasJar) ...[
                                        const SizedBox(width: 6),
                                        PclTag('缺 jar', color: Colors.orange),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '游戏版本 ${v.gameVersion} · ${formatBytes(v.sizeBytes)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white38
                                          : Colors.black38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  color: kAccent,
                                  size: 20,
                                ),
                              ),
                            PclButton(
                              text: '启动',
                              height: 32,
                              fontSize: 13,
                              onTap: () async {
                                await ref
                                    .read(selectedVersionProvider.notifier)
                                    .select(v.id);
                                try {
                                  await ref
                                      .read(launchSessionsProvider.notifier)
                                      .launch(v.id);
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('$e'),
                                        backgroundColor: kDanger,
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            _iconAction(
                              context,
                              Icons.tune_rounded,
                              '版本设置',
                              () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    VersionSettingsDialog(versionId: v.id),
                              ),
                            ),
                            _iconAction(
                              context,
                              Icons.build_circle_outlined,
                              '补全文件',
                              () => _complete(context, ref, v.id),
                            ),
                            _iconAction(
                              context,
                              Icons.folder_open_rounded,
                              '打开文件夹',
                              () async {
                                try {
                                  await rust.openPath(path: v.dir);
                                } catch (_) {}
                              },
                            ),
                            _iconAction(
                              context,
                              Icons.drive_file_rename_outline,
                              '重命名',
                              () => _rename(context, ref, v.id),
                            ),
                            _iconAction(
                              context,
                              Icons.copy_rounded,
                              '复制',
                              () => _copy(context, ref, v.id),
                            ),
                            _iconAction(
                              context,
                              Icons.delete_outline_rounded,
                              '删除',
                              () => _delete(context, ref, v.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyView(text: '扫描版本失败: $e'),
          ),
        ),
      ],
    );
  }

  Widget _iconAction(
    BuildContext context,
    IconData icon,
    String tip,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 19,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  void _complete(BuildContext context, WidgetRef ref, String versionId) {
    final settings = ref.read(settingsProvider);
    ref
        .read(installTaskProvider.notifier)
        .complete(
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

  Future<void> _importExternal(BuildContext context, WidgetRef ref) async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择版本目录（需包含 版本名.json）',
    );
    if (dir == null) return;
    if (!context.mounted) return;
    final name = await _inputDialog(context, '导入版本名称（可留空自动）', '');
    if (name == null) return;
    try {
      await ref.read(versionOpsProvider).importExternal(dir, name);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入版本 ${name.isEmpty ? "（自动命名）" : name}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String versionId,
  ) async {
    final name = await _inputDialog(context, '重命名版本', versionId);
    if (name == null || name.isEmpty || name == versionId) return;
    try {
      await ref.read(versionOpsProvider).rename(versionId, name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }

  Future<void> _copy(
    BuildContext context,
    WidgetRef ref,
    String versionId,
  ) async {
    final name = await _inputDialog(context, '复制版本为新名称', '$versionId-副本');
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(versionOpsProvider).copy(versionId, name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('复制失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    String versionId,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除版本'),
        content: Text(
          '确定删除版本「$versionId」吗？\n该版本目录将被完整删除（含隔离目录内的存档）。\n此操作不可恢复！',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(versionOpsProvider).delete(versionId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }
}

/// 简单文本输入弹窗
Future<String?> _inputDialog(
  BuildContext context,
  String title,
  String initial,
) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// 整合包
// ---------------------------------------------------------------------------

class _ModpackTab extends ConsumerWidget {
  const _ModpackTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: PclPanel(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: kAccent.withAlpha(22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.inventory_2_outlined,
                      color: kAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '安装整合包',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '支持 Modrinth (.mrpack) 与 CurseForge (zip) 整合包，自动安装游戏与加载器',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              PclButton(
                text: '选择整合包文件...',
                icon: Icons.file_open_rounded,
                onTap: () => _pickAndInstall(context, ref),
              ),
              const SizedBox(height: 14),
              Text(
                '· 安装过程：解析清单 → 下载覆盖文件与模组 → 安装游戏本体与加载器\n'
                '· 整合包将安装为独立版本，出现在「已安装」列表中\n'
                '· CurseForge 整合包文件名解析依赖社区镜像，个别文件可能需要手动补齐',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndInstall(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择整合包',
      type: FileType.custom,
      allowedExtensions: ['zip', 'mrpack'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    final settings = ref.read(settingsProvider);
    ref
        .read(installTaskProvider.notifier)
        .installModpack(
          zipPath: path,
          gameDir: ref.read(gameDirProvider),
          instanceName: '',
          javaPath: settings.javaPath,
          useBmclapi: settings.downloadSourceIndex == 0,
          concurrency: settings.concurrency,
        );
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const InstallTaskDialog(),
    );
  }
}

// ---------------------------------------------------------------------------
// Modrinth 内容（模组 / 资源包 / 光影 / 数据包）
// ---------------------------------------------------------------------------

class _ContentTab extends ConsumerStatefulWidget {
  final String category;

  const _ContentTab({required this.category});

  @override
  ConsumerState<_ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends ConsumerState<_ContentTab> {
  final _queryController = TextEditingController();
  List<rust.SearchHit>? _results;
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final selected = ref.read(selectedVersionProvider);
      final versions = ref.read(localVersionsProvider).value ?? const [];
      final v = versions.where((x) => x.id == selected).firstOrNull;
      final results = await rust
          .searchContent(
            query: _queryController.text.trim(),
            category: widget.category,
            mcVersion: v?.gameVersion ?? '',
            loader: v?.loader ?? '',
            index: 0,
          )
          // UI 侧兜底超时：Rust 侧自身有限时与重试（约 1 分钟内出结果），
          // 此处保证转圈永不无限持续
          .timeout(const Duration(seconds: 120));
      setState(() => _results = results);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedVersionProvider);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _queryController,
                decoration: InputDecoration(
                  hintText: _hintFor(widget.category),
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 10),
            PclButton(text: '搜索', icon: Icons.search_rounded, onTap: _search),
          ],
        ),
        const SizedBox(height: 6),
        if (selected.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                PclTag('提示', color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '尚未选择版本：安装前请先在主页或「已安装」选择目标版本（用于过滤兼容性）',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white38
                          : Colors.black38,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? EmptyView(icon: Icons.cloud_off_rounded, text: '搜索失败: $_error')
              : (_results == null || _results!.isEmpty)
              ? EmptyView(text: '没有搜索结果')
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 340,
                    mainAxisExtent: 108,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: _results!.length,
                  itemBuilder: (context, i) {
                    final hit = _results![i];
                    return _ContentCard(hit: hit);
                  },
                ),
        ),
      ],
    );
  }
}

String _hintFor(String category) {
  switch (category) {
    case 'mod':
      return '搜索模组（如 sodium、jei）...';
    case 'resourcepack':
      return '搜索资源包...';
    case 'shaderpack':
      return '搜索光影（如 BSL、Complementary）...';
    default:
      return '搜索数据包...';
  }
}

class _ContentCard extends ConsumerWidget {
  final rust.SearchHit hit;

  const _ContentCard({required this.hit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PclPanel(
      padding: const EdgeInsets.all(12),
      onTap: () => _showFiles(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: hit.iconUrl.isEmpty
                    ? Container(
                        width: 40,
                        height: 40,
                        color: kAccent.withAlpha(22),
                        child: const Icon(
                          Icons.extension_rounded,
                          size: 20,
                          color: kAccent,
                        ),
                      )
                    : Image.network(
                        hit.iconUrl,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 40,
                          height: 40,
                          color: kAccent.withAlpha(22),
                          child: const Icon(
                            Icons.extension_rounded,
                            size: 20,
                            color: kAccent,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${hit.author} · ${_fmtDownloads(hit.downloads)} 下载',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              hit.description,
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? Colors.white54 : Colors.black45,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFiles(BuildContext context, WidgetRef ref) async {
    try {
      final files = await rust.listProjectFiles(projectId: hit.projectId);
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => _FilePickerDialog(hit: hit, files: files),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取版本列表失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }
}

String _fmtDownloads(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

class _FilePickerDialog extends ConsumerWidget {
  final rust.SearchHit hit;
  final List<rust.ContentFile> files;

  const _FilePickerDialog({required this.hit, required this.files});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedVersionProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择文件 · ${hit.title}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                selected.isEmpty ? '尚未选择目标版本，将无法安装' : '安装到版本：$selected',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white38
                      : Colors.black38,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final f = files[i];
                    return HoverTile(
                      onTap: () => _install(context, ref, f),
                      child: Row(
                        children: [
                          Icon(
                            f.versionType == 'release'
                                ? Icons.check_circle_outline_rounded
                                : Icons.auto_awesome_rounded,
                            size: 18,
                            color: f.versionType == 'release'
                                ? Colors.green
                                : Colors.orange,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${f.name} (${f.versionNumber})',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${_fmtDownloads2(f.gameVersions)} · ${formatBytes(f.sizeBytes)}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.white38
                                        : Colors.black38,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.download_rounded, size: 18),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _install(
    BuildContext context,
    WidgetRef ref,
    rust.ContentFile f,
  ) async {
    final selected = ref.read(selectedVersionProvider);
    if (selected.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择目标版本')));
      return;
    }
    try {
      final savePath = await rust.installContentFile(
        gameDir: ref.read(gameDirProvider),
        versionId: selected,
        category: hit.category,
        downloadUrl: f.downloadUrl,
        filename: f.filename,
        sessionId: 'content-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已安装：${savePath.split(Platform.pathSeparator).last}'),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('安装失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }
}

String _fmtDownloads2(List<String> gameVersions) {
  if (gameVersions.isEmpty) return '无版本信息';
  return gameVersions.take(3).join(', ') +
      (gameVersions.length > 3 ? ' 等' : '');
}
