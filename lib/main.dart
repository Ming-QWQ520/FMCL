import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/logger/app_logger.dart';
import 'providers/settings_provider.dart';
import 'rust_bridge/rust_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- 日志系统 ----------
  final supportDir = await getApplicationSupportDirectory();
  final logsDir = p.join(supportDir.path, 'logs');
  await AppLogger.I.init(logsDir);
  AppLogger.info('Main', '${AppConstants.appFullName} ${AppConstants.appVersion} 启动');

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
      backgroundColor: Colors.transparent,
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

/// 日志目录（供设置页"打开日志"使用）
Future<String> logsDirectory() async {
  final supportDir = await getApplicationSupportDirectory();
  return p.join(supportDir.path, 'logs');
}
