import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/sources/download_source.dart';
import '../download/download_manager.dart';
import '../download/http_service.dart';
import '../install/installer_base.dart';
import 'version_repository.dart';

/// 本地版本管理。
///
/// 借鉴 PCL2 / HMCL 的版本识别与导入方式：
/// - 扫描时容忍「目录名 ≠ json 名 ≠ jar 名」的第三方结构（PCL 式模糊识别）
/// - 从磁盘导入：整个版本文件夹（HMCL「从磁盘安装版本」）
/// - 压缩包导入：版本 zip（PCL 支持压缩包方式）
/// - 版本修复：自动补全缺失的 version json / client jar（PCL「版本修复」）
class LocalVersionManager {
  LocalVersionManager._();
  static final LocalVersionManager instance = LocalVersionManager._();
  static LocalVersionManager get I => instance;

  // ------------------------------------------------------------------
  // 扫描
  // ------------------------------------------------------------------

  /// 列出本地已安装版本。
  ///
  /// 识别规则（PCL 式模糊识别）：
  /// - 目录内任意一个「长得像版本 json」的文件（含 mainClass / minecraftArguments /
  ///   libraries / inheritsFrom 特征）都可作为版本定义，不再强求 <目录名>.json
  /// - 目录内最大的 .jar 视为客户端 jar（过滤 natives 等小文件）
  Future<List<LocalVersion>> listVersions(String gameDir) async {
    final dir = Directory(p.join(gameDir, 'versions'));
    if (!dir.existsSync()) return [];
    final result = <LocalVersion>[];
    for (final sub in dir.listSync()) {
      if (sub is! Directory) continue;
      final dirName = p.basename(sub.path);
      if (dirName.startsWith('.')) continue; // 隐藏目录跳过
      try {
        final v = _identifyVersion(sub, dirName);
        if (v != null) result.add(v);
      } catch (e) {
        AppLogger.warn('VersionMgr', '跳过损坏版本 $dirName: $e');
      }
    }
    result.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return result;
  }

  /// 识别单个版本目录。
  LocalVersion? _identifyVersion(Directory dir, String dirName) {
    File? jsonFile;
    File? jarFile;
    String? jsonId;

    final canonicalJson = File(p.join(dir.path, '$dirName.json'));
    final canonicalJar = File(p.join(dir.path, '$dirName.jar'));

    if (canonicalJson.existsSync()) {
      jsonFile = canonicalJson;
    } else {
      // 模糊识别：目录内任意合法版本 json
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.toLowerCase().endsWith('.json')) continue;
        if (p.basename(f.path) == versionSettingsFileName) continue;
        try {
          final content = f.readAsStringSync();
          if (content.length > 4 * 1024 * 1024) continue; // >4MB 的 json 不正常
          if (content.contains('"mainClass"') ||
              content.contains('"minecraftArguments"') ||
              content.contains('"inheritsFrom"') ||
              (content.contains('"libraries"') && content.contains('"id"'))) {
            jsonFile = f;
            jsonId = RegExp(r'"id"\s*:\s*"([^"]+)"').firstMatch(content)?.group(1);
            break;
          }
        } catch (_) {}
      }
    }

    if (jsonFile == null) return null;

    if (canonicalJar.existsSync()) {
      jarFile = canonicalJar;
    } else {
      // 模糊识别：目录内最大的 jar（>256KB，跳过疑似工具小包）
      File? best;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.toLowerCase().endsWith('.jar')) continue;
        try {
          if (f.lengthSync() < 256 * 1024) continue;
          if (best == null || f.lengthSync() > best.lengthSync()) best = f;
        } catch (_) {}
      }
      jarFile = best;
    }

    // 有效 id：json 内 id 优先（PCL 行为），否则目录名
    var id = dirName;
    if (jsonId != null && jsonId.isNotEmpty) {
      // json id 与目录名同前缀或目录名不含版本号时信任 json id；
      // 保守起见：目录名直接作为 id（文件夹名 = 版本目录名的约定优先），
      // 仅当目录名明显是随机串（含空格或 > 40 字符）时采用 json id。
      if (dirName.length > 40 || dirName.contains(' ')) id = jsonId;
    }

    DateTime modified;
    try {
      modified = jsonFile.lastModifiedSync();
    } catch (_) {
      modified = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return LocalVersion(
      id: id,
      dirName: dirName,
      jsonPath: jsonFile.path,
      jarPath: jarFile?.path,
      lastModified: modified,
    );
  }

  /// 删除版本（整个目录）
  Future<void> removeVersion(String gameDir, String versionId) async {
    final dir = Directory(p.join(gameDir, 'versions', versionId));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      AppLogger.info('VersionMgr', '已删除版本 $versionId');
    }
  }

  /// 版本是否完整（json + jar 都在）
  Future<bool> isVersionComplete(String gameDir, String versionId) async {
    final list = await listVersions(gameDir);
    final v = list.where((e) => e.id == versionId || e.dirName == versionId).firstOrNull;
    if (v == null) return false;
    return v.hasJar;
  }

  /// 创建版本隔离目录命名（同 id 冲突时追加后缀）
  Future<String> uniqueVersionId(String gameDir, String baseId) async {
    var id = baseId;
    var n = 1;
    while (Directory(p.join(gameDir, 'versions', id)).existsSync()) {
      id = '$baseId-$n';
      n++;
    }
    return id;
  }

  // ------------------------------------------------------------------
  // 导入（借鉴 HMCL「从磁盘安装版本」/ PCL 压缩包导入）
  // ------------------------------------------------------------------

  /// 从版本文件夹导入。
  ///
  /// 复制整个文件夹到 `versions/<新id>`，并归一化命名：
  /// json → `<id>.json`（内容 id 同步改写），client jar → `<id>.jar`。
  /// 返回最终版本 id。
  Future<String> importFromFolder(
    String gameDir,
    String sourceDirPath, {
    String? newName,
    void Function(InstallProgress)? onProgress,
  }) async {
    final src = Directory(sourceDirPath);
    if (!src.existsSync()) {
      throw const ParseException('所选文件夹不存在');
    }
    onProgress?.call(const InstallProgress('process', '正在识别版本文件...'));

    // 预识别：确认这是个版本目录（有 json），并确定基础 id
    final identified = _identifyVersion(src, p.basename(sourceDirPath));
    if (identified == null) {
      throw const ParseException(
          '未在该文件夹中找到有效的版本 JSON（缺少 mainClass / minecraftArguments 等特征）');
    }

    final baseId = (newName?.trim().isNotEmpty ?? false)
        ? newName!.trim()
        : p.basename(sourceDirPath);
    final newId = await uniqueVersionId(gameDir, baseId);
    final destDir = Directory(p.join(gameDir, 'versions', newId));
    destDir.createSync(recursive: true);

    onProgress?.call(const InstallProgress('download', '正在复制版本文件...'));
    final copied = await _copyDirectory(src, destDir);
    AppLogger.info('VersionMgr', '导入版本 $newId：复制 $copied 个文件');

    // 归一化命名
    await _normalizeNames(destDir, newId);

    onProgress?.call(InstallProgress('done', '版本 $newId 导入完成'));
    return newId;
  }

  /// 从 zip 压缩包导入版本（PCL 式）。
  Future<String> importFromZip(
    String gameDir,
    String zipPath, {
    String? newName,
    void Function(InstallProgress)? onProgress,
  }) async {
    final f = File(zipPath);
    if (!f.existsSync()) throw const ParseException('所选压缩包不存在');
    onProgress?.call(const InstallProgress('process', '正在解压压缩包...'));

    final bytes = f.readAsBytesSync();
    final arc.Archive archive;
    try {
      archive = arc.ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw ParseException('无法解压（仅支持 zip 格式）: $e');
    }

    // 解压到临时目录
    final tmp = await Directory.systemTemp
        .createTemp('fmcl_import_');
    try {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        // zip-slip 防护
        final target = p.normalize(p.join(tmp.path, entry.name));
        if (!p.isWithin(tmp.path, target) && target != p.normalize(tmp.path)) {
          continue;
        }
        final file = File(target);
        if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.content as List<int>);
      }

      // 若 zip 根只有一个子目录（常见打包习惯），进入该目录
      var srcDir = tmp;
      final top = tmp.listSync();
      final dirs = top.whereType<Directory>().toList();
      final files = top.whereType<File>().toList();
      if (dirs.length == 1 && files.isEmpty) {
        srcDir = dirs.first;
      }

      onProgress?.call(const InstallProgress('process', '正在识别版本文件...'));
      final identified = _identifyVersion(srcDir, p.basename(srcDir.path));
      if (identified == null) {
        throw const ParseException(
            '压缩包中未找到有效的版本 JSON（注意：导入的是「版本压缩包」，整合包请使用「导入整合包」）');
      }

      final baseId = (newName?.trim().isNotEmpty ?? false)
          ? newName!.trim()
          : p.basename(zipPath).replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
      final newId = await uniqueVersionId(gameDir, baseId);
      final destDir = Directory(p.join(gameDir, 'versions', newId));
      destDir.createSync(recursive: true);

      onProgress?.call(const InstallProgress('download', '正在复制版本文件...'));
      await _copyDirectory(srcDir, destDir);
      await _normalizeNames(destDir, newId);

      onProgress?.call(InstallProgress('done', '版本 $newId 导入完成'));
      return newId;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 归一化版本目录内命名：json → `<id>.json`（id 改写）、最大 jar → `<id>.jar`
  Future<void> _normalizeNames(Directory dir, String newId) async {
    // json
    final canonicalJson = File(p.join(dir.path, '$newId.json'));
    if (!canonicalJson.existsSync()) {
      File? found;
      String content = '';
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.toLowerCase().endsWith('.json')) continue;
        if (p.basename(f.path) == versionSettingsFileName) continue;
        try {
          final c = f.readAsStringSync();
          if (c.contains('"mainClass"') ||
              c.contains('"minecraftArguments"') ||
              c.contains('"inheritsFrom"')) {
            found = f;
            content = c;
            break;
          }
        } catch (_) {}
      }
      if (found != null) {
        // 改写 json 内 id 为最终目录名
        try {
          final json = jsonDecode(content);
          if (json is Map<String, dynamic>) {
            json['id'] = newId;
            content = const JsonEncoder.withIndent('  ').convert(json);
          }
        } catch (_) {}
        canonicalJson.writeAsStringSync(content);
        if (p.basename(found.path) != '$newId.json') found.deleteSync();
      }
    } else {
      // 已是规范命名：仍改写 id 保持一致
      try {
        final json = jsonDecode(canonicalJson.readAsStringSync());
        if (json is Map<String, dynamic> && json['id'] != newId) {
          json['id'] = newId;
          canonicalJson.writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(json));
        }
      } catch (_) {}
    }

    // jar
    final canonicalJar = File(p.join(dir.path, '$newId.jar'));
    if (!canonicalJar.existsSync()) {
      File? best;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.toLowerCase().endsWith('.jar')) continue;
        try {
          if (f.lengthSync() < 256 * 1024) continue;
          if (best == null || f.lengthSync() > best.lengthSync()) best = f;
        } catch (_) {}
      }
      if (best != null) {
        try {
          best.renameSync(canonicalJar.path);
        } catch (_) {
          best.copySync(canonicalJar.path);
        }
      }
    }
  }

  /// 递归复制目录，返回复制文件数
  Future<int> _copyDirectory(Directory src, Directory dest) async {
    var count = 0;
    if (!dest.existsSync()) dest.createSync(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final target = p.join(dest.path, p.basename(entity.path));
      if (entity is File) {
        await File(target).copy(entity.path);
        count++;
      } else if (entity is Directory) {
        count += await _copyDirectory(entity, Directory(target));
      }
    }
    return count;
  }

  // ------------------------------------------------------------------
  // 修复（借鉴 PCL「版本修复」：自动补全缺失 json / client jar / 父版本链）
  // ------------------------------------------------------------------

  /// 修复版本：补全缺失的 version json、client jar，并递归补全 inheritsFrom 父版本。
  ///
  /// libraries / assets 由启动引擎按需补全，此处仅处理版本定义与客户端主体。
  Future<void> repairVersion(
    String gameDir,
    String versionId, {
    void Function(InstallProgress)? onProgress,
    DownloadManager? downloadManager,
    DownloadSource? source,
  }) async {
    final dm = downloadManager;
    onProgress?.call(InstallProgress('resolve', '检查版本 $versionId ...'));

    final dir = Directory(p.join(gameDir, 'versions', versionId));
    final canonicalJson = File(p.join(dir.path, '$versionId.json'));
    final canonicalJar = File(p.join(dir.path, '$versionId.jar'));

    // ---------- 1. 修复 json ----------
    Map<String, dynamic>? json;
    if (canonicalJson.existsSync()) {
      try {
        json = jsonDecode(canonicalJson.readAsStringSync())
            as Map<String, dynamic>;
      } catch (_) {
        json = null;
      }
    }
    if (json == null) {
      // 模糊识别已有 json 并归一化
      final identified = _identifyVersion(dir, versionId);
      if (identified != null) {
        try {
          json = jsonDecode(File(identified.jsonPath).readAsStringSync())
              as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    if (json == null) {
      // 从清单下载官方 json（仅官方版本可修复；第三方 loader 版本 json 缺失无法凭空构造）
      final fetched = await _downloadOfficialJson(versionId);
      if (fetched == null) {
        throw ParseException(
            '版本 $versionId 缺少定义文件且无法从清单恢复（第三方版本请重新安装）');
      }
      json = fetched;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      canonicalJson.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(json));
      onProgress?.call(InstallProgress('download', '已恢复版本定义 $versionId.json'));
    }

    final inheritsFrom = json['inheritsFrom'] as String?;
    final clientRef = json['downloads']?['client'] as Map<String, dynamic>?;

    // ---------- 2. 递归修复父版本 ----------
    if (inheritsFrom != null && inheritsFrom.isNotEmpty) {
      final parentDir = Directory(p.join(gameDir, 'versions', inheritsFrom));
      final parentJson =
          File(p.join(parentDir.path, '$inheritsFrom.json'));
      final parentJar =
          File(p.join(parentDir.path, '$inheritsFrom.jar'));
      if (!parentJson.existsSync() || !parentJar.existsSync()) {
        onProgress?.call(InstallProgress(
            'resolve', '修复父版本 $inheritsFrom ...'));
        await repairVersion(gameDir, inheritsFrom,
            onProgress: onProgress,
            downloadManager: dm,
            source: source);
      }

      // loader 版本目录 jar 缺失：官方安装器行为是复用原版 jar（复制一份）
      if (!canonicalJar.existsSync()) {
        try {
          canonicalJar.copySync(parentJar.path);
          onProgress?.call(InstallProgress(
              'download', '已为 $versionId 复制客户端主体'));
        } catch (_) {}
      }
    } else if (clientRef != null) {
      // ---------- 3. 原版版本：直接下载 client jar ----------
      final url = clientRef['url'] as String?;
      final sha1 = clientRef['sha1'] as String?;
      final size = clientRef['size'] as int?;
      if (url != null && url.isNotEmpty && !canonicalJar.existsSync()) {
        onProgress?.call(
            InstallProgress('download', '下载客户端 $versionId.jar ...'));
        final src = source ??
            DownloadSources.of(
                HttpService.I.primarySource.kind);
        final tasks = [
          DownloadTask(
            url: src.mapUrl(url),
            savePath: canonicalJar.path,
            sha1: sha1,
            size: size,
          ),
        ];
        if (dm != null) {
          await dm.downloadAll(tasks);
        } else {
          // 无 DownloadManager 时用内存下载兜底（修复场景一般有小文件）
          final bytes =
              await HttpService.I.getBytesWithFallback(src.mapUrl(url));
          canonicalJar.writeAsBytesSync(bytes, flush: true);
        }
        onProgress?.call(InstallProgress('download', '客户端下载完成'));
      }
    }

    onProgress?.call(InstallProgress('done', '版本 $versionId 修复完成'));
  }

  Future<Map<String, dynamic>?> _downloadOfficialJson(String versionId) async {
    try {
      final manifest = await VersionRepository.I.fetchManifest();
      final entries = (manifest['versions'] as List? ?? []);
      final entry = entries.cast<Map<String, dynamic>?>().firstWhere(
            (e) => e?['id'] == versionId,
            orElse: () => null,
          );
      if (entry == null) return null;
      return await HttpService.I.getJsonWithFallback(
        entry['url'] as String,
        mapThroughSource: true,
      ) as Map<String, dynamic>;
    } catch (e) {
      AppLogger.warn('VersionMgr', '下载官方版本定义失败 $versionId: $e');
      return null;
    }
  }

  // ------------------------------------------------------------------
  // 导出（借鉴 HMCL「导出实例」：打包版本目录为 zip）
  // ------------------------------------------------------------------

  /// 将版本目录打包为 zip（不含 fmcl-settings 私有设置）。
  Future<void> exportVersion(
    String gameDir,
    String versionId,
    String targetZipPath,
  ) async {
    final dir = Directory(p.join(gameDir, 'versions', versionId));
    if (!dir.existsSync()) {
      throw ParseException('版本目录不存在: $versionId');
    }
    final archive = arc.Archive();
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: dir.path);
      if (rel == versionSettingsFileName) continue;
      try {
        final bytes = entity.readAsBytesSync();
        archive.addFile(arc.ArchiveFile(rel, bytes.length, bytes));
      } catch (_) {}
    }
    final zipData = arc.ZipEncoder().encode(archive);
    final out = File(targetZipPath);
    if (!out.parent.existsSync()) out.parent.createSync(recursive: true);
    out.writeAsBytesSync(zipData, flush: true);
    AppLogger.info(
        'VersionMgr', '版本 $versionId 已导出 → $targetZipPath');
  }
}

/// 版本设置文件名（与 VersionSettingsService.fileName 保持一致，避免循环依赖）
const String versionSettingsFileName = 'fmcl-settings.json';

/// 本地版本条目
class LocalVersion {
  /// 对外展示 / 启动使用的 id
  final String id;

  /// 实际目录名（导入模糊识别时可能与 id 不同）
  final String dirName;
  final String jsonPath;
  final String? jarPath;
  final DateTime lastModified;

  const LocalVersion({
    required this.id,
    String? dirName,
    required this.jsonPath,
    this.jarPath,
    required this.lastModified,
  }) : dirName = dirName ?? id;

  bool get hasJar => jarPath != null;

  String get dirPath => p.dirname(jsonPath);

  /// 尝试从 JSON 推断加载器类型与游戏版本
  (String loader, String? gameVersion) get loaderInfo {
    try {
      final content = File(jsonPath).readAsStringSync();
      final hasFabric = content.contains('fabricloader') ||
          content.contains('net.fabricmc.loader');
      final hasForge = content.contains('forge') &&
          content.contains('net.minecraftforge');
      final hasNeo = content.contains('neoforge');
      final hasQuilt = content.contains('quilt_loader');
      final gameVer = _extractGameVersion(content);
      if (hasNeo) return ('neoforge', gameVer);
      if (hasFabric) return ('fabric', gameVer);
      if (hasQuilt) return ('quilt', gameVer);
      if (hasForge) return ('forge', gameVer);
      return ('vanilla', gameVer);
    } catch (_) {
      return ('unknown', null);
    }
  }

  String? _extractGameVersion(String content) {
    final m = RegExp(r'"inheritsFrom"\s*:\s*"([^"]+)"').firstMatch(content);
    if (m != null) return m.group(1);
    final idm = RegExp(r'"id"\s*:\s*"([^"]+)"').firstMatch(content);
    return idm?.group(1);
  }
}

/// 简单的目录大小统计
Future<int> directorySize(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  var size = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        size += entity.lengthSync();
      } catch (_) {}
    }
  }
  return size;
}
