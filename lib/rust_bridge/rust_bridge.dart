/// Rust 桥接统一入口。
///
/// 业务代码不直接 import 生成的 FRB 文件，而是经由本文件，
/// 便于统一初始化与平台隔离（Android 未实现时的桩处理）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../src/rust/frb_generated.dart' show RustLib;

export '../src/rust/api/archive.dart';
export '../src/rust/api/download.dart';
export '../src/rust/api/hash.dart';
export '../src/rust/api/install.dart';
export '../src/rust/api/java.dart';
export '../src/rust/api/java_download.dart';
export '../src/rust/api/process.dart';
export '../src/rust/api/server_ping.dart';
export '../src/rust/api/system.dart';

/// 是否成功初始化了 Rust 运行时
bool _rustReady = false;

/// Rust 后端是否可用
bool get rustBridgeAvailable => _rustReady;

/// 初始化 Rust 运行时。
///
/// Android 平台暂未集成 cargokit 构建产物，捕获异常并降级
/// （TODO(ANDROID)：接入 cargokit 后移除降级逻辑，见 TODO.md #A-02）。
Future<void> initRustBridge() async {
  if (_rustReady) return;
  if (Platform.isAndroid) {
    debugPrint('[RustBridge] Android 平台暂未集成 Rust 构建产物，使用 Dart 降级路径');
    return;
  }
  try {
    await RustLib.init();
    _rustReady = true;
    debugPrint('[RustBridge] Rust 运行时初始化成功');
  } catch (e, s) {
    debugPrint('[RustBridge] Rust 初始化失败（降级为 Dart 实现）: $e\n$s');
  }
}
