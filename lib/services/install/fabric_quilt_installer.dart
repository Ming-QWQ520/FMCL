import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/game_version.dart';
import '../../data/sources/download_source.dart';
import '../../services/version/version_repository.dart';
import '../download/download_manager.dart';
import '../download/http_service.dart';
import 'installer_base.dart';

/// Fabric / Quilt 安装器（两者 Meta API 结构一致，仅服务地址不同）。
///
/// 流程：
/// 1. 从 Meta 获取 loader 版本列表
/// 2. 下载 profile JSON（Meta 生成的完整版本定义，含 inheritsFrom）
/// 3. 下载 profile 声明的所有库
/// 4. 落盘版本 JSON
class FabricQuiltInstaller extends BaseInstaller {
  final bool isQuilt;

  FabricQuiltInstaller(
    super.ref,
    super.downloadManager,
    super.source, {
    this.isQuilt = false,
  });

  String get _metaBase => isQuilt ? AppConstants.quiltMeta : AppConstants.fabricMeta;
  String get loaderName => isQuilt ? 'Quilt' : 'Fabric';

  /// 获取可用的 loader 版本列表（稳定版在前）
  Future<List<String>> fetchLoaderVersions(String gameVersion) async {
    final url = '$_metaBase/versions/loader/$gameVersion';
    final data = await HttpService.I.getJsonWithFallback(url);
    final list = (data as List<dynamic>)
        .map((e) => ((e as Map<String, dynamic>)['loader']
            as Map<String, dynamic>)['version'] as String)
        .toList();
    return list;
  }

  /// 安装：返回最终版本 id（如 fmcl-fabric-1.20.1-0.15.11）
  Future<String> install({
    required String gameVersion,
    required String loaderVersion,
    required void Function(InstallProgress) onProgress,
    String? customVersionId,
  }) async {
    // 1. 确保原版已安装（下载原版 JSON + jar）
    onProgress(InstallProgress('resolve', '准备 Minecraft $gameVersion 基础文件...'));
    await _ensureVanillaBase(gameVersion, onProgress);

    // 2. 获取 profile JSON
    final profileUrl = '$_metaBase/versions/loader/'
        '$gameVersion/$loaderVersion/profile/json';
    final profile = await HttpService.I.getJsonWithFallback(profileUrl)
        as Map<String, dynamic>;

    final versionId = customVersionId ??
        await _uniqueId('fmcl-${isQuilt ? 'quilt' : 'fabric'}-'
            '$gameVersion-$loaderVersion');

    // 3. 收集库下载任务
    final libs = (profile['libraries'] as List<dynamic>? ?? [])
        .map((e) => Library.fromJson(e as Map<String, dynamic>))
        .toList();
    final librariesDir = p.join(gameDir, 'libraries');
    final tasks = <DownloadTask>[];
    for (final lib in libs) {
      final artifact = lib.downloads?.artifact;
      if (artifact != null && artifact.url.isNotEmpty) {
        tasks.add(DownloadTask(
          url: mapUrl(artifact.url),
          savePath: p.join(librariesDir, artifact.path ?? lib.path),
          sha1: artifact.sha1,
          size: artifact.size,
        ));
      } else {
        // 无 downloads 键：按 maven 布局拼接（url 字段或默认库根）
        final base = lib.url ?? (source.kind == DownloadSourceKind.bmclapi
            ? AppConstants.bmclapiLibraries
            : AppConstants.officialLibraries);
        tasks.add(DownloadTask(
          url: mapUrl('$base/${lib.path}'),
          savePath: p.join(librariesDir, lib.path),
        ));
      }
    }
    await downloadTasks(tasks, onProgress);

    // 4. 落盘
    profile['id'] = versionId;
    await writeVersionJson(versionId, profile);
    AppLogger.info('Install', '$loaderName $loaderVersion 安装完成 → $versionId');
    onProgress(InstallProgress('done', '$loaderName 安装完成'));
    return versionId;
  }

  /// 确保原版 JSON + 客户端 jar 存在（不落盘独立的原版版本条目）
  Future<void> _ensureVanillaBase(
    String gameVersion,
    void Function(InstallProgress) onProgress,
  ) async {
    final jsonFile = File(p.join(gameDir, 'versions', gameVersion, '$gameVersion.json'));
    final jarFile = File(p.join(gameDir, 'versions', gameVersion, '$gameVersion.jar'));

    Map<String, dynamic> json;
    if (jsonFile.existsSync()) {
      json = jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
    } else {
      final manifest = await VersionRepository.I.fetchManifest();
      final entry = (manifest['versions'] as List? ?? [])
          .cast<Map<String, dynamic>?>()
          .firstWhere((e) => e?['id'] == gameVersion, orElse: () => null);
      if (entry == null) {
        throw ParseException('版本清单中不存在: $gameVersion');
      }
      json = await HttpService.I.getJsonWithFallback(
        entry['url'] as String,
        mapThroughSource: true,
      );
      if (!Directory(p.dirname(jsonFile.path)).existsSync()) {
        Directory(p.dirname(jsonFile.path)).createSync(recursive: true);
      }
      await jsonFile.writeAsString(jsonEncode(json));
    }

    if (!jarFile.existsSync()) {
      final version = GameVersionJson.fromJson(json);
      final clientRef = version.downloads?.client;
      if (clientRef == null) {
        throw InstallerException('原版 $gameVersion 缺少客户端定义');
      }
      await downloadTasks([
        DownloadTask(
          url: mapUrl(clientRef.url),
          savePath: jarFile.path,
          sha1: clientRef.sha1,
          size: clientRef.size,
        ),
      ], onProgress);
    }
  }

  Future<String> _uniqueId(String base) async {
    var id = base;
    var n = 1;
    while (Directory(p.join(gameDir, 'versions', id)).existsSync()) {
      id = '$base-$n';
      n++;
    }
    return id;
  }
}
