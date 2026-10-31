import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../data/models/game_version.dart';
import '../../data/sources/download_source.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../download/download_manager.dart';

/// 安装进度事件
class InstallProgress {
  /// "resolve" | "download" | "extract" | "process" | "finalize" | "done" | "failed"
  final String phase;
  final String message;
  final double? progress; // 0~1 或 null（不确定）

  const InstallProgress(this.phase, this.message, {this.progress});
}

/// 安装器公共基类。
///
/// `ref` 同时接受 riverpod 的 `Ref`（服务层）与 `WidgetRef`（UI 层），
/// 仅调用其 .read() —— 运行时二者兼容。
abstract class BaseInstaller {
  // ignore: avoid_dynamic_calls
  final dynamic ref;
  final DownloadManager downloadManager;
  final DownloadSource source;

  BaseInstaller(this.ref, this.downloadManager, this.source);

  String get gameDir => ref.read(appSettingsProvider).gameDirectory;

  /// 镜像映射 URL
  String mapUrl(String url) => source.mapUrl(url);

  /// maven 坐标 → 相对路径
  static String mavenToPath(String coord) {
    final segs = coord.split(':');
    if (segs.length < 3) {
      throw ParseException('非法 maven 坐标: $coord');
    }
    final (g, a, v, c, ext) = Library.parseMaven(coord);
    final file = c == null ? '$a-$v.$ext' : '$a-$v-$c.$ext';
    return '${g.replaceAll('.', '/')}/$a/$v/$file';
  }

  /// maven 坐标 → 绝对路径（库目录内）
  static String mavenToAbs(String coord, String librariesDir) =>
      p.join(librariesDir, mavenToPath(coord));

  /// 从 maven 坐标推导 URL
  String mavenUrl(String coord, {String repoBase = ''}) {
    final path = mavenToPath(coord);
    final base = repoBase.isNotEmpty
        ? repoBase
        : (source.kind == DownloadSourceKind.bmclapi
            ? AppConstants.bmclapiLibraries
            : AppConstants.officialLibraries);
    return '$base/$path';
  }

  /// 下载一组文件（走 DownloadManager → Rust 引擎）
  Future<void> downloadTasks(
    List<DownloadTask> tasks,
    void Function(InstallProgress) onProgress,
  ) async {
    if (tasks.isEmpty) return;
    onProgress(InstallProgress('download',
        '下载 ${tasks.length} 个文件...', progress: 0));
    await downloadManager.downloadAll(tasks, onProgress: (state) {
      onProgress(InstallProgress(
        'download',
        '下载中 ${state.finishedFiles}/${state.totalFiles}',
        progress: state.progress,
      ));
    });
    final st = ref.read(downloadStateProvider);
    if (st.phase == DownloadPhase.failed) {
      throw NetworkException('下载失败: ${st.lastError ?? '未知错误'}');
    }
  }

  /// 读取安装器 jar 内的 JSON 条目（经 Rust zip 读取）
  Future<Map<String, dynamic>> readInstallerJson(
    String installerPath,
    String entryName,
  ) async {
    try {
      final bytes = await rust.readZipEntry(
        jarPath: installerPath,
        entryName: entryName,
      );
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on AppException {
      rethrow;
    } catch (e) {
      throw InstallerException('安装器中缺少或损坏 $entryName',
          technicalDetail: e.toString());
    }
  }

  /// 写版本 JSON 到 versions 目录
  Future<String> writeVersionJson(
    String versionId,
    Map<String, dynamic> json,
  ) async {
    final dir = Directory(p.join(gameDir, 'versions', versionId));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(p.join(dir.path, '$versionId.json'));
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    return f.path;
  }

  /// sha1 校验文件（Rust 引擎）
  Future<String> sha1OfFile(String path) =>
      rust.fileSha1(path: path);
}
