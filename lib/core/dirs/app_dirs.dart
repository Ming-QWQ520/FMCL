import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logger/app_logger.dart';

/// FMCL 便携目录系统（对齐 PCL2 的便携模式）。
///
/// Windows / Linux 下所有启动器数据固定在 **exe 所在目录\FMCL\** 下：
/// ```
/// <exeDir>/
///  ├─ FMCL/
///  │   ├─ logs/                       启动器完整日志（latest.log + 轮转）
///  │   │   ├─ game/                   每次游戏启动的完整输出镜像
///  │   │   └─ crash-reports/          启动器崩溃报告
///  │   ├─ lib/authlib-injector/       外置登录 authlib-injector.jar
///  │   ├─ cache/                      启动器缓存（版本清单等）
///  │   └─ java/                       自动安装的 Java 运行时
///  └─ .minecraft/                     游戏目录（便携）
/// ```
/// exe 目录不可写（如 Program Files）时自动回退到系统应用目录。
class AppDirs {
  AppDirs._();

  static String? _fmclRoot;
  static bool _resolved = false;

  /// 可执行文件所在目录（桌面端）。
  static String get exeDir {
    if (Platform.isAndroid || kIsWeb) return '';
    return p.dirname(Platform.resolvedExecutable);
  }

  /// 目录是否可写（探测文件法）。
  static bool isWritable(String dir) {
    try {
      final probe = File(p.join(dir, '.fmcl_write_probe'));
      probe.writeAsStringSync('ok', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// FMCL 数据根目录：优先 `<exeDir>/FMCL`，不可写回退系统目录。
  static String get fmclRoot {
    if (_resolved && _fmclRoot != null) return _fmclRoot!;
    String root;
    if (Platform.isAndroid || kIsWeb) {
      root = ''; // Android 在 init() 中异步确定
    } else {
      final base = exeDir;
      final candidate = p.join(base, 'FMCL');
      try {
        Directory(candidate).createSync(recursive: true);
        if (isWritable(base)) {
          root = candidate;
        } else {
          root = '';
          AppLogger.warn('Dirs', 'exe 目录不可写: $base，FMCL 数据将回退到系统目录');
        }
      } catch (e) {
        root = '';
        AppLogger.warn('Dirs', '创建 FMCL 目录失败: $e');
      }
    }
    if (root.isEmpty) {
      // 同步兜底：临时目录（init() 中会用系统支持目录覆盖）
      root = p.join(Directory.systemTemp.path, 'fmcl', 'FMCL');
    }
    _fmclRoot = root;
    _resolved = true;
    AppLogger.info('Dirs', 'FMCL 数据目录: $root');
    return root;
  }

  /// 异步初始化（应用启动时调用一次，处理 Android 与回退路径）。
  static Future<void> init() async {
    if (Platform.isAndroid || kIsWeb) {
      final support = await getApplicationSupportDirectory();
      _fmclRoot = p.join(support.path, 'FMCL');
      _resolved = true;
      return;
    }
    // 触发同步解析
    final root = fmclRoot;
    // 若同步解析回退到了临时目录，尝试用系统支持目录替代
    if (root.startsWith(Directory.systemTemp.path)) {
      try {
        final support = await getApplicationSupportDirectory();
        final candidate = p.join(support.path, 'FMCL');
        Directory(candidate).createSync(recursive: true);
        if (isWritable(support.path)) _fmclRoot = candidate;
      } catch (_) {}
    }
    AppLogger.info('Dirs', 'FMCL 数据目录(最终): $_fmclRoot');
  }

  /// 启动器完整日志目录：`<exeDir>\FMCL\logs`
  static String get logsDir => p.join(fmclRoot, 'logs');

  /// 游戏输出镜像目录：`<exeDir>\FMCL\logs\game`
  static String get gameLogsDir => p.join(logsDir, 'game');

  /// 启动器崩溃报告目录
  static String get crashReportsDir => p.join(logsDir, 'crash-reports');

  /// 启动器库目录：`<exeDir>\FMCL\lib`
  static String get libDir => p.join(fmclRoot, 'lib');

  /// authlib-injector 目录：`<exeDir>\FMCL\lib\authlib-injector`
  static String get authlibInjectorDir => p.join(libDir, 'authlib-injector');

  /// authlib-injector jar 完整路径
  static String get authlibInjectorJar =>
      p.join(authlibInjectorDir, 'authlib-injector.jar');

  /// 缓存目录：`<exeDir>\FMCL\cache`
  static String get cacheDir => p.join(fmclRoot, 'cache');

  /// 自动安装 Java 目录：`<exeDir>\FMCL\java`
  static String get javaDir => p.join(fmclRoot, 'java');

  /// 确保核心子目录存在。
  static void ensureCore() {
    for (final d in [
      logsDir,
      gameLogsDir,
      crashReportsDir,
      authlibInjectorDir,
      cacheDir,
    ]) {
      try {
        Directory(d).createSync(recursive: true);
      } catch (e) {
        AppLogger.warn('Dirs', '创建目录失败 $d: $e');
      }
    }
  }
}
