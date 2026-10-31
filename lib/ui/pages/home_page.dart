/// 主页（对齐 PCL2 布局）：
/// 左侧：大启动按钮（含当前版本）+ 当前账户卡 + 快捷入口 2x2 + 运行中会话
/// 右侧：PCL2 风格公告面板（蓝色标题栏 + 公告内容）
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../dialogs/install_task_dialog.dart';
import '../dialogs/version_settings_dialog.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

/// PCL2 启动按钮的标志性绿色
const Color _launchGreen = Color(0xFF3DA039);
const Color _launchGreenHover = Color(0xFF358D32);
const Color _launchGreenDeep = Color(0xFF2E7C2B);

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);
    final sessions = ref.watch(launchSessionsProvider);
    final active = sessions.where((s) => s.isActive).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ==================== 左侧主区 ====================
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ---------- 启动区（大按钮 + 账户卡） ----------
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _LaunchButton(selected: selected)),
                    const SizedBox(width: 10),
                    const SizedBox(width: 216, child: _AccountCard()),
                  ],
                ),
                const SizedBox(height: 10),
                // ---------- 快捷入口 2x2（PCL2 主页样式） ----------
                Expanded(
                  child: _QuickGrid(selected: selected, versions: versions),
                ),
                // ---------- 运行中的游戏（有会话时显示） ----------
                if (active.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _RunningSessions(sessions: active),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // ==================== 右侧公告 ====================
          const SizedBox(width: 320, child: _AnnouncementPanel()),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 大启动按钮（PCL2 绿色渐变，含当前版本名）
// ---------------------------------------------------------------------------
class _LaunchButton extends ConsumerStatefulWidget {
  final String selected;

  const _LaunchButton({required this.selected});

  @override
  ConsumerState<_LaunchButton> createState() => _LaunchButtonState();
}

class _LaunchButtonState extends ConsumerState<_LaunchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(launchSessionsProvider);
    final active = sessions.where((s) => s.isActive).length;
    final hasVersion = widget.selected.isNotEmpty;

    // 无版本时可点击 → 引导去选择/安装版本；有活跃会话时不响应
    void onTap() {
      if (hasVersion && active > 0) return;
      if (!hasVersion) {
        showDialog<void>(
          context: context,
          builder: (_) => const _VersionSelectorDialog(),
        );
        return;
      }
      ref.read(launchSessionsProvider.notifier).launch(widget.selected);
    }

    final grad = !hasVersion || active > 0
        ? [
            Colors.grey.shade400,
            Colors.grey.shade500,
          ]
        : _hover
        ? const [_launchGreenHover, _launchGreenDeep]
        : const [_launchGreen, _launchGreenDeep];

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 112,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: grad,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: hasVersion && active == 0
                ? [
                    BoxShadow(
                      color: _launchGreen.withAlpha(_hover ? 96 : 60),
                      blurRadius: _hover ? 18 : 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(_hover ? 52 : 34),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 46,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      active > 0 ? '游戏运行中（$active）' : hasVersion ? '启动游戏' : '没有已安装的版本',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasVersion
                          ? widget.selected
                          : '点击选择版本或前往下载页安装',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withAlpha(_hover ? 235 : 200),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white70,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 当前账户卡（PCL2：启动按钮右侧，点击切换账户）
// ---------------------------------------------------------------------------
class _AccountCard extends ConsumerWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final cur = accounts.current;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final String name;
    final String sub;
    final Color typeColor;
    final IconData icon;
    if (cur == null) {
      name = '未登录';
      sub = '点击添加账户';
      typeColor = kAccent;
      icon = Icons.person_add_alt_1_rounded;
    } else {
      name = cur.name;
      sub = switch (cur.accountType) {
        'microsoft' => '微软正版',
        'yggdrasil' => '外置登录',
        _ => '离线模式',
      };
      typeColor = switch (cur.accountType) {
        'microsoft' => Colors.green,
        'yggdrasil' => Colors.deepPurple,
        _ => kAccent,
      };
      icon = switch (cur.accountType) {
        'microsoft' => Icons.verified_user_rounded,
        'yggdrasil' => Icons.dns_rounded,
        _ => Icons.person_rounded,
      };
    }

    return PclPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: () => ref.read(pageIndexProvider.notifier).set(2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: typeColor.withAlpha(30),
                child: Icon(icon, size: 18, color: typeColor),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: typeColor.withAlpha(16),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              cur == null ? '去登录' : '切换账户',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: typeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 快捷入口 2x2（PCL2 主页：游戏文件夹 / 补全文件 / 版本设置 / 下载游戏）
// ---------------------------------------------------------------------------
class _QuickGrid extends ConsumerWidget {
  final String selected;
  final AsyncValue<List<rust.LocalVersionInfo>> versions;

  const _QuickGrid({required this.selected, required this.versions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = [
      (
        Icons.folder_open_rounded,
        '游戏文件夹',
        '打开 .minecraft 目录',
        () => _openGameDir(ref),
      ),
      (
        Icons.build_circle_outlined,
        '补全文件',
        '校验并补全当前版本',
        () => _completeVersion(context, ref, selected),
      ),
      (
        Icons.tune_rounded,
        '版本设置',
        '隔离 / 内存 / Java / JVM',
        () => _openVersionSettings(context, selected),
      ),
      (
        Icons.download_for_offline_outlined,
        '下载游戏',
        '新版本 / 模组 / 整合包',
        () => ref.read(pageIndexProvider.notifier).set(1),
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.9,
      padding: EdgeInsets.zero,
      children: [
        for (final (icon, title, sub, onTap) in tiles)
          _QuickCard(icon: icon, title: title, subtitle: sub, onTap: onTap),
      ],
    );
  }

  void _openGameDir(WidgetRef ref) async {
    final dir = ref.read(gameDirProvider);
    try {
      await Directory(dir).create(recursive: true);
      await rust.openPath(path: dir);
    } catch (_) {}
  }

  void _completeVersion(BuildContext context, WidgetRef ref, String versionId) {
    if (versionId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择版本')));
      return;
    }
    final settings = ref.read(settingsProvider);
    final task = ref.read(installTaskProvider.notifier);
    task.complete(
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

  void _openVersionSettings(BuildContext context, String versionId) {
    if (versionId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择版本')));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => VersionSettingsDialog(versionId: versionId),
    );
  }
}

// ---------------------------------------------------------------------------
// 快捷入口卡（PCL2 横向卡片）
// ---------------------------------------------------------------------------
class _QuickCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QuickCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PclPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: kAccent.withAlpha(22),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 21, color: kAccent),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 运行中的游戏会话
// ---------------------------------------------------------------------------
class _RunningSessions extends ConsumerWidget {
  final List<LaunchSession> sessions;

  const _RunningSessions({required this.sessions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PclPanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in sessions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _launchGreen,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    s.versionId,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.message,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white38
                            : Colors.black38,
                      ),
                    ),
                  ),
                  PclButton(
                    text: '终止',
                    danger: true,
                    height: 26,
                    fontSize: 12,
                    onTap: () => ref
                        .read(launchSessionsProvider.notifier)
                        .terminate(s.id),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 公告面板（PCL2 风格：蓝色标题栏 + 内容区）
// ---------------------------------------------------------------------------
class _AnnouncementPanel extends StatelessWidget {
  const _AnnouncementPanel();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PclPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 蓝色标题栏（PCL2 公告卡）
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [kAccent, Color(0xFF2B62CE)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.campaign_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text(
                  '公告',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '欢迎使用 FMCL',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  _announcementText(
                    'FMCL（Fluent Minecraft Launcher）是一款遵循 PCL2 '
                    '交互习惯的 Minecraft Java 版启动器：下载、安装、'
                    '补全、启动与多账户登录全部由 Rust 核心完成，'
                    '界面流畅且行为可预期。',
                    isDark,
                  ),
                  _AnnouncementDivider(isDark: isDark),
                  _announcementTitle('快速上手', 14),
                  const SizedBox(height: 6),
                  _announcementStep('1', '在「下载」页选择版本并一键安装'
                      '（原版与 Forge / NeoForge / Fabric / Quilt / OptiFine '
                      '加载器合并安装）', isDark),
                  _announcementStep('2', '在「账户」页添加离线 / 微软 / 外置账户'
                      '；外置登录（LittleSkin 等）会自动下载 authlib-injector',
                      isDark),
                  _announcementStep('3', '回到本页，点击绿色大按钮启动游戏', isDark),
                  _AnnouncementDivider(isDark: isDark),
                  _announcementTitle('提示', 14),
                  const SizedBox(height: 6),
                  _announcementText(
                    '· 下载源可在「设置」页切换（BMCLAPI 优先 / 官方优先）\n'
                    '· 完整日志输出至启动器目录 FMCL\\logs\\，遇到问题'
                    '可在「日志」页一键打开并发给我们\n'
                    '· 游戏与资源统一存放在启动器所在目录的 .minecraft',
                    isDark,
                  ),
                  _AnnouncementDivider(isDark: isDark),
                  _announcementTitle('反馈与更新', 14),
                  const SizedBox(height: 6),
                  SelectableText(
                    'github.com/Ming-QWQ520/FMCL',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: kAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _announcementTitle(String text, double size) {
    return Text(
      text,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
    );
  }

  Widget _announcementText(String text, bool isDark) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        height: 1.65,
        color: isDark ? Colors.white54 : Colors.black54,
      ),
    );
  }

  Widget _announcementStep(String n, String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 17,
            height: 17,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: kAccent.withAlpha(28),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              n,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: kAccent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnnouncementDivider extends StatelessWidget {
  final bool isDark;

  const _AnnouncementDivider({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Divider(
        height: 1,
        color: isDark ? Colors.white.withAlpha(18) : Colors.black.withAlpha(18),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 版本快速选择弹窗（保持 PCL2 列表样式）
// ---------------------------------------------------------------------------
class _VersionSelectorDialog extends ConsumerWidget {
  const _VersionSelectorDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '选择版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  PclButton(
                    text: '安装新版本',
                    primary: false,
                    height: 30,
                    fontSize: 12.5,
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(pageIndexProvider.notifier).set(1);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: versions.when(
                  data: (list) => list.isEmpty
                      ? const EmptyView(text: '尚未安装任何版本')
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final v = list[i];
                            final isSelected = v.id == selected;
                            return Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? kAccent
                                      : Colors.transparent,
                                ),
                              ),
                              child: HoverTile(
                                onTap: () {
                                  ref
                                      .read(selectedVersionProvider.notifier)
                                      .select(v.id);
                                  Navigator.of(context).pop();
                                },
                                child: Row(
                                  children: [
                                    VersionIcon(loader: v.loader),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        v.id,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    PclTag(loaderLabel(v.loader)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyView(text: '加载失败: $e'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
