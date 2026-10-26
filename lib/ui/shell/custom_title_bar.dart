import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 自绘标题栏（Windows/Linux 使用；macOS 使用系统按钮区域留白）。
class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isLinux) {
      return const SizedBox(height: 8);
    }
    final isMac = Platform.isMacOS;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (isMac) const SizedBox(width: 78),
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              behavior: HitTestBehavior.translucent,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    'FMCL · Fluent Minecraft Launcher',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(120),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _WindowButton(
            icon: Icons.remove_rounded,
            onPressed: windowManager.minimize,
          ),
          _WindowButton(
            icon: Icons.crop_square_rounded,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            },
          ),
          _WindowButton(
            icon: Icons.close_rounded,
            isClose: true,
            onPressed: windowManager.close,
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        width: 46,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            hoverColor:
                isClose ? const Color(0xFFE85A6B) : (isDark ? Colors.white12 : Colors.black12),
            child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurface.withAlpha(160)),
          ),
        ),
      ),
    );
  }
}
