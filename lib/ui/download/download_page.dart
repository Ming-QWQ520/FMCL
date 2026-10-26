import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../services/download/http_service.dart';
import '../../services/install/fabric_quilt_installer.dart';
import '../../services/install/forge_installer.dart';
import '../../services/install/rust_install_service.dart';
import '../../services/version/version_repository.dart';
import '../../data/models/version_manifest.dart';
import '../../data/sources/download_source.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';

/// 下载页：原版版本 + 加载器安装入口。
class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

enum _Tab { release, snapshot, oldBeta, loaders }

class _DownloadPageState extends ConsumerState<DownloadPage> {
  VersionManifest? _manifest;
  bool _loading = true;
  String _search = '';
  _Tab _tab = _Tab.release;
  String? _error;

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
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('下载游戏', style: context.titleStyle),
                    const Spacer(),
                    // 下载源指示
                    Builder(builder: (context) {
                      final src = ref.watch(appSettingsProvider).downloadSourceIndex == 1
                          ? '官方源'
                          : 'BMCLAPI';
                      return Tooltip(
                        message: '可在 设置 → 下载 中切换',
                        child: Chip(
                          avatar: Icon(Icons.cloud_outlined,
                              size: 16, color: Theme.of(context).colorScheme.primary),
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
                const SizedBox(height: 12),
                SegmentedButton<_Tab>(
                  segments: const [
                    ButtonSegment(value: _Tab.release, label: Text('正式版')),
                    ButtonSegment(value: _Tab.snapshot, label: Text('快照')),
                    ButtonSegment(value: _Tab.oldBeta, label: Text('远古版')),
                    ButtonSegment(value: _Tab.loaders, label: Text('加载器')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
                const SizedBox(height: 12),
                if (_tab != _Tab.loaders)
                  TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: const InputDecoration(
                      hintText: '搜索版本（如 1.20.1）',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                const SizedBox(height: 12),
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
                    : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_tab == _Tab.loaders) return const _LoaderInstallPanel();

    final versions = (_manifest?.versions ?? []).where((v) {
      final typeOk = switch (_tab) {
        _Tab.release => v.isRelease,
        _Tab.snapshot => v.isSnapshot,
        _Tab.oldBeta => v.isOld,
        _Tab.loaders => true,
      };
      return typeOk && v.id.contains(_search);
    }).toList();

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 420,
        mainAxisExtent: 84,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: versions.length,
      itemBuilder: (context, i) => _VersionCard(
        entry: versions[i],
        onInstall: () => _showInstallDialog(versions[i]),
      ),
    );
  }

  void _showInstallDialog(VersionEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _InstallSheet(
        entry: entry,
        onConfirm: (versionId) async {
          Navigator.pop(context);
          try {
            _snack('开始安装 ${entry.id}（Rust 引擎）...');
            final service = ref.read(rustInstallServiceProvider).create(
                  RustInstallParams(
                    gameVersion: entry.id,
                    instanceName: versionId,
                    requiredJavaMajor: javaMajorFor(entry.id),
                  ),
                );
            await service.install(
              onProgress: (p) {
                // 进度事件可在启动页/通知中展示；此处仅日志
              },
            );
            _snack('$versionId 安装完成');
          } catch (e) {
            _snack('安装失败: $e', error: true);
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

/// 加载器安装面板
class _LoaderInstallPanel extends ConsumerStatefulWidget {
  const _LoaderInstallPanel();

  @override
  ConsumerState<_LoaderInstallPanel> createState() =>
      _LoaderInstallPanelState();
}

class _LoaderInstallPanelState extends ConsumerState<_LoaderInstallPanel> {
  String _gameVersion = '1.20.1';
  String _loader = 'fabric';
  List<String> _loaderVersions = [];
  String? _selectedLoaderVersion;
  bool _loadingVersions = false;
  bool _installing = false;

  static const _loaders = [
    ('fabric', 'Fabric', Icons.auto_fix_high_rounded),
    ('forge', 'Forge', Icons.local_fire_department_rounded),
    ('neoforge', 'NeoForge', Icons.emoji_objects_rounded),
    ('quilt', 'Quilt', Icons.layers_rounded),
    ('optifine', 'OptiFine 高清修复', Icons.high_quality_rounded),
  ];

  /// OptiFine 版本条目（BMCLAPI versionList）
  List<_OptiFineEntry> _optifineEntries = [];

  Future<void> _loadLoaderVersions() async {
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
              .fetchRecommendedVersions(_gameVersion);
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
    setState(() => _installing = true);
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
              .install(onProgress: (_) {});
        case 'fabric':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'fabric-loader-$loaderVersion-$_gameVersion',
            fabricVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: (_) {});
        case 'quilt':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'quilt-loader-$loaderVersion-$_gameVersion',
            quiltVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: (_) {});
        case 'forge':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'forge-$_gameVersion-$loaderVersion',
            forgeVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: (_) {});
        case 'neoforge':
          resultId = await factory
              .create(RustInstallParams(
            gameVersion: _gameVersion,
            instanceName: 'neoforge-$_gameVersion-$loaderVersion',
            neoforgeVersion: loaderVersion,
            requiredJavaMajor: javaMajorFor(_gameVersion),
          ))
              .install(onProgress: (_) {});
        default:
          resultId = _gameVersion;
      }
      _snack('$_loader $loaderVersion 安装完成 → $resultId');
    } catch (e) {
      _snack('安装失败: $e', error: true);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('安装模组加载器'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _loaders.map((l) {
                  final selected = _loader == l.$1;
                  return ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(l.$3,
                            size: 17,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : null),
                        const SizedBox(width: 6),
                        Text(l.$2),
                      ],
                    ),
                    selected: selected,
                    onSelected: (_) {
                      setState(() {
                        _loader = l.$1;
                        _loaderVersions = [];
                        _selectedLoaderVersion = null;
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      decoration:
                          const InputDecoration(hintText: 'Minecraft 版本'),
                      controller:
                          TextEditingController(text: _gameVersion),
                      onChanged: (v) => _gameVersion = v.trim(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _loadingVersions ? null : _loadLoaderVersions,
                    child: Text(_loadingVersions ? '获取中...' : '获取版本列表'),
                  ),
                ],
              ),
              if (_loaderVersions.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButton<String>(
                  value: _selectedLoaderVersion,
                  isExpanded: true,
                  hint: const Text('选择加载器版本'),
                  items: _loaderVersions
                      .map((v) => DropdownMenuItem(
                            value: v,
                            child: Text(v, style: const TextStyle(fontSize: 14)),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedLoaderVersion = v),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _installing || _selectedLoaderVersion == null
                      ? null
                      : _install,
                  icon: _installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(_installing
                      ? '安装中，请勿关闭窗口...'
                      : '安装 $_loader $_selectedLoaderVersion'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '提示：Forge/NeoForge 安装过程需要执行官方处理器链，首次安装耗时约 1~3 分钟；'
          '若处理器执行失败，请在 设置 → Java 中确认已配置有效的 Java 17+ 环境。',
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
