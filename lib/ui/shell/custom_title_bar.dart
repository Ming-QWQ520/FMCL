import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/app_constants.dart';

/// 自绘标题栏（PCL2 / Windows 11 风格）。
///
/// - 仅由 [AppShell] 渲染一次（页面内部不得再渲染，避免出现双层标题栏）
/// - 窗口按钮为全高方形热区，Hover 为 120ms 平滑过渡
/// - 关闭键 Hover 为系统红（#E81123），按下加深
/// - 拖拽区支持双击最大化 / 还原
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({super.key});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      _refreshMaximized();
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
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

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isLinux) {
      return const SizedBox(height: 8);
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 40,
      color: isDark ? const Color(0xFF202124) : const Color(0xFFF3F4F6),
      child: Row(
        children: [
          // ---------- 拖拽区 + 标题 ----------
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
                      Text(
                        AppConstants.appName,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(150),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        AppConstants.appFullName,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ---------- 窗口控制按钮（Windows 标准布局） ----------
          _WindowButton(
            icon: Icons.horizontal_rule_rounded,
            hoverColor: isDark ? Colors.white.withAlpha(26) : Colors.black.withAlpha(20),
            pressedColor: isDark ? Colors.white.withAlpha(40) : Colors.black.withAlpha(34),
            onPressed: windowManager.minimize,
          ),
          _WindowButton(
            icon: _maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            iconSize: 15,
            hoverColor: isDark ? Colors.white.withAlpha(26) : Colors.black.withAlpha(20),
            pressedColor: isDark ? Colors.white.withAlpha(40) : Colors.black.withAlpha(34),
            onPressed: _toggleMaximize,
          ),
          _WindowButton(
            icon: Icons.close_rounded,
            hoverColor: const Color(0xFFE81123),
            pressedColor: const Color(0xFFF1707A),
            hoverIconColor: Colors.white,
            onPressed: windowManager.close,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    _refreshMaximized();
  }
}

/// 全高方形窗口按钮（PCL2 式：无圆角、热区占满标题栏高度）。
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final Color hoverColor;
  final Color pressedColor;
  final Color? hoverIconColor;
  final VoidCallback onPressed;

  const _WindowButton({
    required this.icon,
    required this.hoverColor,
    required this.pressedColor,
    required this.onPressed,
    this.hoverIconColor,
    this.iconSize = 16,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final baseIcon = Theme.of(context).colorScheme.onSurface.withAlpha(170);
    final iconColor = _pressed
        ? (widget.hoverIconColor ?? baseIcon)
        : _hover
            ? (widget.hoverIconColor ?? baseIcon)
            : baseIcon;

    return MouseRegion(
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
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          width: 46,
          height: 40,
          color: _pressed
              ? widget.pressedColor
              : _hover
                  ? widget.hoverColor
                  : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}
