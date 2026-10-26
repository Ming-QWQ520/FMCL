import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'providers/settings_provider.dart';

/// FMCL 应用根组件。
class FmclApp extends ConsumerStatefulWidget {
  const FmclApp({super.key});

  @override
  ConsumerState<FmclApp> createState() => _FmclAppState();
}

class _FmclAppState extends ConsumerState<FmclApp> {
  @override
  void initState() {
    super.initState();
    // 初始化默认游戏目录（Android TODO：使用 SAF 路径，见 TODO.md #A-04）
    Future.microtask(() {
      ref.read(appSettingsProvider.notifier).initGameDirectory();
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeIndex = ref.watch(themeModeIndexProvider);
    final themeMode = switch (themeIndex) {
      1 => ThemeMode.light,
      2 => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final settings = ref.watch(appSettingsProvider);
    final hasBackground = settings.backgroundImagePath.isNotEmpty;

    return MaterialApp.router(
      title: 'FMCL · Fluent Minecraft Launcher',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(transparentScaffold: hasBackground),
      darkTheme: AppTheme.dark(transparentScaffold: hasBackground),
      themeMode: themeMode,
      routerConfig: appRouter,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
    );
  }
}

/// 平台便捷判断
bool get isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
bool get isAndroid => Platform.isAndroid;
