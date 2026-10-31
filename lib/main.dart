import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

/// 截取堆栈首部 N 行（含关键的应用层帧，去除冗余框架尾部）。
String _trimStack(StackTrace? stack, int lines) {
  if (stack == null) return '';
  final parts = stack.toString().split('\n').take(lines).join('\n');
  return parts;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------- 全局错误捕获（处理函数自身绝不抛错，避免二次异常杀死应用） ----------
  // 注意：必须携带堆栈首部，否则仅凭 "Null check operator used on a null value"
  // 无法定位崩溃点（用户日志定位问题的唯一线索）。
  FlutterError.onError = (details) {
    try {
      final msg =
          '${details.exceptionAsString()}\n${_trimStack(details.stack, 8)}';
      debugPrint('[Flutter] $msg');
      _logToRustFile('ERROR', 'Flutter', msg);
    } catch (_) {}
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    try {
      final msg = '$error\n${_trimStack(stack, 8)}';
      debugPrint('[Dart] $msg');
      _logToRustFile('ERROR', 'Dart', msg);
    } catch (_) {}
    return true;
  };

  // release 模式默认 ErrorWidget 几乎不可见（白屏假象）：
  // 任何构建期错误都渲染为明确的错误页，杜绝"白屏却不知原因"。
  ErrorWidget.builder = (details) {
    try {
      final msg =
          '${details.exceptionAsString()}\n${_trimStack(details.stack, 8)}';
      debugPrint('[Build] $msg');
      _logToRustFile('ERROR', 'Build', msg);
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

  // ---------- 启动流程 ----------
  // 根视图切换器：启动页 → 主界面 / 错误页。
  // 启动页在窗口显示前就已经渲染完毕，因此无论初始化耗时多久
  // （杀毒软件扫描核心 DLL 可能耗时数十秒），用户看到的都是明确的
  // "FMCL 正在启动"而非空白窗口或无响应。
  final stage = ValueNotifier<String>('正在准备界面…');
  final root = ValueNotifier<Widget>(_BootstrapApp(stage: stage));
  runApp(
    ValueListenableBuilder<Widget>(
      valueListenable: root,
      builder: (_, widget, _) => widget,
    ),
  );

  // 首帧就绪后再显示窗口：用户看到的窗口自带完整启动页内容，绝不白屏
  if (!kIsWeb && Platform.isWindows) {
    try {
      await WidgetsBinding.instance.endOfFrame;
      await windowManager.show();
      await windowManager.focus();
    } catch (e, s) {
      debugPrint('[Main] 窗口显示异常: $e\n$s');
    }
  }

  String? fatalMessage;
  String? diagnostics;
  ProviderContainer? container;

  try {
    // ---------- 1. 加载 Rust 核心（同步桥 + ABI 健康检查） ----------
    stage.value = '正在加载核心组件…';
    await rust.initRustBridge();
    rust.pingCore();
    debugPrint('[Main] Rust 核心已加载并通过健康检查');

    // ---------- 2. 初始化应用（目录解析 + 日志系统；同步桥，毫秒级） ----------
    stage.value = '正在初始化 FMCL 核心…';
    final info = await rust
        .initApp()
        .timeout(const Duration(seconds: 60));
    debugPrint(
      '[Main] FMCL ${info.appVersion} | FMCL 根: ${info.fmclRoot} | '
      '默认游戏目录: ${info.defaultGameDir}',
    );

    // ---------- 3. 启动 Provider 体系并载入设置 ----------
    stage.value = '正在载入设置…';
    container = ProviderContainer();
    try {
      await container
          .read(settingsProvider.notifier)
          .reload()
          .timeout(const Duration(seconds: 60));
    } catch (e, s) {
      // 设置加载失败不致命：Notifier 已有默认值兜底，界面照常可用
      debugPrint('[Main] 设置加载失败（使用默认设置）: $e\n$s');
      _logToRustFile('WARN', 'Main', '设置加载失败（使用默认设置）: $e');
    }

    // ---------- 4. 记忆的窗口尺寸（PCL2 式恢复上次窗口大小） ----------
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

    // ---------- 5. 切换到主界面 ----------
    stage.value = '启动完成';
    root.value = UncontrolledProviderScope(
      container: container,
      child: const FmclApp(),
    );
    try {
      await windowManager.setTitle('FMCL - Fluent Minecraft Launcher');
    } catch (_) {}
  } catch (e, s) {
    fatalMessage = '$e';
    debugPrint('[Main] 启动失败: $e\n$s');
    _logToRustFile('ERROR', 'Main', '启动失败: $e');
    // 自诊断：尽力采集本机环境信息（DLL 是否在位、大小、核心健康状态），
    // 让错误页直接给出可执行的结论而不是泛泛的提示。
    diagnostics = await _selfDiagnose();
    root.value = StartupErrorView(
      title: 'FMCL 核心初始化失败',
      message: fatalMessage,
      diagnostics: diagnostics,
      hint: '全部核心逻辑位于 rust_lib_fmcl.dll，加载失败通常因为：\n'
          '· 杀毒软件（如 Windows Defender / 360）隔离了该 dll —— 请在'
          '隔离区恢复并添加信任；\n'
          '· 压缩包未完整解压或解压后移动了单独文件 —— 请完整解压后再运行；\n'
          '· 缺少 VC++ 运行库 —— 请安装 Microsoft Visual C++ Redistributable。'
          '\n\n详细日志位于启动器目录 FMCL\\logs\\latest.log。',
    );
  }
}

/// 启动失败时的本机自诊断（自身绝不抛错，采集多少算多少）。
Future<String> _selfDiagnose() async {
  final b = StringBuffer();
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dll = File('$exeDir\\rust_lib_fmcl.dll');
    if (dll.existsSync()) {
      final mb = dll.lengthSync() / 1024 / 1024;
      b.writeln('rust_lib_fmcl.dll：存在（${mb.toStringAsFixed(1)} MB）');
    } else {
      b.writeln('rust_lib_fmcl.dll：不存在 —— 压缩包未完整解压或文件被杀毒'
          '软件隔离，请完整解压并在杀毒软件中恢复/信任该文件');
    }
    try {
      rust.pingCore();
      b.writeln('核心健康检查（ping）：通过');
    } catch (e) {
      b.writeln('核心健康检查（ping）：$e');
    }
  } catch (e) {
    b.writeln('诊断过程出错: $e');
  }
  return b.toString();
}

/// 启动期错误可见化页面（release 模式下替代默认的"隐形"ErrorWidget）。
class StartupErrorView extends StatelessWidget {
  final String title;
  final String message;
  final String? stack;
  final String? hint;
  final String? diagnostics;

  const StartupErrorView({
    super.key,
    required this.title,
    required this.message,
    this.stack,
    this.hint,
    this.diagnostics,
  });

  @override
  Widget build(BuildContext context) {
    final stack = this.stack;
    final stackTail = (stack == null || stack.isEmpty)
        ? ''
        : stack.split('\n').take(14).join('\n');
    final hint = this.hint;
    final diagnostics = this.diagnostics;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
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
                if (diagnostics != null && diagnostics.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F7F9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD0D7DE)),
                    ),
                    child: SelectableText(
                      '—— 本机自诊断 ——\n$diagnostics',
                      style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: Color(0xFF3A3F45),
                          fontFamily: 'monospace'),
                    ),
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

/// 启动页（PCL2 风格）：窗口显示的第一眼就是它，替代任何形式的空白窗口。
class _BootstrapApp extends StatelessWidget {
  final ValueNotifier<String> stage;

  const _BootstrapApp({required this.stage});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: Container(
        color: const Color(0xFFF3F5F8),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 草方块标识（与版本图标同源资产）
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/img/hmcl/grass.png',
                  width: 72,
                  height: 72,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'FMCL',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  color: Color(0xFF1F2328),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Fluent Minecraft Launcher',
                style: TextStyle(fontSize: 12, color: Color(0xFF6A737D)),
              ),
              const SizedBox(height: 26),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Color(0xFF3DA039),
                ),
              ),
              const SizedBox(height: 14),
              ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (_, text, _) => Text(
                  text,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF3A3F45)),
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                '首次运行如被杀毒软件拦截，请添加信任',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA4AF)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
