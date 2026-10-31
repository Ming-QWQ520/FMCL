import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/dirs/app_dirs.dart';
import 'core/logger/app_logger.dart';
import 'providers/settings_provider.dart';
import 'rust_bridge/rust_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- 便携目录系统（exe 所在目录\FMCL\） ----------
  await AppDirs.init();
  AppDirs.ensureCore();

  // ---------- 日志系统（输出至 exe 所在目录\FMCL\logs\） ----------
  await AppLogger.I.init(AppDirs.logsDir);
  AppLogger.info('Main', '${AppConstants.appFullName} ${AppConstants.appVersion} 启动');
  AppLogger.info(
    'Main',
    '便携目录: root=${AppDirs.fmclRoot} exeDir=${AppDirs.exeDir.isEmpty ? "(非桌面)" : AppDirs.exeDir}',
  );

  // ---------- 全局错误捕获 ----------
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLogger.error(
        'Flutter', details.exceptionAsString(), details.exception, details.stack);
    AppLogger.I.saveCrashReport(
        '${details.exception}\n${details.stack}');
    originalOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('Dart', error.toString(), error, stack);
    AppLogger.I.saveCrashReport('$error\n$stack');
    return true;
  };

  // ---------- 桌面窗口 ----------
  if (!Platform.isAndroid) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1120, 720),
      minimumSize: Size(960, 600),
      center: true,
      // 不透明背景：透明背景 + 隐藏标题栏会在 Windows 顶部产生残影条
      backgroundColor: Color(0xFFF3F4F6),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden, // 自绘标题栏
      title: AppConstants.appFullName,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitle('${AppConstants.appName} · ${AppConstants.appFullName}');
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // ---------- Rust 后端 ----------
  await initRustBridge();

  // ---------- 依赖注入 ----------
  final prefs = await SharedPreferences.getInstance();

  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
    child: const FmclApp(),
  ));
}

/// 日志目录（供设置页"打开日志"使用）：exe 所在目录\FMCL\logs
Future<String> logsDirectory() async {
  return AppDirs.logsDir;
}
