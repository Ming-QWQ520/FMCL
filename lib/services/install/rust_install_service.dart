import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/sources/download_source.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../java/java_service.dart';
import 'installer_base.dart';

/// Rust 合并安装管线（PCL2 式体验对齐）的 Dart 薄封装。
///
/// 所有重活（下载 / 解析 / 处理器链 / 版本合并 / 补全扫描）都在 Rust 完成，
/// 本层仅负责：
/// - 组装 [rust.InstallRequest]（读取全局设置映射下载源 / 并发数）
/// - 预解析处理器链所需 Java（复用 JavaService 自动安装）
/// - 把 Rust 进度事件流转译为 [InstallProgress]
class RustInstallService {
  RustInstallService(this._ref, {required this.params});

  // ignore: avoid_dynamic_calls
  final dynamic _ref;

  /// 请求参数
  final RustInstallParams params;

  /// 执行安装，返回最终版本 id。
  Future<String> install({
    required void Function(InstallProgress) onProgress,
  }) async {
    final settings = _ref.read(appSettingsProvider);

    // 下载源映射
    final useBmclapi = (settings.downloadSourceIndex == 0);

    // 处理器链 Java：优先用户指定，否则自动选择（允许自动安装）
    String javaPath = settings.javaPath;
    if (javaPath.isEmpty) {
      try {
        final java = await _ref.read(javaServiceProvider).pickJava(
              params.requiredJavaMajor ?? 8,
              autoInstall: settings.autoInstallJava,
            );
        javaPath = java.javaPath;
        AppLogger.info('Install', '处理器链 Java: ${java.versionString}');
      } catch (e) {
        AppLogger.warn('Install', '自动选择 Java 失败（处理器链将尝试 PATH）: $e');
      }
    }

    final sessionId = await rust.createDownloadSession();

    final request = rust.InstallRequest(
      gameDir: settings.gameDirectory,
      instanceName: params.instanceName,
      gameVersion: params.gameVersion,
      versionJsonUrl: params.versionJsonUrl,
      fabricVersion: params.fabricVersion,
      quiltVersion: params.quiltVersion,
      forgeVersion: params.forgeVersion,
      neoforgeVersion: params.neoforgeVersion,
      optifine: params.optifine == null
          ? null
          : rust.OptiFineEntry(
              inherit: params.optifine!.inherit,
              displayName: params.optifine!.displayName,
              fileName: params.optifine!.fileName,
              isPreview: params.optifine!.isPreview,
            ),
      javaPath: javaPath,
      useBmclapi: useBmclapi,
      concurrency: settings.concurrency,
      sessionId: sessionId,
    );

    final completer = Completer<String>();
    final sub = rust.installCombined(request: request).listen(
      (event) {
        onProgress(InstallProgress(event.phase, event.message,
            progress: event.progress));
        if (event.phase == 'done') {
          if (!completer.isCompleted) completer.complete(params.instanceName);
        } else if (event.phase == 'failed') {
          if (!completer.isCompleted) {
            completer.completeError(InstallerException(event.message));
          }
        } else if (event.phase == 'cancelled') {
          if (!completer.isCompleted) {
            completer.completeError(const InstallerException('安装已取消'));
          }
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(
              e is AppException ? e : InstallerException('安装失败: $e'));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(params.instanceName);
        }
      },
      cancelOnError: true,
    );
    _activeSubscriptions[sessionId] = sub;

    try {
      return await completer.future;
    } finally {
      _activeSubscriptions.remove(sessionId);
      await sub.cancel();
      // 释放会话句柄（失败/取消时 Rust 端可能仍持有）
      rust.disposeDownloadSession(sessionId: sessionId);
    }
  }

  static final Map<String, StreamSubscription<dynamic>> _activeSubscriptions = {};

  /// 取消最近的安装会话
  static void cancelLast() {
    for (final id in _activeSubscriptions.keys.toList()) {
      rust.cancelDownload(sessionId: id);
    }
  }
}

/// Rust 安装参数（加载器与 OptiFine 条目可任意组合）
class RustInstallParams {
  final String gameVersion;
  final String instanceName;
  final String? versionJsonUrl;
  final String? fabricVersion;
  final String? quiltVersion;
  final String? forgeVersion;
  final String? neoforgeVersion;

  /// 高清修复（OptiFine），按模组 / Tweaker 方式处理由 Rust 决策
  final SimpleOptiFine? optifine;

  /// 处理器链 Java 主版本提示（None → 8）
  final int? requiredJavaMajor;

  const RustInstallParams({
    required this.gameVersion,
    required this.instanceName,
    this.versionJsonUrl,
    this.fabricVersion,
    this.quiltVersion,
    this.forgeVersion,
    this.neoforgeVersion,
    this.optifine,
    this.requiredJavaMajor,
  });
}

/// 简化的 OptiFine 条目（避免 Dart 层直接依赖 rust 类型）
class SimpleOptiFine {
  final String inherit;
  final String displayName;
  final String fileName;
  final bool isPreview;

  const SimpleOptiFine({
    required this.inherit,
    required this.displayName,
    required this.fileName,
    required this.isPreview,
  });
}

/// 服务 provider
final rustInstallServiceProvider = Provider<RustInstallServiceFactory>((ref) {
  return RustInstallServiceFactory(ref);
});

/// 工厂：每次安装创建独立服务实例
class RustInstallServiceFactory {
  final Ref ref;

  const RustInstallServiceFactory(this.ref);

  RustInstallService create(RustInstallParams params) =>
      RustInstallService(ref, params: params);
}

/// 下载源便捷引用（保持与其它安装器一致的行为）
final downloadSourceForInstallProvider = Provider<DownloadSource>((ref) {
  final idx = ref.watch(appSettingsProvider).downloadSourceIndex;
  return DownloadSources.of(
      idx == 1 ? DownloadSourceKind.official : DownloadSourceKind.bmclapi);
});

