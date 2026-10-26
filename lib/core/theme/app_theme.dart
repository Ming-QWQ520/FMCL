import 'package:flutter/material.dart';

/// FMCL 设计令牌与主题。
///
/// 设计方向：PCL2 式圆角卡片布局 + 简洁克制的白底黑字主配色——
/// 白色背景、黑色文字、中性灰分层，仅保留少量功能强调色。
class AppTheme {
  AppTheme._();

  // ---------------- 品牌色板 ----------------

  /// 主色（正文黑 / 主按钮黑）
  static const Color brandPrimary = Color(0xFF1A1A1A);

  /// 主色亮部（深色模式下的主按钮 / 高亮）
  static const Color brandPrimaryLight = Color(0xFFE8E8E8);

  /// 主色深部（按压态）
  static const Color brandPrimaryDark = Color(0xFF000000);

  /// 强调橙（更新提醒、警示性高亮）
  static const Color accentOrange = Color(0xFFD97706);

  /// 强调蓝（信息、链接）
  static const Color accentBlue = Color(0xFF2563EB);

  /// 强调红（错误）
  static const Color accentRed = Color(0xFFDC2626);

  // ---------------- 圆角与间距 ----------------

  static const double radiusS = 8;
  static const double radiusM = 12;
  static const double radiusL = 16;
  static const double radiusXL = 22;

  static const EdgeInsets pagePadding = EdgeInsets.all(20);
  static const EdgeInsets cardPadding = EdgeInsets.all(16);

  // ---------------- 亮色主题 ----------------

  static ThemeData light({bool transparentScaffold = false}) =>
      _build(Brightness.light, transparentScaffold: transparentScaffold);

  // ---------------- 深色主题 ----------------

  static ThemeData dark({bool transparentScaffold = false}) =>
      _build(Brightness.dark, transparentScaffold: transparentScaffold);

  static ThemeData _build(
    Brightness brightness, {
    bool transparentScaffold = false,
  }) {
    final isDark = brightness == Brightness.dark;

    // 白底黑字：亮色 = 纯白背景 + 近黑文字；深色 = 中性深灰 + 白字
    final bgColor = isDark ? const Color(0xFF17181A) : Colors.white;
    final cardColor = isDark ? const Color(0xFF1F2023) : Colors.white;
    final textMain = isDark ? const Color(0xFFF2F2F2) : const Color(0xFF111111);
    final textSub = isDark ? const Color(0xFFB8B8BC) : const Color(0xFF555555);
    final outline = isDark ? const Color(0xFF34353A) : const Color(0xFFE4E4E7);
    final inputFill = isDark ? const Color(0xFF26272B) : const Color(0xFFF6F6F7);
    final primary = isDark ? Colors.white : const Color(0xFF111111);
    final onPrimary = isDark ? const Color(0xFF111111) : Colors.white;

    final scheme = ColorScheme.fromSeed(
      seedColor: isDark ? const Color(0xFF9E9E9E) : const Color(0xFF333333),
      brightness: brightness,
    ).copyWith(
      primary: primary,
      onPrimary: onPrimary,
      secondary: primary,
      onSecondary: onPrimary,
      surface: cardColor,
      onSurface: textMain,
      surfaceContainerHighest: isDark ? const Color(0xFF26272B) : inputFill,
      outline: outline,
      error: accentRed,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 背景图模式下页面底色透明，让背景图层在 AppShell 底部透出
      scaffoldBackgroundColor:
          transparentScaffold ? Colors.transparent : bgColor,
      fontFamily: null, // 跟随系统字体（Windows: 微软雅黑 / HarmonyOS Sans 等）
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            bodyColor: textMain,
            displayColor: textMain,
          ),

      // 卡片：白底 + 细边框，保持层次
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusL),
          side: BorderSide(color: outline, width: 1),
        ),
      ),

      // 输入框
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusM),
          borderSide: BorderSide(
              color: isDark ? Colors.white54 : const Color(0xFF111111),
              width: 1.4),
        ),
        hintStyle: TextStyle(color: textSub.withAlpha(120), fontSize: 14),
        labelStyle: TextStyle(color: textSub, fontSize: 14),
      ),

      // 按钮：黑底白字（亮色）/ 白底黑字（深色）
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          minimumSize: const Size(64, 42),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusM),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textMain,
          minimumSize: const Size(64, 42),
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusM),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? Colors.white : const Color(0xFF111111),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusS),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: isDark ? Colors.white70 : const Color(0xFF3F3F46),
        ),
      ),

      // 对话框 / 底部面板
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXL),
        ),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: textMain,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXL)),
        ),
        showDragHandle: true,
      ),

      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),

      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusM),
        ),
        iconColor: isDark ? Colors.white70 : const Color(0xFF3F3F46),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: textMain,
        unselectedLabelColor: textSub,
        indicatorColor: textMain,
        dividerColor: outline,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF2A2B2F) : const Color(0xFF1A1A1A),
        contentTextStyle: TextStyle(color: isDark ? Colors.white : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusM),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: textMain,
        linearTrackColor: outline,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onPrimary;
          return isDark ? const Color(0xFF8A8A8E) : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return isDark ? Colors.white60 : const Color(0xFF1A1A1A);
          }
          return isDark ? const Color(0xFF3A3B40) : const Color(0xFFD9D9DE);
        }),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: isDark ? Colors.white : const Color(0xFF1A1A1A),
        thumbColor: isDark ? Colors.white : const Color(0xFF1A1A1A),
        inactiveTrackColor: outline,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF3A3B40) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(radiusS),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: bgColor,
        foregroundColor: textMain,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: bgColor,
        selectedIconTheme: IconThemeData(color: textMain),
        unselectedIconTheme: IconThemeData(color: textSub),
        selectedLabelTextStyle: TextStyle(
            color: textMain, fontWeight: FontWeight.w700, fontSize: 13),
        unselectedLabelTextStyle: TextStyle(color: textSub, fontSize: 12.5),
      ),
    );
  }
}

/// 文本样式快捷扩展
extension AppTextStyle on BuildContext {
  /// 页面标题
  TextStyle get titleStyle => TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: Theme.of(this).colorScheme.onSurface,
      );

  /// 分区标题
  TextStyle get sectionTitle => TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Theme.of(this).colorScheme.onSurface,
      );

  /// 次要说明文字
  TextStyle get captionStyle => TextStyle(
        fontSize: 13,
        color: Theme.of(this).colorScheme.onSurface.withAlpha(150),
      );
}
