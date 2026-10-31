/// Rust 桥接统一入口。
///
/// 全部业务逻辑在 Rust 侧；Dart 仅通过本文件访问生成绑定。
/// 业务代码不直接 import 生成的 FRB 文件，而是经由本文件统一导出。
library;

import 'package:flutter/foundation.dart';

import '../src/rust/frb_generated.dart' show RustLib;

export '../src/rust/api/app.dart';
export '../src/rust/api/archive.dart';
export '../src/rust/api/auth_api.dart';
export '../src/rust/api/content_api.dart';
export '../src/rust/api/download.dart';
export '../src/rust/api/hash.dart';
export '../src/rust/api/install.dart';
export '../src/rust/api/java.dart';
export '../src/rust/api/java_api.dart';
export '../src/rust/api/java_download.dart';
export '../src/rust/api/launch_api.dart';
export '../src/rust/api/manifest_api.dart';
export '../src/rust/api/process.dart';
export '../src/rust/api/server_ping.dart';
export '../src/rust/api/settings_api.dart';
export '../src/rust/api/system.dart';
export '../src/rust/api/versions_api.dart';

/// 是否成功初始化了 Rust 运行时
bool _rustReady = false;

/// Rust 后端是否可用
bool get rustBridgeAvailable => _rustReady;

/// 初始化 Rust 运行时（幂等）。失败时抛出，由调用方决定退出策略。
Future<void> initRustBridge() async {
  if (_rustReady) return;
  await RustLib.init();
  _rustReady = true;
  debugPrint('[RustBridge] Rust 运行时初始化成功');
}
