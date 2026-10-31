import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/dirs/app_dirs.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../services/account/microsoft_auth.dart';
import '../../services/java/java_service.dart';
import '../../widgets/common.dart';

/// 设置页（分页签：启动 / 下载 / Java / 外观 / 关于）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 5, vsync: this);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Row(
              children: [
                Text('设置', style: context.titleStyle),
                const Spacer(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TabBar(
              controller: _tab,
              tabs: const [
                Tab(text: '启动'),
                Tab(text: '下载'),
                Tab(text: 'Java'),
                Tab(text: '外观'),
                Tab(text: '关于'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                _LaunchTab(),
                _DownloadTab(),
                _JavaTab(),
                _AppearanceTab(),
                _AboutTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 启动设置
class _LaunchTab extends ConsumerWidget {
  const _LaunchTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appSettingsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('游戏目录'),
              SettingsRow(
                icon: Icons.folder_rounded,
                title: '游戏根目录（.minecraft）',
                description: s.gameDirectory.isEmpty ? '未设置' : s.gameDirectory,
                trailing: OutlinedButton(
                  onPressed: () async {
                    final result = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: '选择游戏目录',
                    );
                    if (result != null) {
                      ref
                          .read(appSettingsProvider.notifier)
                          .patch((st) => st.copyWith(gameDirectory: result));
                    }
                  },
                  child: const Text('更改'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('内存'),
              Row(
                children: [
                  Text('最大内存', style: const TextStyle(fontSize: 14.5)),
                  Expanded(
                    child: Slider(
                      min: 512,
                      max: 16384,
                      divisions: 31,
                      value: s.maxMemoryMb.clamp(512, 16384).toDouble(),
                      label: '${s.maxMemoryMb} MB',
                      onChanged: (v) => ref
                          .read(appSettingsProvider.notifier)
                          .patch((st) => st.copyWith(maxMemoryMb: v.round())),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      '${s.maxMemoryMb} MB',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              // 系统内存提示
              FutureBuilder<int>(
                future: _totalMemory(),
                builder: (context, snap) {
                  if (snap.data == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '系统物理内存：${formatBytes(snap.data! * 1024 * 1024)}'
                      '（建议不超过其 60%）',
                      style: context.captionStyle,
                    ),
                  );
                },
              ),
              SettingsRow(
                icon: Icons.code_rounded,
                title: 'JVM 参数',
                description: '追加到默认参数之后，如 -XX:+UseG1GC',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(text: s.jvmArguments),
                  maxLines: 2,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(jvmArguments: v)),
                ),
              ),
              SettingsRow(
                icon: Icons.gamepad_rounded,
                title: '游戏参数',
                description: '附加启动参数，如 --demo',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(text: s.gameArguments),
                  maxLines: 1,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(gameArguments: v)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('版本管理（PCL2 式）'),
              SettingsRow(
                icon: Icons.dashboard_customize_rounded,
                title: '版本隔离',
                description:
                    '为每个版本使用独立游戏目录（saves / options.txt / mods 互不干扰），'
                    'libraries 与 assets 仍共享。可在「版本管理 → 版本设置」中单独覆盖。',
                trailing: Switch(
                  value: s.versionIsolation,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(versionIsolation: v)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('启动行为与窗口'),
              SettingsRow(
                icon: Icons.hide_source_rounded,
                title: '启动后启动器行为',
                trailing: DropdownButton<int>(
                  value: s.launcherBehavior,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('保持启动器可见')),
                    DropdownMenuItem(value: 1, child: Text('隐藏启动器')),
                    DropdownMenuItem(value: 2, child: Text('关闭启动器')),
                  ],
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(launcherBehavior: v ?? 0)),
                ),
              ),
              SettingsRow(
                icon: Icons.fullscreen_rounded,
                title: '全屏启动游戏',
                trailing: Switch(
                  value: s.fullscreen,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(fullscreen: v)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('进阶启动选项（借鉴 HMCL）'),
              SettingsRow(
                icon: Icons.speed_rounded,
                title: '游戏进程优先级',
                description: '高优先级可减少卡顿，低优先级保持桌面流畅',
                trailing: DropdownButton<int>(
                  value: s.processPriority,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('普通')),
                    DropdownMenuItem(value: 1, child: Text('高')),
                    DropdownMenuItem(value: 2, child: Text('低')),
                  ],
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(processPriority: v ?? 0)),
                ),
              ),
              SettingsRow(
                icon: Icons.dns_rounded,
                title: '启动后自动加入服务器',
                description:
                    '格式 host 或 host:port（1.20+ 用 quickPlay，旧版用 --server）',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(text: s.serverAddress),
                  maxLines: 1,
                  decoration: const InputDecoration(
                    hintText: '例如 play.example.com:25565',
                    isDense: true,
                  ),
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(serverAddress: v.trim())),
                ),
              ),
              SettingsRow(
                icon: Icons.terminal_rounded,
                title: '启动前执行命令',
                description: '游戏启动前运行；失败将中止启动。可用 \$VERSION_ID / \$GAME_DIR',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(text: s.preLaunchCommand),
                  maxLines: 1,
                  decoration: const InputDecoration(
                    hintText: '例如 echo 准备启动 \$VERSION_ID',
                    isDense: true,
                  ),
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(preLaunchCommand: v)),
                ),
              ),
              SettingsRow(
                icon: Icons.memory_rounded,
                title: '游戏环境变量',
                description: '每行一条 KEY=VALUE，传递给游戏进程',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(
                    text: s.launchEnvironment.join('\n'),
                  ),
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'JAVA_OPTS=...',
                    isDense: true,
                  ),
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch(
                        (st) => st.copyWith(
                          launchEnvironment: v
                              .split('\n')
                              .map((e) => e.trim())
                              .where((e) => e.isNotEmpty)
                              .toList(),
                        ),
                      ),
                ),
              ),
              SettingsRow(
                icon: Icons.wrap_text_rounded,
                title: '包装命令（wrapper）',
                description: '以指定命令包装 Java，如 gamemoderun / optirun',
                trailing: const SizedBox(width: 0),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: TextField(
                  controller: TextEditingController(text: s.wrapperCommand),
                  maxLines: 1,
                  decoration: const InputDecoration(
                    hintText: '例如 gamemoderun',
                    isDense: true,
                  ),
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(wrapperCommand: v.trim())),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<int> _totalMemory() async {
    if (rust.rustBridgeAvailable) {
      final info = await rust.systemInfo();
      return info.totalMemoryMb;
    }
    return 8192;
  }
}

/// 下载设置
class _DownloadTab extends ConsumerWidget {
  const _DownloadTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appSettingsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('下载源'),
              SettingsRow(
                icon: Icons.cloud_rounded,
                title: '资源下载源',
                description: 'BMCLAPI 为国内镜像（推荐），失败时自动回退官方源',
                trailing: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('BMCLAPI')),
                    ButtonSegment(value: 1, label: Text('官方')),
                  ],
                  selected: {s.downloadSourceIndex},
                  onSelectionChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(downloadSourceIndex: v.first)),
                ),
              ),
              SettingsRow(
                icon: Icons.sync_alt_rounded,
                title: '自动回退',
                description: '主源请求失败时切换到备用源',
                trailing: Switch(
                  value: s.autoFallback,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(autoFallback: v)),
                ),
              ),
              SettingsRow(
                icon: Icons.speed_rounded,
                title: '并发下载数',
                description: '同时进行的连接数量（建议 16~64）',
                trailing: Slider(
                  min: 4,
                  max: 128,
                  divisions: 31,
                  value: s.concurrency.clamp(4, 128).toDouble(),
                  label: '${s.concurrency}',
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(concurrency: v.round())),
                ),
              ),
              SettingsRow(
                icon: Icons.verified_rounded,
                title: '校验文件完整性',
                description: '关闭可提升速度，但可能导致损坏文件未被替换',
                trailing: Switch(
                  value: s.verifyFiles,
                  onChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(verifyFiles: v)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Java 设置
class _JavaTab extends ConsumerStatefulWidget {
  const _JavaTab();

  @override
  ConsumerState<_JavaTab> createState() => _JavaTabState();
}

class _JavaTabState extends ConsumerState<_JavaTab> {
  List<rust.JavaInfo> _javas = [];
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final service = ref.read(javaServiceProvider);
      final list = await service.detectAll(force: true);
      if (!mounted) return;
      setState(() {
        _javas = list;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _scanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appSettingsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: SectionHeader('已检测到的 Java')),
                  TextButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: _scanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search_rounded, size: 18),
                    label: const Text('重新扫描'),
                  ),
                ],
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (!_scanning && _javas.isEmpty && _error == null)
                Text('未检测到 Java，请手动指定路径', style: context.captionStyle),
              ..._javas.map(
                (j) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.local_cafe_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    'Java ${j.majorVersion}（${j.versionString}）'
                    '${j.is64Bit ? '' : ' · 32位'}',
                  ),
                  subtitle: Text(
                    j.javaPath,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: s.javaPath == j.javaPath
                      ? Chip(
                          label: const Text(
                            '使用中',
                            style: TextStyle(fontSize: 11),
                          ),
                          visualDensity: VisualDensity.compact,
                        )
                      : null,
                  onTap: () => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(javaPath: j.javaPath)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _JavaAutoInstallCard(),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('手动指定'),
              SettingsRow(
                icon: Icons.terminal_rounded,
                title: 'Java 可执行文件路径',
                description: s.javaPath.isEmpty ? '自动选择' : s.javaPath,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles(
                          dialogTitle: '选择 java 可执行文件',
                        );
                        if (result != null) {
                          ref
                              .read(appSettingsProvider.notifier)
                              .patch(
                                (st) => st.copyWith(
                                  javaPath: result.files.single.path ?? '',
                                ),
                              );
                        }
                      },
                      child: const Text('选择文件'),
                    ),
                    if (s.javaPath.isNotEmpty)
                      TextButton(
                        onPressed: () => ref
                            .read(appSettingsProvider.notifier)
                            .patch((st) => st.copyWith(javaPath: '')),
                        child: const Text('清除'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Java 自动安装卡片（借鉴 PCL2 2.13「缺失 Java 自动下载」）
class _JavaAutoInstallCard extends ConsumerStatefulWidget {
  const _JavaAutoInstallCard();

  @override
  ConsumerState<_JavaAutoInstallCard> createState() =>
      _JavaAutoInstallCardState();
}

class _JavaAutoInstallCardState extends ConsumerState<_JavaAutoInstallCard> {
  bool _installing = false;
  String _status = '';
  double? _progress;

  Future<void> _install(int major) async {
    setState(() {
      _installing = true;
      _status = '准备安装 Java $major...';
      _progress = null;
    });
    try {
      final info = await ref
          .read(javaServiceProvider)
          .installJava(
            major,
            onProgress: (phase, message, progress) {
              if (!mounted) return;
              setState(() {
                _status = message;
                _progress = progress;
              });
            },
          );
      if (!mounted) return;
      setState(() {
        _installing = false;
        _status = info != null
            ? 'Java ${info.versionString} 安装完成'
            : '安装失败（详见日志）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _status = '安装失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appSettingsProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('自动安装（Adoptium Temurin）'),
          SettingsRow(
            icon: Icons.cloud_download_rounded,
            title: '缺失 Java 时自动下载',
            description:
                '启动时若缺少所需版本的 Java，自动从 Adoptium 官方源下载 '
                'JRE 并托管到 <游戏目录>/runtime，多版本共享。',
            trailing: Switch(
              value: s.autoInstallJava,
              onChanged: (v) => ref
                  .read(appSettingsProvider.notifier)
                  .patch((st) => st.copyWith(autoInstallJava: v)),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('手动安装：', style: context.captionStyle),
              for (final major in const [8, 17, 21]) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _installing ? null : () => _install(major),
                  child: Text('Java $major'),
                ),
              ],
            ],
          ),
          if (_installing) ...[
            const SizedBox(height: 10),
            if (_progress != null)
              LinearProgressIndicator(value: _progress!.clamp(0.0, 1.0))
            else
              const LinearProgressIndicator(),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_status, style: context.captionStyle),
          ],
        ],
      ),
    );
  }
}

/// 外观设置
class _AppearanceTab extends ConsumerWidget {
  const _AppearanceTab();

  /// 把用户选择的背景图复制到应用支持目录，返回新的路径
  Future<String?> _pickAndCacheBackground() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: '选择背景图片',
    );
    final picked = result?.files.single;
    if (picked == null) return null;
    final src = picked.path;
    if (src == null) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final bgDir = Directory(p.join(support.path, 'backgrounds'));
      if (!bgDir.existsSync()) bgDir.createSync(recursive: true);
      final ext = picked.extension?.isNotEmpty == true
          ? picked.extension!
          : src.split('.').last;
      final target = p.join(bgDir.path, 'custom_bg.$ext');
      await File(src).copy(target);
      return target;
    } catch (_) {
      return src; // 复制失败时直接引用原路径
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appSettingsProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('主题'),
              SettingsRow(
                icon: Icons.brightness_6_rounded,
                title: '界面主题',
                trailing: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('跟随系统')),
                    ButtonSegment(value: 1, label: Text('浅色')),
                    ButtonSegment(value: 2, label: Text('深色')),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) => ref
                      .read(appSettingsProvider.notifier)
                      .patch((st) => st.copyWith(themeMode: v.first)),
                ),
              ),
              const SizedBox(height: 14),
              const SectionHeader('背景图片'),
              SettingsRow(
                icon: Icons.wallpaper_rounded,
                title: '自定义背景图',
                description: s.backgroundImagePath.isEmpty
                    ? '未设置（使用纯色背景）'
                    : s.backgroundImagePath,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final path = await _pickAndCacheBackground();
                        if (path != null && context.mounted) {
                          ref
                              .read(appSettingsProvider.notifier)
                              .patch(
                                (st) => st.copyWith(backgroundImagePath: path),
                              );
                        }
                      },
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('选择图片'),
                    ),
                    if (s.backgroundImagePath.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '移除背景',
                        onPressed: () => ref
                            .read(appSettingsProvider.notifier)
                            .patch(
                              (st) => st.copyWith(backgroundImagePath: ''),
                            ),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ],
                ),
              ),
              if (s.backgroundImagePath.isNotEmpty) ...[
                SettingsRow(
                  icon: Icons.opacity_rounded,
                  title: '背景不透明度',
                  description: '${s.backgroundOpacity}%',
                  trailing: SizedBox(
                    width: 220,
                    child: Slider(
                      value: s.backgroundOpacity.toDouble(),
                      min: 5,
                      max: 100,
                      divisions: 19,
                      label: '${s.backgroundOpacity}%',
                      onChanged: (v) => ref
                          .read(appSettingsProvider.notifier)
                          .patch(
                            (st) => st.copyWith(backgroundOpacity: v.round()),
                          ),
                    ),
                  ),
                ),
                SettingsRow(
                  icon: Icons.blur_on_rounded,
                  title: '背景模糊',
                  description: s.backgroundBlur == 0
                      ? '关闭'
                      : '${s.backgroundBlur}',
                  trailing: SizedBox(
                    width: 220,
                    child: Slider(
                      value: s.backgroundBlur.toDouble(),
                      min: 0,
                      max: 50,
                      divisions: 10,
                      label: s.backgroundBlur == 0
                          ? '关闭'
                          : '${s.backgroundBlur}',
                      onChanged: (v) => ref
                          .read(appSettingsProvider.notifier)
                          .patch(
                            (st) => st.copyWith(backgroundBlur: v.round()),
                          ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 关于
class _AboutTab extends ConsumerWidget {
  const _AboutTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(AppConstants.appFullName),
              Text(
                '版本 ${AppConstants.appVersion} · '
                'Flutter 3.47.5 · Rust 1.96.0',
                style: context.captionStyle,
              ),
              const SizedBox(height: 10),
              Text(
                '一款现代化、高效、生产级可用的 Minecraft 启动器。'
                'Rust 下载引擎 + Flutter 界面，支持四款模组加载器与微软/外置登录。',
                style: const TextStyle(fontSize: 13.5, height: 1.6),
              ),
              const SizedBox(height: 6),
              Text(
                '本软件基于 GNU GPL-3.0-only 协议开源，'
                '修改与分发须遵循同等协议并保留版权声明。',
                style: context.captionStyle,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Process.start(
                        Platform.isWindows ? 'cmd' : 'open',
                        Platform.isWindows
                            ? ['/c', 'start', AppConstants.repoUrl]
                            : [AppConstants.repoUrl],
                        mode: ProcessStartMode.detached,
                      );
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('GitHub 仓库'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => context.push(AppRoutes.logs),
                    icon: const Icon(Icons.article_rounded, size: 16),
                    label: const Text('日志查看器'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _openLogs(context, ref),
                    icon: const Icon(Icons.folder_rounded, size: 16),
                    label: const Text('打开日志目录'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('微软登录配置（Azure）'),
              Text(
                '使用微软登录需要自备 Azure 应用 Client ID：\n'
                '1. 前往 Azure Portal → 应用注册 → 新建注册\n'
                '2. 受支持账户类型选择「个人 Microsoft 账户」\n'
                '3. 身份验证 → 高级设置 → 启用「允许公共客户端流」\n'
                '4. 将 Client ID 粘贴到下方',
                style: const TextStyle(fontSize: 13, height: 1.7),
              ),
              const SizedBox(height: 10),
              TextField(
                onChanged: (v) =>
                    MicrosoftAuthService.configureClientId(v.trim()),
                decoration: const InputDecoration(
                  hintText: 'Azure Client ID（仅保存在本会话）',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('致谢'),
              Text(
                '· PCL2 / Plain Craft Launcher — 设计灵感\n'
                '· PCL.Core（PCL-Community，Apache 2.0）— 下载器 / Java 管理 / 配置系统设计参考\n'
                '· BMCLAPI (bangbang93) — 国内下载镜像\n'
                '· Modrinth / FabricMC / QuiltMC / NeoForged / MinecraftForge\n'
                '· Adoptium (Eclipse Temurin) — Java 自动安装\n'
                '· authlib-injector (yushijinhun) — 外置登录支持',
                style: const TextStyle(fontSize: 13, height: 1.8),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openLogs(BuildContext context, WidgetRef ref) {
    // 打开启动器完整日志目录：exe 所在目录\FMCL\logs
    final logs = AppDirs.logsDir;
    Directory(logs).createSync(recursive: true);
    if (Platform.isWindows) {
      Process.run('explorer', [logs]);
    } else if (Platform.isMacOS) {
      Process.run('open', [logs]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [logs]);
    }
  }
}
