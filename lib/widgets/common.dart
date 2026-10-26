import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import '../core/theme/app_theme.dart';

/// FMCL 品牌标识（渐变圆角方块 + 字标）
class FmclLogo extends StatelessWidget {
  final double size;

  const FmclLogo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.brandPrimaryLight,
            AppTheme.brandPrimary,
            AppTheme.brandPrimaryDark,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.brandPrimary.withAlpha(70),
            blurRadius: size * 0.35,
            offset: Offset(0, size * 0.1),
          ),
        ],
      ),
      child: Center(
        child: Text(
          'F',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.55,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// 圆角卡片容器（PCL2 式 + 现代质感）
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? color;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final card = Card(
      color: color,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: padding ?? AppTheme.cardPadding,
        child: child,
      ),
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusL),
      child: card,
    );
  }
}

/// 分区标题（左侧主色竖条 + 标题 + 可选操作）
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Text(title, style: context.sectionTitle),
          if (subtitle != null) ...[
            const SizedBox(width: 10),
            Expanded(child: Text(subtitle!, style: context.captionStyle)),
          ] else
            const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 带图标的设置行（标题 + 说明 + 控件）
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? description;
  final Widget? trailing;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                if (description != null && description!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      description!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withAlpha(130),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ?trailing,
        ],
      ),
    );
  }
}

/// 文件大小格式化
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 速度格式化
String formatSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 KB/s';
  return '${formatBytes(bytesPerSecond)}/s';
}

/// 应用名辅助
const String kAppName = AppConstants.appName;
