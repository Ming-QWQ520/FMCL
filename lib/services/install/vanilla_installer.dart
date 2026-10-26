import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../data/models/game_version.dart';
import '../../services/version/version_repository.dart';
import '../download/download_manager.dart';
import '../download/http_service.dart';
import 'installer_base.dart';

/// 原版（Vanilla）安装器：下载版本 JSON + 客户端 jar。
class VanillaInstaller extends BaseInstaller {
  VanillaInstaller(super.ref, super.downloadManager, super.source);

  /// 安装原版版本；返回版本 id
  Future<String> install(
    String versionId, {
    required void Function(InstallProgress) onProgress,
  }) async {
    onProgress(const InstallProgress('resolve', '解析版本清单...'));

    // 获取版本 JSON
    final manifest = await VersionRepository.I.fetchManifest();
    final entries = (manifest['versions'] as List<dynamic>? ?? []);
    final entry = entries.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == versionId,
          orElse: () => null,
        );
    if (entry == null) {
      throw ParseException('版本清单中不存在: $versionId');
    }

    final jsonUrl = entry['url'] as String;
    onProgress(InstallProgress('download', '下载版本定义 $versionId...'));
    final json = await HttpService.I.getJsonWithFallback(
      jsonUrl,
      mapThroughSource: true,
    ) as Map<String, dynamic>;

    final version = GameVersionJson.fromJson(json);

    // 下载客户端 jar
    final clientRef = version.downloads?.client;
    if (clientRef == null) {
      throw InstallerException('版本 $versionId 缺少客户端下载定义');
    }
    final jarPath = p.join(gameDir, 'versions', versionId, '$versionId.jar');
    await downloadTasks([
      DownloadTask(
        url: mapUrl(clientRef.url),
        savePath: jarPath,
        sha1: clientRef.sha1,
        size: clientRef.size,
      ),
    ], onProgress);

    // 写版本 JSON（URL 已按源映射的不写死，保留官方 url，由启动时动态映射）
    await writeVersionJson(versionId, json);
    onProgress(InstallProgress('done', '原版 $versionId 安装完成'));
    return versionId;
  }
}
