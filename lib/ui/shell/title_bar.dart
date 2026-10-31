/// 自绘标题栏 —— 100% 对齐 PCL2 FormMain 布局（规格取自 PCL 源码）：
///
/// - PanTitle 高 48，主题色背景（FormMain.xaml: Grid PanTitle Height=48）
/// - 左侧：FMCL 标识（对应 PCL2 ShapeTitleLogo 位置，Margin 19/15.5）
/// - 中部：PanTitleSelect（Margin 13,0 / Height 27）水平导航单选按钮
///   「启动 / 下载 / 设置 / 更多」（MyRadioButton：Margin 5,0 / Padding 2,0 /
///   CornerRadius 13.5 胶囊，图标+文字，hover 半透明白底）
/// - 右侧：窗口按钮 28×28 圆形（MyIconButton CornerRadius=1000，
///   hover 白 α50/255 圆形底，按下缩放 0.8 → 回弹 1.05 → 1.0；
///   BtnTitleClose 右距 12、BtnTitleMin 右距 44，PCL2 无最大化按钮）
/// - 关闭按钮绝不等待任何异步任务：设置保存改为 fire-and-forget，
///   点击后立即关窗
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../state/app_providers.dart';

/// 页面标题（与 app_shell 的页面顺序一致）
const List<String> kPageTitles = ['启动', '下载', '设置', '更多'];

class FmclTitleBar extends ConsumerStatefulWidget {
  const FmclTitleBar({super.key});

  @override
  ConsumerState<FmclTitleBar> createState() => _FmclTitleBarState();
}

class _FmclTitleBarState extends ConsumerState<FmclTitleBar> {
  /// 双击标题栏切换最大化（PCL2 无独立最大化按钮，靠拖拽/双击/边缘调整）
  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 记住窗口大小（PCL2 式记忆）。fire-and-forget：绝不阻塞关窗。
  void _rememberWindowSize() {
    unawaited(_saveWindowSize());
  }

  Future<void> _saveWindowSize() async {
    try {
      final size = await windowManager.getSize();
      final s = ref.read(settingsProvider);
      await ref
          .read(settingsProvider.notifier)
          .update(
            s.copyWithLocal(
              windowLauncherWidth: size.width.toInt(),
              windowLauncherHeight: size.height.toInt(),
            ),
          );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isWindows) {
      return const SizedBox(width: double.infinity, height: 6);
    }
    final pageIndex = ref.watch(pageIndexProvider);

    // PCL2 标题栏始终使用主题色（FormMain PanTitle：主题色渐变背景 +
    // 白色导航按钮，浅色/夜间模式一致）
    return Container(
      height: 48,
      color: const Color(0xFF3478F6),
      child: Row(
        children: [
          // ---------- 左侧标识（拖拽区，ShapeTitleLogo 位置 Margin 19） ----------
          GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMaximize,
            behavior: HitTestBehavior.translucent,
            child: Container(
              height: 48,
              padding: const EdgeInsets.only(left: 19),
              alignment: Alignment.centerLeft,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'FMCL',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 7),
                ],
              ),
            ),
          ),
          // ---------- 中部导航（PanTitleSelect：Margin 13,0 / Height 27） ----------
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
              behavior: HitTestBehavior.translucent,
              child: Center(
                heightFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < kPageTitles.length; i++)
                      _TitleNavButton(index: i, selected: pageIndex == i),
                  ],
                ),
              ),
            ),
          ),
          // ---------- 右侧窗口按钮（28×28 圆形；Min 右距 44 / Close 右距 12） ----------
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 4),
                _WindowButton(
                  icon: Icons.minimize_rounded,
                  onPressed: windowManager.minimize,
                  tooltip: '最小化',
                ),
                const SizedBox(width: 4),
                _WindowButton(
                  icon: Icons.close_rounded,
                  onPressed: () {
                    // 立即关窗；窗口大小记忆 fire-and-forget，
                    // 绝不 await（旧版在此处 await 导致 X「无反应」）
                    _rememberWindowSize();
                    unawaited(windowManager.close());
                  },
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏导航按钮（PCL2 MyRadioButton：高 27 / Margin 5,0 / Padding 2,0 /
/// CornerRadius 13.5 胶囊，图标 15 + 文字 13，hover 半透明白底）
class _TitleNavButton extends ConsumerStatefulWidget {
  final int index;
  final bool selected;

  const _TitleNavButton({required this.index, required this.selected});

  @override
  ConsumerState<_TitleNavButton> createState() => _TitleNavButtonState();
}

class _TitleNavButtonState extends ConsumerState<_TitleNavButton> {
  bool _hover = false;

  static const List<IconData> _icons = [
    Icons.play_arrow_rounded,
    Icons.download_rounded,
    Icons.settings_rounded,
    Icons.apps_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final bg = selected
        ? Colors.white.withAlpha(46)
        : _hover
        ? Colors.white.withAlpha(26)
        : Colors.transparent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => ref.read(pageIndexProvider.notifier).set(widget.index),
        // 空消费双击：避免冒泡到标题栏拖拽区的双击最大化
        onDoubleTap: () {},
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: 27,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(13.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icons[widget.index], size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                kPageTitles[widget.index],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: Colors.white.withAlpha(selected ? 255 : 215),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 窗口按钮（PCL2 MyIconButton：28×28 圆形 CornerRadius=1000，
/// hover 白 α50 圆形底，按下缩放 0.8 / 释放回弹 1.05 → 1.0）
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hover ? Colors.white.withAlpha(50) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Transform.scale(
              scale: _pressed ? 0.8 : 1.0,
              child: Icon(widget.icon, size: 15, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 拖拽区域包装（页面内顶部辅助拖拽）
class DragArea extends StatelessWidget {
  final Widget child;

  const DragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isWindows) return child;
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}
