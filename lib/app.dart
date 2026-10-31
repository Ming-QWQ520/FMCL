/// FMCL 应用入口（主题切换 / 外壳）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_providers.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/pcl_theme.dart';

class FmclApp extends ConsumerStatefulWidget {
  const FmclApp({super.key});

  @override
  ConsumerState<FmclApp> createState() => _FmclAppState();
}

class _FmclAppState extends ConsumerState<FmclApp> {
  @override
  void initState() {
    super.initState();
    // 监听系统主题变化（跟随系统模式）
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    dispatcher.onPlatformBrightnessChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final brightness = switch (settings.themeMode) {
      1 => Brightness.light,
      2 => Brightness.dark,
      _ => MediaQuery.platformBrightnessOf(context),
    };
    return MaterialApp(
      title: 'FMCL - Fluent Minecraft Launcher',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: const AppShell(),
      // 中文本地化：DefaultMaterialLocalizations 仅支持英文，在 locale=zh_CN
      // 下不会加载，MaterialLocalizations 为 null —— 任何 TextField /
      // Tooltip / 下拉等组件构建时都会抛
      // "Null check operator used on a null value"（release 无断言直达空检查）。
      // 必须使用 GlobalMaterialLocalizations 提供完整中文资源。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
    );
  }
}
