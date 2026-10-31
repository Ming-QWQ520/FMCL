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
  late final int Function(Pointer<Char>, Pointer<Char>, Pointer<Char>, int)
  _fmclCallSync;
  late final int Function() _fmclPing;
  late final void Function(Pointer<Char>) _fmclFree;

  /// 事件回调（进程生命周期内常驻持有！）。
  ///
  /// 绝不能让本对象变成不可达：NativeCallable 一旦被 GC 回收，原生侧
  /// 持有的函数指针随即失效，此后所有 Rust → Dart 响应都静默丢失，
  /// 表现为一切调用永久挂起（启动/下载/启动游戏全部无响应）。
  NativeCallable<Void Function(Pointer<Char>)>? _callback;

  /// 释放 Rust 侧事件缓冲区（emit_event 用 into_raw 移交所有权，
  /// Dart 读完后必须归还，否则内存泄漏）。
  ///
  /// 配套修复 use-after-free：Rust 侧绝不能在回调返回后立即释放，
  /// 否则 Dart 稍后读取时内存已被回收 —— JSON 解析失败被静默吞掉，
  /// 表现为所有异步响应随机丢失（登录卡住/下载转圈/关窗无反应）。
  void _freeEventBuffer(Pointer<Char> ptr) {
    try {
      if (ptr != nullptr) _fmclFree(ptr);
    } catch (_) {}
  }

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

  /// 桥接 ABI 版本（与 rust/src/bridge.rs 的 FMCL_ABI_VERSION 严格一致，
  /// 两侧同时发布；不一致说明 DLL 与程序版本不配套）
  ///
  /// v2：事件内存所有权变更（emit_event into_raw 移交 + fmcl_free 归还，
  /// 修复 v1 的 use-after-free 导致异步响应随机丢失）。
  static const int abiVersion = 2;

  /// fmcl_ping 魔法数高 32 位（"FMCL" 的 ASCII）
  static const int _pingMagic = 0x464D434C;

  /// 加载动态库并完成初始化（幂等）。失败抛出异常，由上层决定策略。
  void ensureLoaded() {
    if (_ready) return;

    _lib = _openLibrary();

    // 健康检查：确认这是配套 ABI 版本的 DLL（旧版/半解压/被篡改的
    // DLL 会在后续产生难以理解的静默故障，这里直接给出明确诊断）
    _fmclPing = _lib
        .lookupFunction<Int64 Function(), int Function()>('fmcl_ping');
    final ping = _fmclPing();
    if (ping >> 32 != _pingMagic || (ping & 0xFFFFFFFF) != abiVersion) {
      throw StateError(
        'rust_lib_fmcl.dll 与程序版本不配套（ping=0x${ping.toRadixString(16)}，'
        '期望 ABI=$abiVersion）。请删除后重新完整解压压缩包再运行。',
      );
    }

    // 事件回调（进程生命周期内常驻，存入字段防止 GC 回收 —— 见字段注释）
    final setCallback = _lib
        .lookupFunction<
          Void Function(Pointer<NativeFunction<Void Function(Pointer<Char>)>>),
          void Function(Pointer<NativeFunction<Void Function(Pointer<Char>)>>)
        >('fmcl_set_event_callback');
    _callback = NativeCallable<Void Function(Pointer<Char>)>.listener(
      _onEvent,
    );
    setCallback(_callback!.nativeFunction);

    _lib.lookupFunction<Int32 Function(), int Function()>('fmcl_init')();

    _fmclCall = _lib
        .lookupFunction<
          Int64 Function(Pointer<Char>, Pointer<Char>),
          int Function(Pointer<Char>, Pointer<Char>)
        >('fmcl_call');

    _fmclCallSync = _lib
        .lookupFunction<
          Int64 Function(Pointer<Char>, Pointer<Char>, Pointer<Char>, Size),
          int Function(Pointer<Char>, Pointer<Char>, Pointer<Char>, int)
        >('fmcl_call_sync');

    _fmclFree = _lib
        .lookupFunction<
          Void Function(Pointer<Char>),
          void Function(Pointer<Char>)
        >('fmcl_free');

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

  /// 同步健康检查（不依赖回调管线）。DLL 未加载或版本不配套时抛出异常。
  void ping() {
    ensureLoaded();
    final p = _fmclPing();
    if (p >> 32 != _pingMagic || (p & 0xFFFFFFFF) != abiVersion) {
      throw StateError('核心健康检查失败（ping=0x${p.toRadixString(16)}）');
    }
  }

  /// 同步调用一个方法（仅供启动关键路径使用）。
  ///
  /// 在调用线程上直接执行并返回响应 value 部分，不经过事件回调管线 ——
  /// 即使回调投递链路异常，启动也能完成。仅限本地快速方法
  /// （init_app / get_settings 等毫秒级调用），严禁用于网络/长耗时任务。
  dynamic callSync(String method, [Map<String, dynamic>? params]) {
    ensureLoaded();
    final methodPtr = method.toNativeUtf8().cast<Char>();
    final payloadPtr = jsonEncode(
      params ?? const {},
    ).toNativeUtf8().cast<Char>();
    Pointer<Char> buf = calloc<Char>(64 * 1024);
    try {
      var r = _fmclCallSync(methodPtr, payloadPtr, buf, 64 * 1024);
      if (r > 0) {
        // 缓冲不足：按所需大小重试一次（附上限保护，防止异常返回值）
        if (r > 16 * 1024 * 1024) {
          throw FmclBridgeException('同步调用 $method 返回异常大小（$r）');
        }
        calloc.free(buf);
        buf = calloc<Char>(r);
        r = _fmclCallSync(methodPtr, payloadPtr, buf, r);
      }
      if (r != 0) {
        throw FmclBridgeException('同步调用 $method 失败（code=$r）');
      }
      final text = buf.cast<Utf8>().toDartString();
      final dynamic msg = jsonDecode(text);
      if (msg is! Map<String, dynamic>) {
        throw FmclBridgeException('同步调用 $method 响应格式异常');
      }
      if (msg['ok'] != true) {
        throw FmclBridgeException('${msg['error'] ?? '执行失败'}');
      }
      return msg['value'];
    } finally {
      calloc.free(buf);
      calloc.free(methodPtr);
      calloc.free(payloadPtr);
    }
  }

  /// 单一事件入口（Rust 任意线程触发）。
  ///
  /// 指针指向的缓冲区由 Rust 侧移交所有权（into_raw），读取后必须
  /// 经 fmcl_free 归还 —— 无论处理成功与否都在 finally 中释放。
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
    } finally {
      _freeEventBuffer(ptr);
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

  /// 调用一个方法，返回最终结果（原始 JSON 值）。
  ///
  /// 兜底超时 5 分钟：即使 Rust 侧响应意外丢失（回调异常等），
  /// 也不让调用方永久挂起（正常业务流均有自身的超时与重试）。
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
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _pending.remove(id);
        throw FmclBridgeException('调用超时: $method（Rust 后端无响应）');
      },
    );
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
