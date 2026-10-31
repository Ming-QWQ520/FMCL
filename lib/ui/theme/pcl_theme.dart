/// PCL2 风格主题（浅色 / 深色 / 跟随系统）。
///
/// 视觉基线对齐 Plain Craft Launcher 2：
/// - 主色蓝 #3478F6，圆角面板 + 细腻投影
/// - 内容卡片白底圆角 10px，页面底色 #F3F4F6（深色 #1E1F22）
library;

import 'package:flutter/material.dart';

import '../../state/app_providers.dart';

const Color kAccent = Color(0xFF3478F6);
const Color kAccentDeep = Color(0xFF2B62CE);
const Color kDanger = Color(0xFFE81123);
const Color kLightBg = Color(0xFFF3F4F6);
const Color kLightPanel = Color(0xFFFFFFFF);
const Color kDarkBg = Color(0xFF1E1F22);
const Color kDarkPanel = Color(0xFF282A2E);

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(seedColor: kAccent, brightness: brightness).copyWith(
        primary: kAccent,
        secondary: kAccent,
        surface: isDark ? kDarkPanel : kLightPanel,
        error: kDanger,
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? kDarkBg : kLightBg,
    fontFamilyFallback: const [
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'sans-serif',
    ],
  );
  return base.copyWith(
    splashFactory: InkRipple.splashFactory,
    textTheme: base.textTheme.apply(
      bodyColor: isDark ? const Color(0xFFE6E6E6) : const Color(0xFF1F2328),
      displayColor: isDark ? const Color(0xFFE6E6E6) : const Color(0xFF1F2328),
    ),
    cardTheme: CardThemeData(
      color: isDark ? kDarkPanel : kLightPanel,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? Colors.white.withAlpha(18) : Colors.black.withAlpha(16),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF33363B) : const Color(0xFFF7F8FA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDark
              ? Colors.white.withAlpha(28)
              : Colors.black.withAlpha(28),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDark
              ? Colors.white.withAlpha(28)
              : Colors.black.withAlpha(28),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kAccent, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? kDarkPanel : kLightPanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF3A3D42) : const Color(0xFF3B414B),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
  );
}

/// 主题工具（供页面判断深浅）
bool isDarkTheme(BuildContext context, SettingsData settings) {
  switch (settings.themeMode) {
    case 1:
      return false;
    case 2:
      return true;
    default:
      return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
  }
}
