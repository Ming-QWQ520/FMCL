import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'rust_bridge/rust_bridge.dart' as rust;
import 'state/app_providers.dart';

/// 把 Dart 侧错误转发到 Rust 落盘（latest.log），静默失败。
void _logToRustFile(String level, String module, String message) {
  try {
    rust.forwardLogToRust(level, module, message);
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- 全局错误捕获（处理函数自身绝不抛错，避免二次异常杀死应用） ----------
  FlutterError.onError = (details) {
    try {
      debugPrint('[Flutter] ${details.exceptionAsString()}');
      _logToRustFile('ERROR', 'Flutter', details.exceptionAsString());
    } catch (_) {}
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    try {
      debugPrint('[Dart] $error\n$stack');
      _logToRustFile('ERROR', 'Dart', '$error');
    } catch (_) {}
    return true;
  };

  // release 模式默认 ErrorWidget 几乎不可见（白屏假象）：
  // 任何构建期错误都渲染为明确的错误页，杜绝"白屏却不知原因"。
  ErrorWidget.builder = (details) {
    try {
      debugPrint('[Build] ${details.exceptionAsString()}');
      _logToRustFile('ERROR', 'Build', details.exceptionAsString());
    } catch (_) {}
    return StartupErrorView(
      title: '界面渲染出错',
      message: details.exceptionAsString(),
      stack: details.stack?.toString(),
      hint: '完整日志位于启动器目录 FMCL\\logs\\latest.log，'
          '可将该文件发送给开发者定位问题。',
    );
  };

  // ---------- 桌面窗口（无边框 + 自绘标题栏，先创建但暂不显示） ----------
  // 窗口延迟到 runApp 之后显示：初始化 Rust/设置期间（杀毒扫描 dll 可达数秒）
  // 不再出现无内容的白窗，用户看到窗口时内容已就绪。
  if (!kIsWeb && Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      const options = WindowOptions(
        size: Size(1120, 720),
        minimumSize: Size(960, 620),
        center: true,
        // 切勿设置 backgroundColor：
        // window_manager 0.5.x 在 Windows 上经 SetWindowCompositionAttribute
        // (ACCENT_ENABLE_GRADIENT) 实现背景色，不透明色会在新版 Flutter 的
        // DirectComposition 渲染下盖住全部窗口内容 → 纯白屏
        // （参考 leanflutter/window_manager#481，0.6.0 重写前无官方修复）。
        // 不设置即为普通不透明 DWM 窗口，内容正常渲染。
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden, // 自绘标题栏（runner 已处理 NCCALCSIZE）
        title: 'FMCL',
      );
      await windowManager.waitUntilReadyToShow(options, () {});
    } catch (e, s) {
      debugPrint('[Main] 窗口初始化异常（继续启动）: $e\n$s');
      _logToRustFile('ERROR', 'Main', '窗口初始化异常: $e');
    }
  }

  // ---------- Rust 后端（目录解析 + 日志系统在此初始化） ----------
  // 桥初始化失败属致命错误（全部业务逻辑在 Rust 侧），但绝不能以白屏收场：
  // 捕获后直接渲染明确的错误页（常见原因：rust_lib_fmcl.dll 被杀毒软件
  // 隔离或压缩包解压不完整）。20 秒超时兜底：即使响应意外挂起也给出错误页。
  String? fatalMessage;
  try {
    await rust
        .initRustBridge()
        .timeout(const Duration(seconds: 20));
    final info = await rust
        .initApp()
        .timeout(const Duration(seconds: 20));
    debugPrint(
      '[Main] FMCL ${info.appVersion} | FMCL 根: ${info.fmclRoot} | 默认游戏目录: ${info.defaultGameDir}',
    );
  } catch (e, s) {
    fatalMessage = '$e';
    debugPrint('[Main] Rust 后端初始化失败: $e\n$s');
  }

  // ---------- 启动 Provider 体系 ----------
  final container = ProviderContainer();
  if (fatalMessage == null) {
    try {
      await container
          .read(settingsProvider.notifier)
          .reload()
          .timeout(const Duration(seconds: 20));
    } catch (e, s) {
      // 设置加载失败不致命：Notifier 已有默认值兜底，界面照常可用
      debugPrint('[Main] 设置加载失败（使用默认设置）: $e\n$s');
      _logToRustFile('WARN', 'Main', '设置加载失败（使用默认设置）: $e');
    }
    // ---------- 记忆的窗口尺寸（PCL2 式恢复上次窗口大小，显示前完成避免闪烁） ----------
    if (!kIsWeb && Platform.isWindows) {
      try {
        final s = container.read(settingsProvider);
        if (s.windowLauncherWidth > 200 && s.windowLauncherHeight > 200) {
          await windowManager.setSize(
            Size(
              s.windowLauncherWidth.toDouble(),
              s.windowLauncherHeight.toDouble(),
            ),
          );
        }
      } catch (_) {}
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: fatalMessage != null
          ? StartupErrorView(
              title: 'FMCL 核心初始化失败',
              message: fatalMessage,
              hint: '全部核心逻辑位于 rust_lib_fmcl.dll，加载失败通常因为：\n'
                  '· 杀毒软件（如 Windows Defender / 360）隔离了该 dll —— 请在'
                  '隔离区恢复并添加信任；\n'
                  '· 压缩包未完整解压或解压后移动了单独文件 —— 请完整解压后再运行；\n'
                  '· 缺少 VC++ 运行库 —— 请安装 Microsoft Visual C++ Redistributable。'
                  '\n\n详细日志位于启动器目录 FMCL\\logs\\latest.log。',
            )
          : const FmclApp(),
    ),
  );

  // ---------- 内容就绪后再显示窗口 ----------
  if (!kIsWeb && Platform.isWindows) {
    try {
      await windowManager.setTitle('FMCL - Fluent Minecraft Launcher');
      await windowManager.show();
      await windowManager.focus();
    } catch (e, s) {
      debugPrint('[Main] 窗口显示异常: $e\n$s');
    }
  }
}

/// 启动期错误可见化页面（release 模式下替代默认的"隐形"ErrorWidget）。
class StartupErrorView extends StatelessWidget {
  final String title;
  final String message;
  final String? stack;
  final String? hint;

  const StartupErrorView({
    super.key,
    required this.title,
    required this.message,
    this.stack,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final stack = this.stack;
    final stackTail = (stack == null || stack.isEmpty)
        ? ''
        : stack.split('\n').take(14).join('\n');
    final hint = this.hint;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      home: Container(
        color: const Color(0xFFF6F7F9),
        padding: const EdgeInsets.all(28),
        alignment: Alignment.center,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 780),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE5484D), width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.error_outline_rounded, color: Color(0xFFE5484D)),
                  SizedBox(width: 10),
                  Text(
                    'FMCL 启动异常',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2328)),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3A3F45)),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  message,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.5, color: Color(0xFF3A3F45)),
                ),
                if (stackTail.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SelectableText(
                    stackTail,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: const Color(0xFF1F2328).withAlpha(150),
                        fontFamily: 'monospace'),
                  ),
                ],
                if (hint != null && hint.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  SelectableText(
                    hint,
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.55, color: Color(0xFF6A737D)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 日志目录（兼容入口）
Future<String> logsDirectory() async {
  final info = await rust.initApp();
  return info.logsDir;
}
