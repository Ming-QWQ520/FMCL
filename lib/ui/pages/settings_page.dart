/// 设置页（对齐 PCL2 分组式设置）：通用 / 启动 / 内存与 Java / 网络 / 外观。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  int _group = 0;

  static const _groups = ['通用', '启动', '内存与 Java', '网络', '外观'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧分组
          SizedBox(
            width: 170,
            child: PclPanel(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _groups.length; i++)
                    HoverTile(
                      onTap: () => setState(() => _group = i),
                      child: Row(
                        children: [
                          Container(
                            width: 3,
                            height: 16,
                            decoration: BoxDecoration(
                              color: _group == i ? kAccent : Colors.transparent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _groups[i],
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: _group == i
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: _group == i ? kAccent : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 右侧内容
          Expanded(
            child: PclPanel(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: ListView(
                children: [
                  switch (_group) {
                    0 => _generalSettings(context, ref),
                    1 => _launchSettings(context, ref),
                    2 => _memoryJavaSettings(context, ref),
                    3 => _networkSettings(context, ref),
                    _ => _appearanceSettings(context, ref),
                  },
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _generalSettings(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('游戏目录'),
        SettingRow(
          title: '游戏根目录（.minecraft）',
          subtitle:
              '当前：${ref.watch(gameDirProvider)}\n默认为 exe 所在目录\\.minecraft（便携模式）',
          trailing: PclButton(
            text: '选择目录',
            primary: false,
            height: 32,
            onTap: () async {
              final dir = await FilePicker.platform.getDirectoryPath(
                  dialogTitle: '选择游戏根目录');
              if (dir == null) return;
              await _update(ref, s.copyWithLocal(gameDirectory: dir));
              await ref.read(localVersionsProvider.notifier).refresh();
            },
          ),
          child: PclButton(
            text: '打开',
            primary: false,
            height: 32,
            onTap: () async {
              try {
                final dir = Directory(ref.read(gameDirProvider));
                if (!dir.existsSync()) dir.createSync(recursive: true);
                await rust.openPath(path: ref.read(gameDirProvider));
              } catch (_) {}
            },
          ),
        ),
        const Divider(),
        const SectionTitle('版本管理'),
        SettingRow(
          title: '版本隔离',
          subtitle: '每个版本使用独立的 saves/config/mods 目录（PCL2 默认行为）',
          trailing: PclSwitch(
            value: s.versionIsolation,
            onChanged: (v) =>
                _update(ref, s.copyWithLocal(versionIsolation: v)),
          ),
        ),
        SettingRow(
          title: '缺失 Java 时自动安装',
          subtitle: '自动从 Adoptium 下载匹配的 JRE（存放于 FMCL\\java）',
          trailing: PclSwitch(
            value: s.autoInstallJava,
            onChanged: (v) => _update(ref, s.copyWithLocal(autoInstallJava: v)),
          ),
        ),
        const Divider(),
        const SectionTitle('启动器日志'),
        SettingRow(
          title: '日志目录',
          subtitle: '完整日志输出至 exe 所在目录\\FMCL\\logs\\（latest.log + 按天归档）',
          child: PclButton(
            text: '打开目录',
            primary: false,
            height: 32,
            onTap: () async {
              final info = await rust.initApp();
              await rust.openPath(path: info.logsDir);
            },
          ),
        ),
      ],
    );
  }

  Widget _launchSettings(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('启动行为'),
        SettingRow(
          title: '启动游戏后',
          subtitle: '启动器保持 / 隐藏 / 关闭',
          child: Segmented(
            items: const ['保持', '隐藏', '关闭'],
            index: s.launcherBehavior.clamp(0, 2),
            onChanged: (i) => _update(ref, s.copyWithLocal(launcherBehavior: i)),
          ),
        ),
        SettingRow(
          title: '进程优先级',
          subtitle: '高优先级可减少卡顿，低优先级避免影响其它程序',
          child: Segmented(
            items: const ['普通', '高', '低'],
            index: s.processPriority.clamp(0, 2),
            onChanged: (i) => _update(ref, s.copyWithLocal(processPriority: i)),
          ),
        ),
        const Divider(),
        const SectionTitle('服务器与参数'),
        SettingRow(
          title: '启动后自动加入服务器',
          subtitle: '格式 host 或 host:port（1.20+ 使用 quickPlay）',
          child: SizedBox(
            width: 220,
            child: TextField(
              controller: TextEditingController(text: s.serverAddress),
              decoration: const InputDecoration(hintText: '例: mc.example.com'),
              onChanged: (v) => _updateDebounced(ref, s, (n) => n.copyWithLocal(serverAddress: v.trim())),
            ),
          ),
        ),
        SettingRow(
          title: '启动前执行命令',
          subtitle: '支持 \$VERSION_ID / \$GAME_DIR 占位符；非 0 退出码中止启动',
          child: SizedBox(
            width: 260,
            child: TextField(
              controller: TextEditingController(text: s.preLaunchCommand),
              onChanged: (v) => _updateDebounced(ref, s, (n) => n.copyWithLocal(preLaunchCommand: v)),
            ),
          ),
        ),
        SettingRow(
          title: '包装命令',
          subtitle: '如 gamemoderun / optirun，游戏 java 命令将被其包裹',
          child: SizedBox(
            width: 220,
            child: TextField(
              controller: TextEditingController(text: s.wrapperCommand),
              onChanged: (v) => _updateDebounced(ref, s, (n) => n.copyWithLocal(wrapperCommand: v)),
            ),
          ),
        ),
        SettingRow(
          title: '游戏窗口',
          subtitle: '全屏或自定义分辨率（0 = 默认）',
          child: Row(
            children: [
              PclSwitch(
                value: s.fullscreen,
                onChanged: (v) => _update(ref, s.copyWithLocal(fullscreen: v)),
              ),
              const Text('全屏', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              SizedBox(
                width: 70,
                child: TextField(
                  keyboardType: TextInputType.number,
                  enabled: !s.fullscreen,
                  controller:
                      TextEditingController(text: s.windowWidth > 0 ? '${s.windowWidth}' : ''),
                  decoration: const InputDecoration(hintText: '宽'),
                  onChanged: (v) => _updateDebounced(ref, s,
                      (n) => n.copyWithLocal(windowWidth: int.tryParse(v) ?? 0)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 70,
                child: TextField(
                  keyboardType: TextInputType.number,
                  enabled: !s.fullscreen,
                  controller:
                      TextEditingController(text: s.windowHeight > 0 ? '${s.windowHeight}' : ''),
                  decoration: const InputDecoration(hintText: '高'),
                  onChanged: (v) => _updateDebounced(ref, s,
                      (n) => n.copyWithLocal(windowHeight: int.tryParse(v) ?? 0)),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        const SectionTitle('环境变量'),
        _EnvEditor(
          lines: s.launchEnvironment,
          onChanged: (lines) => _update(ref, s.copyWithLocal(launchEnvironment: lines)),
        ),
      ],
    );
  }

  Widget _memoryJavaSettings(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final javas = ref.watch(javasProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('内存'),
        SettingRow(
          title: '内存分配',
          subtitle: '建议 2048-8192 MiB；启动时会校验不超过物理内存的 90%',
          child: Row(
            children: [
              SizedBox(
                width: 90,
                child: TextField(
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(text: '${s.minMemoryMb}'),
                  decoration: const InputDecoration(labelText: '最小'),
                  onChanged: (v) => _updateDebounced(
                      ref, s, (n) => n.copyWithLocal(minMemoryMb: int.tryParse(v) ?? 512)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('—'),
              ),
              SizedBox(
                width: 90,
                child: TextField(
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(text: '${s.maxMemoryMb}'),
                  decoration: const InputDecoration(labelText: '最大'),
                  onChanged: (v) => _updateDebounced(
                      ref, s, (n) => n.copyWithLocal(maxMemoryMb: int.tryParse(v) ?? 2048)),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        const SectionTitle('Java 运行时'),
        javas.when(
          data: (list) => Column(
            children: [
              for (final j in list)
                HoverTile(
                  child: Row(
                    children: [
                      Icon(
                        Icons.local_fire_department_rounded,
                        size: 18,
                        color: j.majorVersion >= 17 ? Colors.orange : Colors.brown,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Java ${j.majorVersion} · ${j.versionString}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${j.vendor} · ${j.javaPath}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      Theme.of(context).brightness == Brightness.dark
                                          ? Colors.white35
                                          : Colors.black35),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      PclTag(j.isJre ? 'JRE' : 'JDK'),
                    ],
                  ),
                ),
            ],
          ),
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => EmptyView(text: '未检测到 Java（$e）'),
        ),
        SettingRow(
          title: '手动指定 Java',
          subtitle: '留空自动选择；版本设置中可覆盖',
          child: SizedBox(
            width: 300,
            child: TextField(
              controller: TextEditingController(text: s.javaPath),
              decoration: const InputDecoration(
                  hintText: 'javaw.exe 完整路径'),
              onChanged: (v) =>
                  _updateDebounced(ref, s, (n) => n.copyWithLocal(javaPath: v.trim())),
            ),
          ),
        ),
        SettingRow(
          title: '额外 Java 搜索目录',
          subtitle: '自动扫描这些目录（递归 4 层）',
          child: PclButton(
            text: '添加目录',
            primary: false,
            height: 32,
            onTap: () async {
              final dir = await FilePicker.platform.getDirectoryPath(
                  dialogTitle: '选择 Java 搜索目录');
              if (dir == null) return;
              final next = [...s.javaSearchPaths, dir];
              _update(ref, s.copyWithLocal(javaSearchPaths: next));
            },
          ),
        ),
        for (final p in s.javaSearchPaths)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right_rounded, size: 15),
                Expanded(child: Text(p, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 16),
                  onPressed: () => _update(
                      ref,
                      s.copyWithLocal(
                          javaSearchPaths: s.javaSearchPaths.where((x) => x != p).toList())),
                ),
              ],
            ),
          ),
        const Divider(),
        const SectionTitle('JVM / 游戏参数'),
        SettingRow(
          title: '额外 JVM 参数',
          subtitle: '叠加在版本 JSON 模板之后',
          child: SizedBox(
            width: 320,
            child: TextField(
              maxLines: 2,
              controller: TextEditingController(text: s.jvmArguments),
              onChanged: (v) =>
                  _updateDebounced(ref, s, (n) => n.copyWithLocal(jvmArguments: v)),
            ),
          ),
        ),
        SettingRow(
          title: '额外游戏参数',
          subtitle: '主类之后追加',
          child: SizedBox(
            width: 320,
            child: TextField(
              maxLines: 2,
              controller: TextEditingController(text: s.gameArguments),
              onChanged: (v) =>
                  _updateDebounced(ref, s, (n) => n.copyWithLocal(gameArguments: v)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _networkSettings(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('下载源'),
        SettingRow(
          title: '下载源策略',
          subtitle: 'BMCLAPI 镜像优先（国内友好，自动回退官方）或官方优先',
          child: Segmented(
            items: const ['BMCLAPI 优先', '官方优先'],
            index: s.downloadSourceIndex.clamp(0, 1),
            onChanged: (i) =>
                _update(ref, s.copyWithLocal(downloadSourceIndex: i)),
          ),
        ),
        SettingRow(
          title: '自动回退备用源',
          subtitle: '首选源失败时自动尝试另一源',
          trailing: PclSwitch(
            value: s.autoFallback,
            onChanged: (v) => _update(ref, s.copyWithLocal(autoFallback: v)),
          ),
        ),
        SettingRow(
          title: '下载并发数',
          subtitle: '建议 16-64，过高可能触发限流',
          child: SizedBox(
            width: 90,
            child: TextField(
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: '${s.concurrency}'),
              onChanged: (v) => _updateDebounced(
                  ref, s, (n) => n.copyWithLocal(concurrency: int.tryParse(v) ?? 32)),
            ),
          ),
        ),
        SettingRow(
          title: '校验文件完整性',
          subtitle: 'SHA1/大小双重校验（关闭可提速，但有损坏风险）',
          trailing: PclSwitch(
            value: s.verifyFiles,
            onChanged: (v) => _update(ref, s.copyWithLocal(verifyFiles: v)),
          ),
        ),
      ],
    );
  }

  Widget _appearanceSettings(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('主题'),
        SettingRow(
          title: '主题模式',
          subtitle: '浅色 / 深色 / 跟随系统',
          child: Segmented(
            items: const ['跟随系统', '浅色', '深色'],
            index: s.themeMode.clamp(0, 2),
            onChanged: (i) => _update(ref, s.copyWithLocal(themeMode: i)),
          ),
        ),
        const Divider(),
        const SectionTitle('背景图'),
        SettingRow(
          title: '自定义背景图片',
          subtitle: s.backgroundImagePath.isEmpty
              ? '未设置（可使用本地图片，PCL2 式背景）'
              : s.backgroundImagePath,
          child: PclButton(
            text: '选择图片',
            primary: false,
            height: 32,
            onTap: () async {
              final result = await FilePicker.platform.pickFiles(
                dialogTitle: '选择背景图',
                type: FileType.image,
              );
              final path = result?.files.single.path;
              if (path != null) {
                _update(ref, s.copyWithLocal(backgroundImagePath: path));
              }
            },
          ),
        ),
        if (s.backgroundImagePath.isNotEmpty)
          SettingRow(
            title: '清除背景图',
            subtitle: '恢复默认纯色背景',
            child: PclButton(
              text: '清除',
              danger: true,
              height: 32,
              onTap: () =>
                  _update(ref, s.copyWithLocal(backgroundImagePath: '')),
            ),
          ),
        SettingRow(
          title: '背景不透明度',
          subtitle: '${s.backgroundOpacity}%',
          child: SizedBox(
            width: 220,
            child: Slider(
              value: s.backgroundOpacity.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              activeColor: kAccent,
              onChanged: (v) => _updateDebounced(
                  ref, s, (n) => n.copyWithLocal(backgroundOpacity: v.toInt())),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------

  Future<void> _update(WidgetRef ref, SettingsData next) async {
    await ref.read(settingsProvider.notifier).update(next);
  }

  void _updateDebounced(
      WidgetRef ref, SettingsData current, SettingsData Function(SettingsData) f) {
    // 简单策略：每次变更立即保存（Rust 侧写盘为原子操作，代价可接受）
    _update(ref, f(current));
  }
}

/// 环境变量编辑器（每行 KEY=VALUE）
class _EnvEditor extends StatefulWidget {
  final List<String> lines;
  final ValueChanged<List<String>> onChanged;

  const _EnvEditor({required this.lines, required this.onChanged});

  @override
  State<_EnvEditor> createState() => _EnvEditorState();
}

class _EnvEditorState extends State<_EnvEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      maxLines: 4,
      decoration: const InputDecoration(
        labelText: '游戏进程环境变量（每行 KEY=VALUE）',
        hintText: 'JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8',
      ),
      onChanged: (v) => widget
          .onChanged(v.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList()),
    );
  }
}
