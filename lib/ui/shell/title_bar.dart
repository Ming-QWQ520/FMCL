/// 自绘标题栏（Windows 11 风格，修复 Hover 体验）。
///
/// - 全高方形热区，Hover 130ms 平滑过渡
/// - 最小化/最大化 Hover：半透明底色；关闭 Hover：系统红 #E81123
/// - 拖拽区支持双击最大化/还原；左侧显示应用名与当前页面
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';

class FmclTitleBar extends ConsumerStatefulWidget {
  final String currentPage;

  const FmclTitleBar({super.key, required this.currentPage});

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

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isWindows) {
      return const SizedBox(width: double.infinity, height: 6);
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = ref.watch(settingsProvider);
    final bg = isDark ? const Color(0xFF202124) : const Color(0xFFEFF1F4);

    return Container(
      height: 38,
      color: bg,
      child: Row(
        children: [
          // ---------- 拖拽区 ----------
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
              behavior: HitTestBehavior.translucent,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'FMCL',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                          color: kAccent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.currentPage,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ),
                      if (settings.lastVersionId.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: kAccent.withAlpha(22),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            settings.lastVersionId,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: kAccent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ---------- 窗口控制（Windows 标准布局） ----------
          _WindowButton(
            icon: Icons.horizontal_rule_rounded,
            hoverFill: isDark
                ? Colors.white.withAlpha(30)
                : Colors.black.withAlpha(20),
            pressedFill: isDark
                ? Colors.white.withAlpha(46)
                : Colors.black.withAlpha(34),
            hoverIconColor: isDark ? Colors.white : Colors.black87,
            onPressed: windowManager.minimize,
            tooltip: '最小化',
          ),
          _WindowButton(
            icon: _maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            iconSize: 14,
            hoverFill: isDark
                ? Colors.white.withAlpha(30)
                : Colors.black.withAlpha(20),
            pressedFill: isDark
                ? Colors.white.withAlpha(46)
                : Colors.black.withAlpha(34),
            hoverIconColor: isDark ? Colors.white : Colors.black87,
            onPressed: _toggleMaximize,
            tooltip: _maximized ? '向下还原' : '最大化',
          ),
          _WindowButton(
            icon: Icons.close_rounded,
            hoverFill: kDanger,
            pressedFill: const Color(0xFFF1707A),
            hoverIconColor: Colors.white,
            onPressed: () async {
              // 记住窗口大小后关闭（PCL2 式记忆）
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
              await windowManager.close();
            },
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

/// 全高方形窗口按钮（Hover/按下状态显式分层，修复原 Hover 过淡问题）
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final Color hoverFill;
  final Color pressedFill;
  final Color hoverIconColor;
  final VoidCallback onPressed;
  final String tooltip;

  const _WindowButton({
    required this.icon,
    required this.hoverFill,
    required this.pressedFill,
    required this.hoverIconColor,
    required this.onPressed,
    required this.tooltip,
    this.iconSize = 15,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final idleIcon = isDark ? Colors.white70 : Colors.black54;
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
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            width: 46,
            height: 38,
            color: _pressed
                ? widget.pressedFill
                : _hover
                ? widget.hoverFill
                : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: (_hover || _pressed) ? widget.hoverIconColor : idleIcon,
            ),
          ),
        ),
      ),
    );
  }
}

/// 拖拽区域包装（页面内顶部辅助拖拽；避免出现双层标题栏时使用）
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
