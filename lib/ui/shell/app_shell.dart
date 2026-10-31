/// 应用外壳 —— 100% 对齐 PCL2 FormMain 布局：
///
/// - 顶部标题栏内含水平导航（启动 / 下载 / 设置 / 更多）
/// - 无左侧栏（PCL2 的 PanLeft 仅是页面切换动画层，非导航）
/// - 页面为全区域：背景图铺满整个内容区（PCL2 ImgBack）
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../pages/download_page.dart';
import '../pages/home_page.dart';
import '../pages/more_page.dart';
import '../pages/settings_page.dart';
import '../theme/pcl_theme.dart';
import 'title_bar.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _ShellScaffold();
  }
}

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
          const FmclTitleBar(),
          Expanded(child: _buildPage(context, settings, isDark, pageIndex)),
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
        page = const SettingsPage();
        break;
      default:
        page = const MorePage();
    }
    final bg = isDark ? kDarkBg : kLightBg;
    final Stack stack = Stack(
      children: [
        // 背景图（PCL2 式自定义背景，铺满内容区）
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
