import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';
import '../../providers/settings_provider.dart';
import '../download/download_manager.dart';
import '../install/installer_base.dart';
import '../install/rust_install_service.dart';
import '../version/version_settings.dart';

/// Modrinth 整合包（.mrpack）导入与安装。
///
/// 规范参考 modrinth.index.json formatVersion 1：
/// ```
/// {
///   "formatVersion": 1, "game": "minecraft",
///   "versionId": "...", "name": "...", "summary": "...",
///   "files": [{ "path": "mods/x.jar", "hashes": {"sha1": "..","sha512": ".."},
///               "env": {"client": "required"}, "downloads": ["..."], "fileSize": 1 }],
///   "dependencies": { "minecraft": "1.21.4", "fabric-loader": "0.16.9", ... }
/// }
/// ```
///
/// 安装流程（PCL2 整合包体验对齐）：
/// 1. 解析 index → 识别加载器与游戏版本
/// 2. 安装基础游戏 + 加载器（复用现有安装器）
/// 3. 下载整合包文件（env.client == unsupported 的跳过）
/// 4. 解压 overrides / client-overrides 到生效游戏目录（遵循版本隔离设置）
class ModpackService {
  ModpackService(this._ref);

  // ignore: avoid_dynamic_calls
  final dynamic _ref;

  /// 解析 .mrpack 文件，返回整合包索引。
  static ModrinthIndex parseMrpack(String mrpackPath) {
    final bytes = File(mrpackPath).readAsBytesSync();
    final archive = arc.ZipDecoder().decodeBytes(bytes);
    arc.ArchiveFile? entry;
    for (final e in archive) {
      if (e.name == 'modrinth.index.json') {
        entry = e;
        break;
      }
    }
    if (entry == null) {
      throw const ParseException(
          '无效的 .mrpack 整合包：缺少 modrinth.index.json');
    }
    try {
      final json = jsonDecode(utf8.decode(entry.content as List<int>))
          as Map<String, dynamic>;
      return ModrinthIndex.fromJson(json);
    } catch (e) {
      throw ParseException('整合包索引解析失败: $e');
    }
  }

  /// 安装整合包，返回最终版本 id。
  ///
  /// [mrpackPath] 本地 .mrpack 文件路径。
  /// [onProgress] 进度回调（phase: parse/resolve/download/extract/process/done/failed）。
  Future<String> install({
    required String mrpackPath,
    required void Function(InstallProgress) onProgress,
  }) async {
    // ---------- 1. 解析 ----------
    onProgress(const InstallProgress('parse', '解析整合包...'));
    final index = parseMrpack(mrpackPath);
    if (index.game != 'minecraft') {
      throw ParseException('不支持的整合包类型: ${index.game}');
    }
    final gameVersion = index.dependencies['minecraft'];
    if (gameVersion == null || gameVersion.isEmpty) {
      throw const ParseException('整合包缺少 Minecraft 版本依赖声明');
    }

    // 识别加载器
    String? loader;
    String? loaderVersion;
    for (final e in index.dependencies.entries) {
      switch (e.key) {
        case 'fabric-loader':
          loader = 'fabric';
          loaderVersion = e.value;
        case 'quilt-loader':
          loader = 'quilt';
          loaderVersion = e.value;
        case 'forge':
          loader = 'forge';
          loaderVersion = e.value;
        case 'neoforge':
          loader = 'neoforge';
          loaderVersion = e.value;
      }
      if (loader != null) break;
    }

    // ---------- 2. 基础游戏 + 加载器（Rust 合并安装管线） ----------
    final settings = _ref.read(appSettingsProvider) as AppSettings;
    final gameDir = settings.gameDirectory;

    // 版本 id：整合包名 + 版本号
    final baseId =
        '${index.name.isEmpty ? 'modpack' : index.name} ${index.versionId}'
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');

    onProgress(InstallProgress('process',
        loader == null ? '安装 Minecraft $gameVersion...' : '安装 $loader $loaderVersion 基础...'));
    final versionId = await RustInstallService(
      _ref,
      params: RustInstallParams(
        gameVersion: gameVersion,
        instanceName: baseId,
        fabricVersion: loader == 'fabric' ? loaderVersion : null,
        quiltVersion: loader == 'quilt' ? loaderVersion : null,
        forgeVersion: loader == 'forge' ? loaderVersion : null,
        neoforgeVersion: loader == 'neoforge' ? loaderVersion : null,
      ),
    ).install(onProgress: onProgress);

    AppLogger.info('Modpack', '加载器安装完成: $versionId');

    // ---------- 3. 计算生效游戏目录（遵循版本隔离） ----------
    final override = await VersionSettingsService.I.load(gameDir, versionId);
    final effective = VersionSettingsService.I.resolve(
        settings, gameDir, versionId, override);
    final workDir = effective.workDir;

    // ---------- 4. 下载整合包文件 ----------
    final dm = _ref.read(downloadManagerProvider) as DownloadManager;
    final tasks = <DownloadTask>[];
    for (final file in index.files) {
      final envClient = file.env['client'];
      if (envClient == 'unsupported') continue; // 客户端不需要的文件跳过
      if (file.downloads.isEmpty) continue;
      tasks.add(DownloadTask(
        url: file.downloads.first,
        savePath: p.join(workDir, file.path),
        sha1: file.hashes['sha1'],
        size: file.fileSize > 0 ? file.fileSize : null,
      ));
    }
    if (tasks.isNotEmpty) {
      onProgress(
          InstallProgress('download', '下载整合包文件（${tasks.length} 个）...',
              progress: 0));
      await dm.downloadAll(tasks, onProgress: (state) {
        onProgress(InstallProgress(
          'download',
          '下载整合包文件 ${state.finishedFiles}/${state.totalFiles}',
          progress: state.progress,
        ));
      });
      final st = _ref.read(downloadStateProvider);
      if (st.phase == DownloadPhase.failed) {
        throw NetworkException('整合包文件下载失败: ${st.lastError ?? '未知错误'}');
      }
    }

    // ---------- 5. 解压 overrides ----------
    onProgress(InstallProgress('extract', '释放整合包配置...'));
    final extracted = _extractOverrides(mrpackPath, workDir);
    AppLogger.info('Modpack', 'overrides 释放完成: $extracted 个文件');

    onProgress(InstallProgress('done', '整合包「${index.name}」安装完成'));
    return versionId;
  }

  /// 解压 overrides / client-overrides 到 workDir（含 zip-slip 防护）。
  int _extractOverrides(String mrpackPath, String workDir) {
    final bytes = File(mrpackPath).readAsBytesSync();
    final archive = arc.ZipDecoder().decodeBytes(bytes);
    var count = 0;
    final dest = Directory(workDir);
    if (!dest.existsSync()) dest.createSync(recursive: true);

    for (final e in archive) {
      if (e.isFile) {
        String? rel;
        if (e.name.startsWith('overrides/')) {
          rel = e.name.substring('overrides/'.length);
        } else if (e.name.startsWith('client-overrides/')) {
          rel = e.name.substring('client-overrides/'.length);
        }
        if (rel == null || rel.isEmpty) continue;

        // zip-slip 防护：规范化后必须仍在 workDir 内
        final target = p.normalize(p.join(workDir, rel));
        if (!p.isWithin(p.normalize(workDir), target) &&
            target != p.normalize(workDir)) {
          AppLogger.warn('Modpack', '跳过非法条目: ${e.name}');
          continue;
        }

        final f = File(target);
        if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
        f.writeAsBytesSync(e.content as List<int>, flush: true);
        count++;
      }
    }
    return count;
  }
}

/// modrinth.index.json 模型
class ModrinthIndex {
  final int formatVersion;
  final String game;
  final String versionId;
  final String name;
  final String summary;
  final List<ModrinthIndexFile> files;
  final Map<String, String> dependencies;

  const ModrinthIndex({
    required this.formatVersion,
    required this.game,
    required this.versionId,
    required this.name,
    required this.summary,
    required this.files,
    required this.dependencies,
  });

  factory ModrinthIndex.fromJson(Map<String, dynamic> json) {
    return ModrinthIndex(
      formatVersion: json['formatVersion'] as int? ?? 1,
      game: json['game'] as String? ?? 'minecraft',
      versionId: json['versionId'] as String? ?? '1.0',
      name: json['name'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      files: (json['files'] as List? ?? [])
          .map((e) =>
              ModrinthIndexFile.fromJson(e as Map<String, dynamic>))
          .toList(),
      dependencies: (json['dependencies'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString())),
    );
  }

  /// 加载器描述（用于 UI 展示）
  String get loaderLabel {
    if (dependencies.containsKey('fabric-loader')) {
      return 'Fabric ${dependencies['fabric-loader']}';
    }
    if (dependencies.containsKey('quilt-loader')) {
      return 'Quilt ${dependencies['quilt-loader']}';
    }
    if (dependencies.containsKey('forge')) {
      return 'Forge ${dependencies['forge']}';
    }
    if (dependencies.containsKey('neoforge')) {
      return 'NeoForge ${dependencies['neoforge']}';
    }
    return '原版';
  }

  String get gameVersion => dependencies['minecraft'] ?? '';
}

/// 整合包内单个文件
class ModrinthIndexFile {
  final String path;
  final Map<String, String> hashes;
  final Map<String, String> env;
  final List<String> downloads;
  final int fileSize;

  const ModrinthIndexFile({
    required this.path,
    required this.hashes,
    required this.env,
    required this.downloads,
    required this.fileSize,
  });

  factory ModrinthIndexFile.fromJson(Map<String, dynamic> json) {
    return ModrinthIndexFile(
      path: json['path'] as String? ?? '',
      hashes: (json['hashes'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString())),
      env: (json['env'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString())),
      downloads: (json['downloads'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      fileSize: json['fileSize'] as int? ?? 0,
    );
  }
}

/// Provider
final modpackServiceProvider =
    Provider<ModpackService>(ModpackService.new);
