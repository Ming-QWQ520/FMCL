import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';
import '../../providers/settings_provider.dart';
import '../mod/modrinth_service.dart';
import '../version/version_settings.dart';

/// 资源类型（借鉴 HMCL 资源下载分类）
enum ResourceKind {
  mod('mod', '模组', 'mods'),
  shader('shader', '光影', 'shaderpacks'),
  resourcepack('resourcepack', '资源包', 'resourcepacks'),
  world('world', '地图', 'saves');

  final String apiType; // Modrinth project_type
  final String label;
  final String subDir; // 生效游戏目录下的子目录
  const ResourceKind(this.apiType, this.label, this.subDir);
}

/// 资源安装服务：把 Modrinth 资源安装到版本隔离感知的目标目录。
///
/// - 模组：主文件 + 依赖树 → mods/
/// - 光影 / 资源包：zip 直接到 shaderpacks/ resourcepacks/
/// - 地图：zip 解压到 saves/<地图文件夹>/
class ResourceInstallService {
  ResourceInstallService(this._ref);

  // ignore: avoid_dynamic_calls
  final dynamic _ref;

  /// 计算目标目录（遵循版本隔离设置）
  static String targetDir(
    AppSettings global,
    String gameDir,
    String versionId,
    ResourceKind kind,
  ) {
    return VersionSettingsService.I.dirFor(
        global, gameDir, versionId, kind.subDir);
  }

  /// 从版本 id 猜测游戏版本（如 fmcl-fabric-1.20.1-0.15.11 → 1.20.1）
  static String guessGameVersion(String versionId) {
    final m = RegExp(r'(\d+\.\d+(\.\d+)?)').allMatches(versionId).toList();
    if (m.isNotEmpty) return m.first.group(1)!;
    return versionId;
  }

  /// 安装资源，返回安装说明。
  Future<String> install({
    required ModrinthSearchHit hit,
    required ResourceKind kind,
    required String versionId,
    required String gameVersion,
    String loader = 'fabric',
    void Function(String message)? onProgress,
  }) async {
    final settings = _ref.read(appSettingsProvider) as AppSettings;
    final gameDir = settings.gameDirectory;
    final dir = targetDir(settings, gameDir, versionId, kind);
    Directory(dir).createSync(recursive: true);

    // 1. 取版本列表（模组按 loader+游戏版本过滤；其它类型不做过滤，兼容性最好）
    onProgress?.call('解析 ${kind.label} 版本...');
    final versions = await ModrinthService.I.getVersions(
      projectId: hit.projectId,
      loader: kind == ResourceKind.mod ? loader : null,
      gameVersion: kind == ResourceKind.mod ? gameVersion : null,
    );
    if (versions.isEmpty) {
      throw NetworkException(
          '没有找到适配 $gameVersion ($loader) 的${kind.label}版本');
    }
    final primary = versions.first.primaryFile;
    if (primary == null) {
      throw const NetworkException('资源文件缺失');
    }

    // 2. 下载
    switch (kind) {
      case ResourceKind.mod:
        onProgress?.call('下载 ${primary.filename} ...');
        await ModrinthService.I.downloadMod(
          url: primary.url,
          savePath: p.join(dir, primary.filename),
        );
        // 3. 依赖树
        onProgress?.call('解析前置依赖...');
        final deps = await ModrinthService.I.resolveDependencyTree(
          version: versions.first,
          loader: loader,
          gameVersion: gameVersion,
        );
        for (final dep in deps) {
          onProgress?.call('下载前置 ${dep.fileName} ...');
          await ModrinthService.I.downloadMod(
            url: dep.url,
            savePath: p.join(dir, dep.fileName),
          );
        }
        return deps.isEmpty
            ? '已安装 ${primary.filename}'
            : '已安装 ${primary.filename}（含 ${deps.length} 个前置依赖）';
      case ResourceKind.world:
        onProgress?.call('下载地图 ${primary.filename} ...');
        final tmp = p.join(
            Directory.systemTemp.path, 'fmcl_world_${primary.filename}');
        await ModrinthService.I.downloadMod(
            url: primary.url, savePath: tmp);
        onProgress?.call('解压到 saves ...');
        final folderName = _extractWorld(tmp, dir, primary.filename);
        try {
          File(tmp).deleteSync();
        } catch (_) {}
        AppLogger.info('Resource', '地图已解压 → $folderName');
        return '地图「$folderName」已安装到 saves';
      default:
        onProgress?.call('下载 ${primary.filename} ...');
        await ModrinthService.I.downloadMod(
          url: primary.url,
          savePath: p.join(dir, primary.filename),
        );
        return '${kind.label}「${primary.filename}」已安装';
    }
  }

  /// 解压地图 zip 到 savesDir，返回实际地图文件夹名。
  String _extractWorld(String zipPath, String savesDir, String zipName) {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = arc.ZipDecoder().decodeBytes(bytes);

    // 判断 zip 顶层是否只有一个目录（该目录即地图名）
    String? topLevel;
    var hasFilesAtRoot = false;
    for (final e in archive) {
      if (!e.isFile) continue;
      final name = e.name;
      if (name.contains('/')) {
        final top = name.split('/').first;
        topLevel ??= top;
        if (top != topLevel) hasFilesAtRoot = true;
      } else {
        hasFilesAtRoot = true;
      }
    }

    final folder = (!hasFilesAtRoot && topLevel != null)
        ? topLevel
        : zipName.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');

    final destDir = Directory(p.join(savesDir, folder));
    if (destDir.existsSync()) {
      // 重名冲突：追加后缀
      var n = 1;
      while (Directory(p.join(savesDir, '$folder-$n')).existsSync()) {
        n++;
      }
      final renamed = Directory(p.join(savesDir, '$folder-$n'));
      renamed.createSync(recursive: true);
      _writeArchive(archive, renamed.path);
      return '$folder-$n';
    }
    destDir.createSync(recursive: true);
    _writeArchive(archive, destDir.path);
    return folder;
  }

  void _writeArchive(arc.Archive archive, String destRoot) {
    for (final e in archive) {
      if (!e.isFile) continue;
      final target = p.normalize(p.join(destRoot, e.name));
      if (!p.isWithin(p.normalize(destRoot), target) &&
          target != p.normalize(destRoot)) {
        continue; // zip-slip 防护
      }
      final f = File(target);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsBytesSync(e.content as List<int>);
    }
  }

  // ------------------------------------------------------------------
  // 本地内容列举（本地管理页）
  // ------------------------------------------------------------------

  /// 列出本地资源条目（按类型）
  Future<List<LocalResourceEntry>> listLocal({
    required AppSettings global,
    required String gameDir,
    required String versionId,
    required ResourceKind kind,
  }) async {
    final dir = targetDir(global, gameDir, versionId, kind);
    final d = Directory(dir);
    if (!d.existsSync()) return [];
    final result = <LocalResourceEntry>[];

    if (kind == ResourceKind.world) {
      await for (final e in d.list()) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        final hasLevel = File(p.join(e.path, 'level.dat')).existsSync();
        var size = 0;
        try {
          await for (final f
              in e.list(recursive: true, followLinks: false)) {
            if (f is File) size += f.lengthSync();
          }
        } catch (_) {}
        result.add(LocalResourceEntry(
          path: e.path,
          displayName: name,
          isDirectory: true,
          valid: hasLevel,
          sizeBytes: size,
        ));
      }
    } else {
      await for (final e in d.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        final lower = name.toLowerCase();
        final ok = kind == ResourceKind.mod
            ? (lower.endsWith('.jar') || lower.endsWith('.jar.disabled') ||
                lower.endsWith('.disabled'))
            : lower.endsWith('.zip');
        if (!ok) continue;
        result.add(LocalResourceEntry(
          path: e.path,
          displayName: name,
          isDirectory: false,
          valid: true,
          enabled: !lower.endsWith('.disabled'),
          sizeBytes: e.lengthSync(),
        ));
      }
    }
    result.sort((a, b) => a.displayName.compareTo(b.displayName));
    return result;
  }

  /// 删除本地资源（文件或目录）
  Future<void> deleteLocal(LocalResourceEntry entry) async {
    if (entry.isDirectory) {
      final d = Directory(entry.path);
      if (d.existsSync()) await d.delete(recursive: true);
    } else {
      final f = File(entry.path);
      if (f.existsSync()) await f.delete();
    }
  }

  /// 启停（仅模组：改 .disabled 后缀）
  Future<void> setEnabled(LocalResourceEntry entry, bool enabled) async {
    if (entry.isDirectory) return;
    final dir = p.dirname(entry.path);
    final current = p.basename(entry.path);
    String newName;
    if (enabled && current.endsWith('.disabled')) {
      newName = current.substring(0, current.length - '.disabled'.length);
    } else if (!enabled && !current.endsWith('.disabled')) {
      newName = '$current.disabled';
    } else {
      return;
    }
    await File(entry.path).rename(p.join(dir, newName));
  }
}

/// 本地资源条目
class LocalResourceEntry {
  final String path;
  final String displayName;
  final bool isDirectory;

  /// 地图有效性（saves 下含 level.dat）
  final bool valid;

  /// 模组启停状态
  final bool enabled;
  final int sizeBytes;

  const LocalResourceEntry({
    required this.path,
    required this.displayName,
    required this.isDirectory,
    this.valid = true,
    this.enabled = true,
    this.sizeBytes = 0,
  });
}

/// Provider
final resourceInstallServiceProvider =
    Provider<ResourceInstallService>(ResourceInstallService.new);
