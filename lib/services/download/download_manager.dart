import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../providers/settings_provider.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;

/// 下载阶段
enum DownloadPhase { idle, preparing, downloading, done, failed, cancelled }

/// 下载任务聚合状态
class DownloadState {
  final DownloadPhase phase;
  final int totalFiles;
  final int finishedFiles;
  final int failedFiles;
  final int downloadedBytes;
  final int totalBytes;
  final int speedBps;
  final String? lastError;

  const DownloadState({
    this.phase = DownloadPhase.idle,
    this.totalFiles = 0,
    this.finishedFiles = 0,
    this.failedFiles = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBps = 0,
    this.lastError,
  });

  double get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0;

  bool get isBusy =>
      phase == DownloadPhase.preparing || phase == DownloadPhase.downloading;

  DownloadState copyWith({
    DownloadPhase? phase,
    int? totalFiles,
    int? finishedFiles,
    int? failedFiles,
    int? downloadedBytes,
    int? totalBytes,
    int? speedBps,
    String? lastError,
  }) {
    return DownloadState(
      phase: phase ?? this.phase,
      totalFiles: totalFiles ?? this.totalFiles,
      finishedFiles: finishedFiles ?? this.finishedFiles,
      failedFiles: failedFiles ?? this.failedFiles,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBps: speedBps ?? this.speedBps,
      lastError: lastError ?? this.lastError,
    );
  }
}

/// 单条待下载文件描述
class DownloadTask {
  final String url;
  final String savePath;
  final String? sha1;
  final int? size;

  /// 备用下载地址（Rust 引擎逐个回退）
  final List<String> altUrls;

  const DownloadTask({
    required this.url,
    required this.savePath,
    this.sha1,
    this.size,
    this.altUrls = const [],
  });
}

/// 下载管理器。
///
/// - 优先走 Rust 并发下载引擎（可用时）
/// - Android / Rust 初始化失败时降级为 Dart 串行下载（dio）
class DownloadManager {
  DownloadManager(this._ref);

  final Ref _ref;
  String? _sessionId;
  StreamSubscription<rust.DownloadProgressEvent>? _sub;

  AppSettings get _settings => _ref.read(appSettingsProvider);

  /// 批量下载（取消上一个未完成任务）
  Future<void> downloadAll(
    List<DownloadTask> tasks, {
    void Function(DownloadState state)? onProgress,
  }) async {
    if (tasks.isEmpty) return;
    await cancel();

    final notifier = _ref.read(downloadStateProvider.notifier);
    notifier.set(DownloadState(
      phase: DownloadPhase.preparing,
      totalFiles: tasks.length,
      totalBytes: tasks.fold(0, (s, t) => s + (t.size ?? 0)),
    ));

    if (rust.rustBridgeAvailable) {
      await _downloadWithRust(tasks, onProgress);
    } else {
      await _downloadWithDart(tasks, onProgress);
    }
  }

  Future<void> _downloadWithRust(
    List<DownloadTask> tasks,
    void Function(DownloadState)? onProgress,
  ) async {
    final completer = Completer<void>();
    final sessionId = await rust.createDownloadSession();
    _sessionId = sessionId;

    final items = tasks
        .map((t) => rust.DownloadItem(
              url: t.url,
              savePath: t.savePath,
              expectedSha1: _settings.verifyFiles ? t.sha1 : null,
              expectedSize: t.size == 0 ? null : t.size,
              altUrls: t.altUrls,
            ))
        .toList();

    final stream = rust.downloadBatch(
      items: items,
      concurrency: _settings.concurrency,
      sessionId: sessionId,
      userAgent: AppConstants.userAgent,
    );

    _sub = stream.listen(
      (event) {
        final notifier = _ref.read(downloadStateProvider.notifier);
        switch (event.kind) {
          case 'file_done':
          case 'progress':
            notifier.patchState((s) => s.copyWith(
              phase: DownloadPhase.downloading,
              finishedFiles: event.finishedFiles,
              failedFiles: event.failedFiles,
              downloadedBytes: event.downloadedBytes,
              totalBytes: event.totalBytes,
              speedBps: event.speedBps,
            ));
            onProgress?.call(_ref.read(downloadStateProvider));
          case 'file_failed':
            AppLogger.warn(
                'Download', '文件失败 ${event.currentFile}: ${event.errorMessage}');
            notifier.patchState((s) => s.copyWith(
              phase: DownloadPhase.downloading,
              finishedFiles: event.finishedFiles,
              failedFiles: event.failedFiles,
              downloadedBytes: event.downloadedBytes,
              totalBytes: event.totalBytes,
              speedBps: event.speedBps,
              lastError: event.errorMessage,
            ));
            onProgress?.call(_ref.read(downloadStateProvider));
          case 'cancelled':
            notifier.patchState((s) => s.copyWith(phase: DownloadPhase.cancelled));
            if (!completer.isCompleted) completer.complete();
          case 'done':
            final st = _ref.read(downloadStateProvider);
            if (st.failedFiles > 0) {
              notifier.patchState((s) => s.copyWith(
                phase: DownloadPhase.failed,
                lastError: '${st.failedFiles} 个文件下载失败',
              ));
            } else {
              notifier.patchState((s) => s.copyWith(phase: DownloadPhase.done));
            }
            if (!completer.isCompleted) completer.complete();
        }
      },
      onError: (Object e) {
        AppLogger.error('Download', 'Rust 下载引擎异常', e);
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
    } finally {
      await _sub?.cancel();
      _sub = null;
      await rust.disposeDownloadSession(sessionId: sessionId);
      _sessionId = null;
    }
  }

  /// Dart 降级下载（Android 等）：dio 简单并发
  Future<void> _downloadWithDart(
    List<DownloadTask> tasks,
    void Function(DownloadState)? onProgress,
  ) async {
    final notifier = _ref.read(downloadStateProvider.notifier);
    var finished = 0;
    var failed = 0;
    var downloaded = 0;
    final total = tasks.fold<int>(0, (s, t) => s + (t.size ?? 0));
    final errors = <String>[];

    notifier.patchState((s) => s.copyWith(phase: DownloadPhase.downloading));

    for (final task in tasks) {
      try {
        final file = File(task.savePath);
        if (file.existsSync() && task.size != null && file.lengthSync() == task.size) {
          finished++;
          continue;
        }
        await Directory(p.dirname(task.savePath)).create(recursive: true);
        // Android 桩实现：使用内置 HTTP 客户端直接下载
        // TODO(ANDROID)：接入 Rust 引擎后移除此路径，见 TODO.md #A-03
        final resp = await HttpFallback.client.getBytes(task.url);
        if (resp.statusCode != 200) {
          throw NetworkException('HTTP ${resp.statusCode}');
        }
        final bytes = resp.data;
        await file.writeAsBytes(bytes, flush: true);
        downloaded += bytes.length;
        finished++;
        notifier.patchState((s) => s.copyWith(
          finishedFiles: finished,
          downloadedBytes: downloaded,
          totalBytes: total,
        ));
        onProgress?.call(_ref.read(downloadStateProvider));
      } catch (e) {
        failed++;
        errors.add('${task.url}: $e');
        AppLogger.warn('Download', '降级下载失败: $e');
      }
    }

    notifier.patchState((s) => s.copyWith(
      phase: failed > 0 ? DownloadPhase.failed : DownloadPhase.done,
      failedFiles: failed,
      finishedFiles: finished,
      lastError: errors.isEmpty ? null : errors.first,
    ));
    onProgress?.call(_ref.read(downloadStateProvider));
  }

  /// 取消当前下载
  Future<void> cancel() async {
    final id = _sessionId;
    if (id != null) {
      rust.cancelDownload(sessionId: id);
    }
    await _sub?.cancel();
    _sub = null;
    _ref.read(downloadStateProvider.notifier).set(
        _ref.read(downloadStateProvider).copyWith(phase: DownloadPhase.cancelled));
  }
}

/// Android 降级路径使用的极简 HTTP 客户端（独立于 HttpService 避免循环依赖）
class HttpFallback {
  static final _FallbackDio client = _FallbackDio();
}

class _FallbackDio {
  Future<_FallbackResponse> getBytes(String url) async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      return _FallbackResponse(resp.statusCode, bytes);
    } finally {
      client.close(force: true);
    }
  }
}

class _FallbackResponse {
  final int statusCode;
  final List<int> data;
  const _FallbackResponse(this.statusCode, this.data);
}
