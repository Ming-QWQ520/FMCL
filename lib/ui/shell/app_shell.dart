/// 应用外壳：标题栏 + 左侧图标导航 + 内容区（PCL2 布局）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../pages/accounts_page.dart';
import '../pages/download_page.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../pages/settings_page.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';
import 'title_bar.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _ShellScaffold();
  }
}

const List<String> _titles = ['主页', '下载', '账户', '日志', '设置'];
const List<IconData> _icons = [
  Icons.home_rounded,
  Icons.download_rounded,
  Icons.person_rounded,
  Icons.article_outlined,
  Icons.settings_rounded,
];

/// 背景图存在性缓存：existsSync 是同步 IO，不得在每次 rebuild 时执行
/// （路径指向网络盘/失效 UNC 时可阻塞 UI 线程数百毫秒甚至秒级）。
/// 按路径缓存一次判定结果；文件运行中被删除时由 Image.file 的
/// errorBuilder 兜底，不影响显示。
final Map<String, bool> _bgExistsCache = {};

bool _bgFileExists(String path) {
  return _bgExistsCache.putIfAbsent(path, () {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  });
}

class _ShellScaffold extends ConsumerStatefulWidget {
  const _ShellScaffold();

  @override
  ConsumerState<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends ConsumerState<_ShellScaffold> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(localVersionsProvider.notifier).refresh();
      ref.read(accountsProvider.notifier).reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final isDark = isDarkTheme(context, settings);
    final pageIndex = ref.watch(pageIndexProvider);

    return Scaffold(
      body: Column(
        children: [
          FmclTitleBar(currentPage: _titles[pageIndex]),
          Expanded(
            child: Row(
              children: [
                _buildRail(isDark, pageIndex),
                Expanded(
                  child: _buildPage(context, settings, isDark, pageIndex),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRail(bool isDark, int pageIndex) {
    return Container(
      width: 76,
      color: isDark ? const Color(0xFF232528) : const Color(0xFFECEEF1),
      child: Column(
        children: [
          const SizedBox(height: 10),
          for (var i = 0; i < _titles.length; i++)
            _RailItem(
              icon: _icons[i],
              label: _titles[i],
              selected: pageIndex == i,
              isDark: isDark,
              onTap: () => ref.read(pageIndexProvider.notifier).set(i),
            ),
          const Spacer(),
          // 启动中的会话指示
          Consumer(
            builder: (context, ref, _) {
              final sessions = ref.watch(launchSessionsProvider);
              final active = sessions.where((s) => s.isActive).length;
              if (active == 0) return const SizedBox(height: 14);
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PclTag('$active 个游戏运行中', color: Colors.green),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPage(
    BuildContext context,
    SettingsData settings,
    bool isDark,
    int pageIndex,
  ) {
    Widget page;
    switch (pageIndex) {
      case 0:
        page = const HomePage();
        break;
      case 1:
        page = const DownloadPage();
        break;
      case 2:
        page = const AccountsPage();
        break;
      case 3:
        page = const LogsPage();
        break;
      default:
        page = const SettingsPage();
    }
    final bg = isDark ? kDarkBg : kLightBg;
    final Stack stack = Stack(
      children: [
        // 背景图（PCL2 式自定义背景）
        if (settings.backgroundImagePath.trim().isNotEmpty &&
            _bgFileExists(settings.backgroundImagePath.trim()))
          Positioned.fill(
            child: Opacity(
              opacity: (settings.backgroundOpacity.clamp(0, 100)) / 100,
              child: Image.file(
                File(settings.backgroundImagePath.trim()),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        Positioned.fill(child: page),
      ],
    );
    return Container(color: bg, child: stack);
  }
}

class _RailItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.selected || _hover ? kAccent : null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? kAccent.withAlpha(30)
                : _hover
                ? kAccent.withAlpha(14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            children: [
              Icon(
                widget.icon,
                size: 21,
                color:
                    accent ?? (widget.isDark ? Colors.white60 : Colors.black54),
              ),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color:
                      accent ??
                      (widget.isDark ? Colors.white54 : Colors.black45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
