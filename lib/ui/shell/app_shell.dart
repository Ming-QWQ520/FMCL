import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/game_account.dart';
import '../../providers/account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common.dart';
import '../versions/modpack_import_dialog.dart';
import 'custom_title_bar.dart';

/// 主框架：自绘标题栏 + 左侧导航栏 + 内容区
/// （支持自定义背景图与整合包文件拖拽导入）。
class AppShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell shell;

  const AppShell({super.key, required this.shell});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _dragging = false;

  /// 处理拖入的整合包文件
  void _handleDropped(DropDoneDetails details) {
    setState(() => _dragging = false);
    for (final file in details.files) {
      final lower = file.path.toLowerCase();
      if (lower.endsWith('.mrpack') || lower.endsWith('.zip')) {
        if (mounted) showModpackImport(context, initialFilePath: file.path);
        return;
      }
    }
  }

  static const _navItems = [
    (AppRoutes.home, Icons.play_circle_outline_rounded, '启动'),
    (AppRoutes.download, Icons.download_outlined, '下载'),
    (AppRoutes.versions, Icons.folder_copy_outlined, '版本'),
    (AppRoutes.mods, Icons.extension_outlined, '模组'),
    (AppRoutes.accounts, Icons.people_outline, '账户'),
    (AppRoutes.settings, Icons.settings_outlined, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    final ref = this.ref;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = ref.watch(appSettingsProvider);
    final bgPath = settings.backgroundImagePath;
    final hasBg = bgPath.isNotEmpty && File(bgPath).existsSync();
    // 有背景图时侧边栏半透明，让背景透出
    final sidebarColor = hasBg
        ? (isDark ? const Color(0xCC17181A) : const Color(0xB8FFFFFF))
        : (isDark ? const Color(0xFF1B1E23) : const Color(0xFFF7F8FA));
    final account = ref.watch(currentAccountProvider);

    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _handleDropped,
        child: Stack(
          fit: StackFit.expand,
        children: [
          // ---------- 拖拽覆盖提示 ----------
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withAlpha(70),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 18),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(AppTheme.radiusXL),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 1.6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inventory_2_rounded),
                        SizedBox(width: 10),
                        Text('松开以导入整合包（.mrpack）',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // ---------- 背景图层（用户自定义） ----------
          if (hasBg)
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: settings.backgroundBlur / 4,
                  sigmaY: settings.backgroundBlur / 4,
                  tileMode: TileMode.decal,
                ),
                child: Opacity(
                  opacity: settings.backgroundOpacity.clamp(5, 100) / 100,
                  child: Image.file(
                    File(bgPath),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          // ---------- 主体内容 ----------
          Column(
        children: [
          const CustomTitleBar(),
          Expanded(
            child: Row(
              children: [
                // ---------- 侧边栏 ----------
                Container(
                  width: 190,
                  color: sidebarColor,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 16, 20),
                        child: Row(
                          children: [
                            const FmclLogo(size: 38),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'FMCL',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  Text(
                                    'Fluent MC Launcher',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withAlpha(110),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 导航项（按分支索引高亮）
                      ..._navItems.map((item) {
                        final index = _navItems.indexOf(item);
                        return _NavItem(
                          icon: item.$2,
                          label: item.$3,
                          selected: shell.currentIndex == index,
                          onTap: () => shell.goBranch(
                            index,
                            initialLocation: index == shell.currentIndex,
                          ),
                        );
                      }),
                      const Spacer(),
                      // 底部账户卡
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: _AccountMiniCard(account: account),
                      ),
                      if (Platform.isAndroid)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Android 预览版',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withAlpha(100),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // ---------- 内容区 ----------
                Expanded(
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.horizontal(left: Radius.circular(0)),
                    child: shell,
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ],
      ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedColor =
        isDark ? AppTheme.brandPrimary.withAlpha(46) : AppTheme.brandPrimary.withAlpha(30);
    final hoverColor = isDark ? Colors.white.withAlpha(14) : Colors.black.withAlpha(10);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: widget.selected
                ? selectedColor
                : _hover
                    ? hoverColor
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusM),
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppTheme.radiusM),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 21,
                    color: widget.selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withAlpha(150),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: widget.selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: widget.selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface.withAlpha(190),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountMiniCard extends StatelessWidget {
  final GameAccount? account;

  const _AccountMiniCard({this.account});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: () => context.go(AppRoutes.accounts),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withAlpha(40),
            child: Text(
              account?.name.isNotEmpty == true
                  ? account!.name.characters.first.toUpperCase()
                  : '?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account?.name ?? '未登录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  account?.typeLabel ?? '点击添加账户',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(90),
          ),
        ],
      ),
    );
  }
}
