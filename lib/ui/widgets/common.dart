/// 通用 PCL2 风格组件。
library;

import 'package:flutter/material.dart';

import '../theme/pcl_theme.dart';

/// 圆角面板（PCL2 卡片）
class PclPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  const PclPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: isDark ? kDarkPanel : kLightPanel,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 60 : 16),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
            ),
    );
  }
}

/// 主按钮（PCL2 蓝色圆角）
class PclButton extends StatefulWidget {
  final String text;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final IconData? icon;
  final double height;
  final double fontSize;

  const PclButton({
    super.key,
    required this.text,
    this.onTap,
    this.primary = true,
    this.danger = false,
    this.icon,
    this.height = 38,
    this.fontSize = 14,
  });

  @override
  State<PclButton> createState() => _PclButtonState();
}

class _PclButtonState extends State<PclButton> {
  bool _hover = false;
  bool _press = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color bg;
    Color fg;
    if (widget.danger) {
      bg = _hover ? const Color(0xFFC50F1F) : kDanger;
      fg = Colors.white;
    } else if (widget.primary) {
      bg = _hover ? kAccentDeep : kAccent;
      fg = Colors.white;
    } else {
      bg = _hover
          ? (isDark ? Colors.white.withAlpha(28) : Colors.black.withAlpha(16))
          : (isDark ? Colors.white.withAlpha(14) : Colors.black.withAlpha(8));
      fg = isDark ? const Color(0xFFE6E6E6) : const Color(0xFF1F2328);
    }
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _press = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _press = true),
        onTapCancel: () => setState(() => _press = false),
        onTapUp: (_) => setState(() => _press = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          transform: Matrix4.identity()
            ..scaleByDouble(
              _press ? 0.985 : 1.0,
              _press ? 0.985 : 1.0,
              _press ? 0.985 : 1.0,
              1.0,
            ),
          decoration: BoxDecoration(
            color: enabled
                ? bg
                : (isDark
                      ? Colors.white.withAlpha(10)
                      : Colors.black.withAlpha(6)),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: widget.fontSize + 4, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                widget.text,
                style: TextStyle(
                  color: enabled ? fg : fg.withAlpha(90),
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标签（版本类型 / 加载器）
class PclTag extends StatelessWidget {
  final String text;
  final Color? color;
  final bool filled;

  const PclTag(this.text, {super.key, this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final c = color ?? kAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? c : c.withAlpha(26),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: filled ? Colors.white : c,
        ),
      ),
    );
  }
}

/// 列表条目 Hover 容器（PCL2 列表样式）
class HoverTile extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius? radius;

  const HoverTile({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.radius,
  });

  @override
  State<HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<HoverTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: _hover
              ? (isDark ? Colors.white.withAlpha(14) : kAccent.withAlpha(12))
              : Colors.transparent,
          borderRadius: widget.radius ?? BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: widget.radius ?? BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );
  }
}

/// 进度条（PCL2 风格圆角）
class PclProgress extends StatelessWidget {
  final double value; // 0~1，<0 表示不确定
  final double height;

  const PclProgress({super.key, required this.value, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final track = isDark
        ? Colors.white.withAlpha(20)
        : Colors.black.withAlpha(12);
    if (value < 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: LinearProgressIndicator(
            backgroundColor: track,
            valueColor: const AlwaysStoppedAnimation(kAccent),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: track),
            FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(color: kAccent),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分段选择（下载页子页签）
class Segmented extends StatelessWidget {
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  const Segmented({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(6),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: i == index
                      ? (isDark ? kDarkPanel : kLightPanel)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: i == index
                      ? [
                          BoxShadow(
                            color: Colors.black.withAlpha(20),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  items[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                    color: i == index
                        ? (isDark
                              ? const Color(0xFFE6E6E6)
                              : const Color(0xFF1F2328))
                        : (isDark ? Colors.white60 : Colors.black54),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 空状态
class EmptyView extends StatelessWidget {
  final IconData icon;
  final String text;

  const EmptyView({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: isDark ? Colors.white30 : Colors.black26),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置分组标题
class SectionTitle extends StatelessWidget {
  final String text;

  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Container(width: 3, height: 14, color: kAccent),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// 设置行（标题 + 说明 + 右侧控件）
class SettingRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;

  const SettingRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white38
                          : Colors.black38,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
          const SizedBox(width: 12),
          ?child,
        ],
      ),
    );
  }
}

/// 开关（统一样式）
class PclSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const PclSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: kAccent,
    );
  }
}

/// 版本图标（原版=草方块，加载器=对应图标）
class VersionIcon extends StatelessWidget {
  final String loader;
  final double size;

  const VersionIcon({super.key, required this.loader, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final asset = _assetFor(loader);
    if (asset == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: kAccent.withAlpha(24),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.videogame_asset_outlined,
          size: size * 0.55,
          color: kAccent,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: kAccent.withAlpha(24),
          child: Icon(
            Icons.videogame_asset_outlined,
            size: size * 0.55,
            color: kAccent,
          ),
        ),
      ),
    );
  }

  String? _assetFor(String loader) {
    switch (loader) {
      case 'vanilla':
      case '':
        return 'assets/img/hmcl/grass.png'; // 原版 = 草方块
      case 'forge':
        return 'assets/img/hmcl/forge.png';
      case 'neoforge':
        return 'assets/img/hmcl/neoforge.png';
      case 'fabric':
        return 'assets/img/hmcl/fabric.png';
      case 'quilt':
        return 'assets/img/hmcl/quilt.png';
      case 'optifine':
        return 'assets/img/hmcl/optifine.png';
      case 'legacyfabric':
        return 'assets/img/hmcl/legacyfabric.png';
      default:
        return 'assets/img/hmcl/unknown_pack.png';
    }
  }
}

/// 加载器中文标签
String loaderLabel(String loader) {
  switch (loader) {
    case 'vanilla':
      return '原版';
    case 'forge':
      return 'Forge';
    case 'neoforge':
      return 'NeoForge';
    case 'fabric':
      return 'Fabric';
    case 'quilt':
      return 'Quilt';
    case 'optifine':
      return 'OptiFine';
    default:
      return '未知';
  }
}

/// 字节数格式化
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
