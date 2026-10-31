/// 自绘标题栏 —— 100% 对齐 PCL2 FormMain 布局：
///
/// - 高 48（PCL2 PanTitle Height=48）
/// - 左侧：FMCL 标识（PCL2 ShapeTitleLogo 位置）
/// - 中部：水平导航单选按钮「启动 / 下载 / 设置 / 更多」
///   （PCL2 BtnTitleSelect0..4：MyRadioButton，高 27，图标+文字，
///   hover 半透明底、选中主题色底）
/// - 右侧：窗口按钮 28×28（PCL2 BtnTitleClose/BtnTitleMin：
///   Height=28 Width=28，hover 半透明圆角底）
/// - 关闭按钮绝不等待任何异步任务：设置保存改为 fire-and-forget，
///   点击后立即关窗（修复「X 点击无反应」——旧实现 await 设置保存，
///   一旦响应丢失则永不关闭）
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

class _FmclTitleBarState extends ConsumerState<FmclTitleBar>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
      _refreshMaximized();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    try {
      final v = await windowManager.isMaximized();
      if (mounted && v != _maximized) setState(() => _maximized = v);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    _refreshMaximized();
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
          // ---------- 左侧标识（拖拽区） ----------
          GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMaximize,
            behavior: HitTestBehavior.translucent,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'FMCL',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(36),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        '2',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ---------- 中部导航（PCL2 BtnTitleSelect：水平单选按钮） ----------
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
          // ---------- 右侧窗口按钮（PCL2 28×28） ----------
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _WindowButton(
                  icon: Icons.minimize_rounded,
                  onPressed: windowManager.minimize,
                  tooltip: '最小化',
                ),
                const SizedBox(width: 4),
                _WindowButton(
                  icon: _maximized
                      ? Icons.filter_none_rounded
                      : Icons.crop_square_rounded,
                  onPressed: _toggleMaximize,
                  tooltip: _maximized ? '向下还原' : '最大化',
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

/// 顶栏导航按钮（PCL2 MyRadioButton：高 27，图标 + 文字，hover 半透明底）
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
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
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

/// 窗口按钮（PCL2 MyIconButton：28×28，hover 半透明圆角底，点击缩放反馈）
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
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _pressed
                  ? Colors.white.withAlpha(52)
                  : _hover
                  ? Colors.white.withAlpha(34)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 15, color: Colors.white),
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
