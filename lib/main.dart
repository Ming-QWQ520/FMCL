import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'rust_bridge/rust_bridge.dart' as rust;
import 'state/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- 全局错误捕获（Rust 侧同时落盘） ----------
  FlutterError.onError = (details) {
    debugPrint('[Flutter] ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[Dart] $error\n$stack');
    return true;
  };

  // ---------- 桌面窗口（无边框 + 自绘标题栏） ----------
  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1120, 720),
      minimumSize: Size(960, 620),
      center: true,
      backgroundColor: Color(0xFFF3F4F6),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden, // 自绘标题栏（runner 已处理 NCCALCSIZE）
      title: 'FMCL',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setTitle('FMCL - Fluent Minecraft Launcher');
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // ---------- Rust 后端（目录解析 + 日志系统在此初始化） ----------
  await rust.initRustBridge();
  final info = await rust.initApp();
  debugPrint(
      '[Main] FMCL ${info.appVersion} | FMCL 根: ${info.fmclRoot} | 默认游戏目录: ${info.defaultGameDir}');

  // ---------- 启动 Provider 体系 ----------
  final container = ProviderContainer();
  await container.read(settingsProvider.notifier).reload();
  // ---------- 记忆的窗口尺寸（PCL2 式恢复上次窗口大小） ----------
  try {
    if (!kIsWeb && Platform.isWindows) {
      final s = container.read(settingsProvider);
      if (s.windowLauncherWidth > 200 && s.windowLauncherHeight > 200) {
        await windowManager.setSize(Size(
          s.windowLauncherWidth.toDouble(),
          s.windowLauncherHeight.toDouble(),
        ));
      }
    }
  } catch (_) {}

  runApp(UncontrolledProviderScope(
    container: container,
    child: const FmclApp(),
  ));
}

/// 日志目录（兼容入口）
Future<String> logsDirectory() async {
  final info = await rust.initApp();
  return info.logsDir;
}
