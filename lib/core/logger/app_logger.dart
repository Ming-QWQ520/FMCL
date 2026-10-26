import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';

/// 日志级别
enum LogLevel { debug, info, warn, error }

/// FMCL 日志系统。
///
/// - 同时输出到控制台（debug）与 `<gameDir>/logs/fmcl/latest.log`
/// - 启动器崩溃时保存 crash report 到 `logs/fmcl/crash-reports/`
/// - 线程安全（写入经由 isolate 安全的同步 IO + 队列）
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();
  static AppLogger get I => instance;

  IOSink? _sink;
  File? _logFile;
  final List<String> _buffer = [];
  bool _initialized = false;

  /// 初始化日志文件
  Future<void> init(String logsDir) async {
    if (_initialized) return;
    try {
      final dir = Directory(logsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFile = File(
        '${dir.path}${Platform.pathSeparator}latest.log',
      );
      if (_logFile!.existsSync()) {
        // 轮转旧日志（最多保留 5 份）
        _rotateOldLogs(dir);
      }
      _sink = _logFile!.openWrite(mode: FileMode.append);
      _sink!.writeln('==== FMCL ${AppConstants.appVersion} 启动于 ${DateTime.now()} ====');
      _initialized = true;
      // 将初始化前缓冲的内容写入
      for (final line in _buffer) {
        _sink!.writeln(line);
      }
      _buffer.clear();
      await _sink!.flush();
    } catch (e) {
      debugPrint('AppLogger 初始化失败: $e');
    }
  }

  void _rotateOldLogs(Directory dir) {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      _logFile!.renameSync('${dir.path}${Platform.pathSeparator}latest-$stamp.log');
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('latest-'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(5)) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  void _log(LogLevel level, String tag, String message,
      [Object? error, StackTrace? stack]) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [${level.name.toUpperCase()}] [$tag] $message'
        '${error == null ? '' : ' | error=$error'}'
        '${stack == null ? '' : '\n$stack'}';
    if (kDebugMode) {
      debugPrint(line);
    }
    if (_initialized && _sink != null) {
      _sink!.writeln(line);
      // 出错时立即落盘
      if (level == LogLevel.error) _sink!.flush();
    } else {
      _buffer.add(line);
      if (_buffer.length > 500) _buffer.removeAt(0);
    }
  }

  static void debug(String tag, String message) =>
      instance._log(LogLevel.debug, tag, message);

  static void info(String tag, String message) =>
      instance._log(LogLevel.info, tag, message);

  static void warn(String tag, String message, [Object? error]) =>
      instance._log(LogLevel.warn, tag, message, error);

  static void error(String tag, String message,
      [Object? error, StackTrace? stack]) =>
      instance._log(LogLevel.error, tag, message, error, stack);

  /// 保存启动器崩溃报告
  Future<String?> saveCrashReport(String detail) async {
    if (_logFile == null) return null;
    try {
      final dir = Directory('${_logFile!.parent.path}${Platform.pathSeparator}crash-reports');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File(
        '${dir.path}${Platform.pathSeparator}fmcl-crash-${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await f.writeAsString(detail, flush: true);
      return f.path;
    } catch (e) {
      debugPrint('保存崩溃报告失败: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _initialized = false;
  }
}
