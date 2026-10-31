/// FMCL Rust 桥接底层（C-ABI JSON-RPC over dart:ffi）。
///
/// 与 `rust/src/bridge.rs` 一一对应：
/// - `fmcl_set_event_callback`：注册单一事件回调（NativeCallable.listener，
///   任意 Rust 线程触发、自动投递至本 isolate）
/// - `fmcl_init`：启动 tokio 运行时 + 日志转发
/// - `fmcl_call(method, payload)`：异步调用，立即返回调用 id；
///   结果以 `{"type":"response",...}` 回传，过程事件以
///   `{"type":"event",...}` 回传，启动器日志以 `{"type":"app_log",...}` 回传
///
/// 本文件不含任何业务语义；类型化 API 见 `rust_bridge.dart`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Rust 返回 Err 时抛出的异常（message 即 Rust 错误文本）
class FmclBridgeException implements Exception {
  final String message;

  FmclBridgeException(this.message);

  @override
  String toString() => message;
}

/// 底层通信单例
class RustFfi {
  RustFfi._();

  static final RustFfi instance = RustFfi._();

  late final DynamicLibrary _lib;
  late final int Function(Pointer<Char>, Pointer<Char>) _fmclCall;

  /// 调用 id → Future
  final Map<int, Completer<dynamic>> _pending = {};

  /// 调用 id → 事件流控制器（流式方法）
  final Map<int, List<StreamController<dynamic>>> _streams = {};

  /// 启动器实时日志（app_log 事件）
  final StreamController<dynamic> _appLog =
      StreamController<dynamic>.broadcast();

  bool _ready = false;

  /// 是否已成功加载并初始化
  bool get isReady => _ready;

  /// 加载动态库并完成初始化（幂等）。失败抛出异常，由上层决定策略。
  void ensureLoaded() {
    if (_ready) return;

    _lib = _openLibrary();

    // 事件回调（进程生命周期内常驻）
    final setCallback = _lib
        .lookupFunction<
          Void Function(Pointer<NativeFunction<Void Function(Pointer<Char>)>>),
          void Function(Pointer<NativeFunction<Void Function(Pointer<Char>)>>)
        >('fmcl_set_event_callback');
    final callback = NativeCallable<Void Function(Pointer<Char>)>.listener(
      _onEvent,
    );
    setCallback(callback.nativeFunction);

    _lib.lookupFunction<Int32 Function(), int Function()>('fmcl_init')();

    _fmclCall = _lib
        .lookupFunction<
          Int64 Function(Pointer<Char>, Pointer<Char>),
          int Function(Pointer<Char>, Pointer<Char>)
        >('fmcl_call');

    _ready = true;
  }

  DynamicLibrary _openLibrary() {
    // 1) 标准插件布局（cargokit 将动态库放在 exe 同级或插件目录）
    const name = 'rust_lib_fmcl';
    try {
      if (Platform.isWindows) {
        return DynamicLibrary.open('$name.dll');
      }
      if (Platform.isLinux) {
        return DynamicLibrary.open('lib$name.so');
      }
      if (Platform.isMacOS) {
        return DynamicLibrary.open('lib$name.dylib');
      }
    } catch (_) {
      // 继续尝试 exe 同级绝对路径
    }
    // 2) exe 所在目录
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      return DynamicLibrary.open('$exeDir\\$name.dll');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('$exeDir/lib$name.dylib');
    }
    return DynamicLibrary.open('$exeDir/lib$name.so');
  }

  /// 单一事件入口（Rust 任意线程触发）
  void _onEvent(Pointer<Char> ptr) {
    try {
      if (ptr == nullptr) return;
      final text = ptr.cast<Utf8>().toDartString();
      final msg = jsonDecode(text);
      if (msg is! Map<String, dynamic>) return;
      switch (msg['type']) {
        case 'response':
          _onResponse(msg);
        case 'event':
          final id = (msg['id'] as num).toInt();
          final controllers = _streams[id];
          if (controllers != null) {
            for (final c in List.of(controllers)) {
              if (!c.isClosed) c.add(msg['event']);
            }
          }
        case 'app_log':
          _appLog.add(msg['event']);
      }
    } catch (_) {
      // 事件解析失败静默忽略（不得让原生回调抛出）
    }
  }

  void _onResponse(Map<String, dynamic> msg) {
    final id = (msg['id'] as num).toInt();
    final ok = msg['ok'] == true;

    // 1) 普通调用的 Future
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      if (ok) {
        completer.complete(msg['value']);
      } else {
        completer.completeError(
          FmclBridgeException('${msg['error'] ?? '执行失败'}'),
        );
      }
    }
    // 2) 流式调用：response 同时为流的结束边界
    final controllers = _streams.remove(id);
    if (controllers != null) {
      for (final c in controllers) {
        if (c.isClosed) continue;
        if (!ok) {
          c.addError(FmclBridgeException('${msg['error'] ?? '执行失败'}'));
        }
        c.close();
      }
    }
  }

  /// 调用一个方法，返回最终结果（原始 JSON 值）
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) {
    ensureLoaded();
    final methodPtr = method.toNativeUtf8().cast<Char>();
    final payloadPtr = jsonEncode(
      params ?? const {},
    ).toNativeUtf8().cast<Char>();
    final id = _fmclCall(methodPtr, payloadPtr);
    calloc.free(methodPtr);
    calloc.free(payloadPtr);
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    return completer.future;
  }

  /// 调用一个流式方法：返回过程事件流（response 时自动关闭；
  /// Rust 返回 Err 时向流内注入错误后关闭）
  Stream<dynamic> callStream(String method, [Map<String, dynamic>? params]) {
    ensureLoaded();
    late final StreamController<dynamic> controller;
    controller = StreamController<dynamic>(
      onListen: () {
        final methodPtr = method.toNativeUtf8().cast<Char>();
        final payloadPtr = jsonEncode(
          params ?? const {},
        ).toNativeUtf8().cast<Char>();
        final id = _fmclCall(methodPtr, payloadPtr);
        calloc.free(methodPtr);
        calloc.free(payloadPtr);
        _streams.putIfAbsent(id, () => []).add(controller);
      },
      onPause: () {},
      onResume: () {},
      onCancel: () {},
      sync: false,
    );
    return controller.stream;
  }

  /// 启动器实时日志事件流（原始 JSON）
  Stream<dynamic> get appLogEvents => _appLog.stream;
}
