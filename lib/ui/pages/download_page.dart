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
// 新游戏
// ---------------------------------------------------------------------------

class _NewGameTab extends ConsumerStatefulWidget {
  const _NewGameTab();

  @override
  ConsumerState<_NewGameTab> createState() => _NewGameTabState();
}

class _NewGameTabState extends ConsumerState<_NewGameTab> {
  static const _loaders = ['vanilla', 'forge', 'neoforge', 'fabric', 'quilt', 'optifine'];
  static const _loaderNames = ['原版', 'Forge', 'NeoForge', 'Fabric', 'Quilt', 'OptiFine'];

  int _loaderIndex = 0;
  String? _selectedMc;
  String? _selectedLoaderVer;
  final _nameController = TextEditingController();
  String _mcFilter = '';

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteVersionsProvider);
    final settings = ref.watch(settingsProvider);
    final bmclFirst = settings.downloadSourceIndex == 0;
    final loaderKey = _loaders[_loaderIndex] == 'vanilla'
        ? null
        : (_loaders[_loaderIndex], _selectedMc ?? '');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左：原版版本列表
        PclPanel(
          padding: const EdgeInsets.all(10),
          margin: EdgeInsets.zero,
          child: SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                      final filtered = _mcFilter.isEmpty
                          ? list
                          : list
                              .where((e) => e.id
                                  .toLowerCase()
                                  .contains(_mcFilter.toLowerCase()))
                              .toList();
                      return ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final e = filtered[i];
                          final selected = _selectedMc == e.id;
                          return HoverTile(
                            onTap: () => setState(() {
                              _selectedMc = e.id;
                              _selectedLoaderVer = null;
                            }),
                            child: Row(
                              children: [
                                Container(
                                  width: 4,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    color: selected ? kAccent : Colors.transparent,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(e.id,
                                          style: TextStyle(
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: selected ? kAccent : null,
                                          )),
                                      Text(
                                        _typeLabel(e.versionType),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context)
                                                        .brightness ==
                                                    Brightness.dark
                                                ? Colors.white30
                                                : Colors.black26),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => EmptyView(
                        icon: Icons.cloud_off_rounded,
                        text: '获取版本清单失败：$e'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 右：加载器 + 安装
        Expanded(
          child: PclPanel(
            padding: const EdgeInsets.all(16),
            child: _selectedMc == null
                ? const EmptyView(
                    icon: Icons.touch_app_rounded, text: '先在左侧选择游戏版本')
                : _buildRight(context, loaderKey, bmclFirst),
          ),
        ),
      ],
    );
  }

  Widget _buildRight(BuildContext context, (String, String)? loaderKey, bool bmclFirst) {
    final loaderVersions = loaderKey == null
        ? null
        : ref.watch(loaderVersionsProvider(loaderKey));
    final canInstall = _selectedMc != null &&
        (_loaders[_loaderIndex] == 'vanilla' ||
            _loaders[_loaderIndex] == 'optifine' ||
            _selectedLoaderVer != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            VersionIcon(loader: _loaders[_loaderIndex], size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_selectedMc ${_loaderNames[_loaderIndex]}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    '安装到 ${ref.watch(gameDirProvider)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white38
                            : Colors.black38),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 加载器类型
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < _loaders.length; i++)
              ChoiceChip(
                label: Text(_loaderNames[i]),
                selected: _loaderIndex == i,
                selectedColor: kAccent.withAlpha(40),
                labelStyle: TextStyle(
                  color: _loaderIndex == i ? kAccent : null,
                  fontWeight:
                      _loaderIndex == i ? FontWeight.w700 : FontWeight.w500,
                ),
                side: BorderSide(
                  color: _loaderIndex == i
                      ? kAccent
                      : (Theme.of(context).brightness == Brightness.dark
                          ? Colors.white24
                          : Colors.black12),
                ),
                onSelected: (_) => setState(() {
                  _loaderIndex = i;
                  _selectedLoaderVer = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // 加载器版本
        if (loaderKey != null)
          loaderVersions!.when(
            data: (list) {
              if (list.isEmpty) {
                return const Text('该版本暂无可用加载器版本',
                    style: TextStyle(color: Colors.orange));
              }
              return DropdownButtonFormField<String>(
                value: _selectedLoaderVer,
                decoration: InputDecoration(
                  labelText: '${_loaderNames[_loaderIndex]} 版本',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                items: [
                  for (final v in list)
                    DropdownMenuItem(
                      value: v.version,
                      child: Row(
                        children: [
                          Text(v.version),
                          if (v.isRecommended) ...[
                            const SizedBox(width: 6),
                            PclTag('推荐', color: Colors.green),
                          ],
                          if (v.isPreview) PclTag('测试', color: Colors.orange),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedLoaderVer = v),
              );
            },
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(
              '获取加载器版本失败：$e',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        const SizedBox(height: 14),
        // 实例名
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: '版本名称（可留空自动命名）',
            hintText: '${_selectedMc ?? ''}${_loaders[_loaderIndex] == 'vanilla' ? '' : '-${_loaderNames[_loaderIndex]}'}',
          ),
        ),
        const Spacer(),
        Row(
          children: [
            PclTag(
              bmclFirst ? '下载源：BMCLAPI 优先' : '下载源：官方优先',
              color: bmclFirst ? kAccent : Colors.teal,
            ),
            const Spacer(),
            PclButton(
              text: '开始安装',
              icon: Icons.download_rounded,
              onTap: canInstall ? () => _install(context) : null,
            ),
          ],
        ),
      ],
    );
  }

  void _install(BuildContext context) {
    final settings = ref.read(settingsProvider);
    final gameDir = ref.read(gameDirProvider);
    final loader = _loaders[_loaderIndex];
    final name = _nameController.text.trim().isEmpty
        ? '${_selectedMc}${loader == 'vanilla' ? '' : '-${_loaderNames[_loaderIndex]}'}'
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
    task.install(request, '安装 $_selectedMc ${_loaderNames[_loaderIndex]}');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const InstallTaskDialog(),
    ).then((_) {
      ref.read(localVersionsProvider.notifier).refresh();
    });
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
                    text: '尚未安装任何版本，去「新游戏」安装或导入外部版本')
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final v = list[i];
                      final isSelected = v.id == selected;
                      return PclPanel(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
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
                                              fontWeight: FontWeight.w700),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PclTag(loaderLabel(v.loader)),
                                      if (v.loaderVersion.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        PclTag(v.loaderVersion,
                                            color: Colors.deepPurple),
                                      ],
                                      if (!v.hasJar) ...[
                                        const SizedBox(width: 6),
                                        PclTag('缺 jar',
                                            color: Colors.orange),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '游戏版本 ${v.gameVersion} · ${formatBytes(v.sizeBytes)}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.white38
                                            : Colors.black38),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(Icons.check_circle_rounded,
                                    color: kAccent, size: 20),
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
                                          backgroundColor: kDanger),
                                    );
                                  }
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            _iconAction(context, Icons.tune_rounded, '版本设置',
                                () => showDialog(
                                      context: context,
                                      builder: (_) => VersionSettingsDialog(
                                          versionId: v.id),
                                    )),
                            _iconAction(context, Icons.build_circle_outlined,
                                '补全文件', () => _complete(context, ref, v.id)),
                            _iconAction(context, Icons.folder_open_rounded,
                                '打开文件夹', () async {
                              try {
                                await rust.openPath(path: v.dir);
                              } catch (_) {}
                            }),
                            _iconAction(context, Icons.drive_file_rename_outline,
                                '重命名', () => _rename(context, ref, v.id)),
                            _iconAction(context, Icons.copy_rounded, '复制',
                                () => _copy(context, ref, v.id)),
                            _iconAction(
                                context, Icons.delete_outline_rounded, '删除',
                                () => _delete(context, ref, v.id)),
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
      BuildContext context, IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
        ),
      ),
    );
  }

  void _complete(BuildContext context, WidgetRef ref, String versionId) {
    final settings = ref.read(settingsProvider);
    ref.read(installTaskProvider.notifier).complete(
          gameDir: ref.read(gameDirProvider),
          versionId: versionId,
          bmclapiFirst: settings.downloadSourceIndex == 0,
          concurrency: settings.concurrency,
        );
    showDialog(
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
    final name = await _inputDialog(context, '导入版本名称（可留空自动）', '');
    if (name == null) return;
    try {
      await ref.read(versionOpsProvider).importExternal(dir, name);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入版本 ${name.isEmpty ? "（自动命名）" : name}')));
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
      BuildContext context, WidgetRef ref, String versionId) async {
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
      BuildContext context, WidgetRef ref, String versionId) async {
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
      BuildContext context, WidgetRef ref, String versionId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除版本'),
        content: Text('确定删除版本「$versionId」吗？\n该版本目录将被完整删除（含隔离目录内的存档）。\n此操作不可恢复！'),
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
    BuildContext context, String title, String initial) async {
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
                    child: const Icon(Icons.inventory_2_outlined,
                        color: kAccent),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('安装整合包',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800)),
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
                    color: isDark ? Colors.white38 : Colors.black38),
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
    final settings = ref.read(settingsProvider);
    ref.read(installTaskProvider.notifier).installModpack(
          zipPath: path,
          gameDir: ref.read(gameDirProvider),
          instanceName: '',
          javaPath: settings.javaPath,
          useBmclapi: settings.downloadSourceIndex == 0,
          concurrency: settings.concurrency,
        );
    showDialog(
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
      final results = await rust.searchContent(
        query: _queryController.text.trim(),
        category: widget.category,
        mcVersion: v?.gameVersion ?? '',
        loader: v?.loader ?? '',
        index: 0,
      );
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
                            : Colors.black38),
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
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
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
                        child: const Icon(Icons.extension_rounded,
                            size: 20, color: kAccent),
                      )
                    : Image.network(
                        hit.iconUrl,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 40,
                          height: 40,
                          color: kAccent.withAlpha(22),
                          child: const Icon(Icons.extension_rounded,
                              size: 20, color: kAccent),
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
                          fontSize: 13.5, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${hit.author} · ${_fmtDownloads(hit.downloads)} 下载',
                      style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white35 : Colors.black35),
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
                  color: isDark ? Colors.white45 : Colors.black45,
                  height: 1.3),
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
      showDialog(
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
              Text('选择文件 · ${hit.title}',
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                selected.isEmpty
                    ? '尚未选择目标版本，将无法安装'
                    : '安装到版本：$selected',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white38
                        : Colors.black38),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final f = files[i];
                    return HoverTile(
                      onTap: () => _install(context, ref, f),
                      child: Row(
                        children: [
                          Icon(
                            f.versionType == 'release'
                                ? Icons.check_circle_outline_rounded
                                : Icons.beta_rounded,
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
                                      fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${_fmtDownloads2(f.gameVersions)} · ${formatBytes(f.sizeBytes)}',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white35
                                          : Colors.black35),
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
      BuildContext context, WidgetRef ref, rust.ContentFile f) async {
    final selected = ref.read(selectedVersionProvider);
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择目标版本')));
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
          SnackBar(content: Text('已安装：${savePath.split(Platform.pathSeparator).last}')),
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
