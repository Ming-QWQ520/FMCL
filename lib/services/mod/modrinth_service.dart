import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';

/// Modrinth API v2 客户端。
///
/// 支持模组搜索、版本解析、依赖解析与文件下载。
/// CurseForge 因需要第三方 API Key 暂不接入（见 TODO.md #M-06）。
class ModrinthService {
  ModrinthService._();
  static final ModrinthService instance = ModrinthService._();
  static ModrinthService get I => instance;

  static const String _api = AppConstants.modrinthApi;

  /// 搜索模组
  Future<List<ModrinthSearchHit>> search({
    required String query,
    String loader = 'fabric',
    String? gameVersion,
    int limit = 20,
    int offset = 0,
  }) async {
    final facets = [
      ['project_type:mod'],
      ['categories:$loader'],
      if (gameVersion != null && gameVersion.isNotEmpty)
        ['versions:$gameVersion'],
    ];
    final url = '$_api/search?query=$query&limit=$limit&offset=$offset'
        '&facets=${Uri.encodeComponent(jsonEncode(facets))}';

    final data = await _getJson(url);
    return (data['hits'] as List? ?? [])
        .map((e) => ModrinthSearchHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取项目详情
  Future<ModrinthProject> getProject(String projectId) async {
    final data = await _getJson('$_api/project/$projectId');
    return ModrinthProject.fromJson(data);
  }

  /// 获取项目版本（可按 loader 与游戏版本过滤）
  Future<List<ModrinthVersion>> getVersions({
    required String projectId,
    String? loader,
    String? gameVersion,
  }) async {
    final params = <String>[];
    if (loader != null) params.add('loaders=["$loader"]');
    if (gameVersion != null) params.add('game_versions=["$gameVersion"]');
    final qs = params.isEmpty ? '' : '?${params.join('&')}';
    final data = await _getJson('$_api/project/$projectId/version$qs');
    return (data as List)
        .map((e) => ModrinthVersion.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 解析依赖链（BFS，含传递依赖）
  Future<List<ModrinthVersionFile>> resolveDependencyTree({
    required ModrinthVersion version,
    required String loader,
    required String gameVersion,
    int maxDepth = 4,
  }) async {
    final result = <ModrinthVersionFile>[];
    final visited = <String>{};
    var queue = <String>[...version.requiredDependencies];

    var depth = 0;
    while (queue.isNotEmpty && depth < maxDepth) {
      final next = <String>[];
      for (final depId in queue) {
        if (visited.contains(depId)) continue;
        visited.add(depId);
        try {
          final versions = await getVersions(
            projectId: depId,
            loader: loader,
            gameVersion: gameVersion,
          );
          if (versions.isEmpty) continue;
          final latest = versions.first;
          final primary = latest.primaryFile;
          if (primary != null) {
            result.add(ModrinthVersionFile(
              projectId: depId,
              projectName: latest.name,
              fileName: primary.filename,
              url: primary.url,
              sha1: primary.hashes['sha1'],
              size: primary.size,
            ));
            next.addAll(latest.requiredDependencies);
          }
        } catch (e) {
          AppLogger.warn('Modrinth', '依赖解析失败 $depId: $e');
        }
      }
      queue = next;
      depth++;
    }
    return result;
  }

  Future<dynamic> _getJson(String url) async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw NetworkException('Modrinth API 错误 HTTP ${resp.statusCode}');
      }
      return jsonDecode(await resp.transform(utf8.decoder).join());
    } finally {
      client.close(force: true);
    }
  }

  /// 下载 mod 文件到指定路径
  Future<void> downloadMod({
    required String url,
    required String savePath,
    String? sha1,
  }) async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw NetworkException('Mod 下载失败 HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      await Directory(p.dirname(savePath)).create(recursive: true);
      await File(savePath).writeAsBytes(bytes, flush: true);
      AppLogger.info('Modrinth', '已下载 ${p.basename(savePath)}');
    } finally {
      client.close(force: true);
    }
  }
}

class ModrinthSearchHit {
  final String projectId;
  final String slug;
  final String title;
  final String description;
  final List<String> categories;
  final int downloads;
  final String? iconUrl;
  final String? author;

  const ModrinthSearchHit({
    required this.projectId,
    required this.slug,
    required this.title,
    required this.description,
    this.categories = const [],
    this.downloads = 0,
    this.iconUrl,
    this.author,
  });

  factory ModrinthSearchHit.fromJson(Map<String, dynamic> json) =>
      ModrinthSearchHit(
        projectId: json['project_id'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        categories: (json['categories'] as List? ?? [])
            .map((e) => e as String)
            .toList(),
        downloads: json['downloads'] as int? ?? 0,
        iconUrl: json['icon_url'] as String?,
        author: json['author'] as String?,
      );
}

class ModrinthProject {
  final String id;
  final String title;
  final String description;
  final String? body;
  final List<String> loaders;
  final List<String> gameVersions;

  const ModrinthProject({
    required this.id,
    required this.title,
    required this.description,
    this.body,
    this.loaders = const [],
    this.gameVersions = const [],
  });

  factory ModrinthProject.fromJson(Map<String, dynamic> json) =>
      ModrinthProject(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        body: json['body'] as String?,
        loaders:
            (json['loaders'] as List? ?? []).map((e) => e as String).toList(),
        gameVersions: (json['game_versions'] as List? ?? [])
            .map((e) => e as String)
            .toList(),
      );
}

class ModrinthVersion {
  final String id;
  final String name;
  final String versionNumber;
  final List<String> loaders;
  final List<String> gameVersions;
  final List<ModrinthFile> files;
  final List<String> dependencies;

  const ModrinthVersion({
    required this.id,
    required this.name,
    required this.versionNumber,
    this.loaders = const [],
    this.gameVersions = const [],
    this.files = const [],
    this.dependencies = const [],
  });

  factory ModrinthVersion.fromJson(Map<String, dynamic> json) {
    final deps = (json['dependencies'] as List? ?? [])
        .whereType<Map>()
        .where((d) =>
            d['dependency_type'] == 'required' && d['project_id'] != null)
        .map((d) => d['project_id'] as String)
        .toList();
    return ModrinthVersion(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      versionNumber: json['version_number'] as String? ?? '',
      loaders:
          (json['loaders'] as List? ?? []).map((e) => e as String).toList(),
      gameVersions: (json['game_versions'] as List? ?? [])
          .map((e) => e as String)
          .toList(),
      files: (json['files'] as List? ?? [])
          .map((e) => ModrinthFile.fromJson(e as Map<String, dynamic>))
          .toList(),
      dependencies: deps,
    );
  }

  ModrinthFile? get primaryFile {
    for (final f in files) {
      if (f.primary) return f;
    }
    return files.isEmpty ? null : files.first;
  }

  List<String> get requiredDependencies => dependencies;
}

class ModrinthFile {
  final String filename;
  final String url;
  final int size;
  final Map<String, String> hashes;
  final bool primary;

  const ModrinthFile({
    required this.filename,
    required this.url,
    this.size = 0,
    this.hashes = const {},
    this.primary = false,
  });

  factory ModrinthFile.fromJson(Map<String, dynamic> json) => ModrinthFile(
        filename: json['filename'] as String,
        url: json['url'] as String,
        size: json['size'] as int? ?? 0,
        hashes: (json['hashes'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        primary: json['primary'] as bool? ?? false,
      );
}

/// 依赖下载描述
class ModrinthVersionFile {
  final String projectId;
  final String projectName;
  final String fileName;
  final String url;
  final String? sha1;
  final int size;

  const ModrinthVersionFile({
    required this.projectId,
    required this.projectName,
    required this.fileName,
    required this.url,
    this.sha1,
    this.size = 0,
  });
}

/// 本地 mod 文件条目
class LocalModEntry {
  final String path;
  final String fileName;
  final bool enabled; // .disabled 后缀 = 停用
  final int sizeBytes;
  final String? modId;
  final String? name;

  const LocalModEntry({
    required this.path,
    required this.fileName,
    required this.enabled,
    required this.sizeBytes,
    this.modId,
    this.name,
  });
}

/// 本地 Mod 管理（列出 / 启用 / 停用 / 删除）
class LocalModService {
  LocalModService._();
  static final LocalModService instance = LocalModService._();
  static LocalModService get I => instance;

  /// 列出版本 mods 目录。
  ///
  /// [modsDir] 为空时使用默认位置 `versions/<id>/mods`（隔离模式）。
  /// 非隔离版本应传入根目录 mods（由调用方经 VersionSettingsService 计算）。
  Future<List<LocalModEntry>> listMods(String versionId, String gameDir,
      {String? modsDir}) async {
    final dir = Directory(modsDir ?? p.join(gameDir, 'versions', versionId, 'mods'));
    if (!dir.existsSync()) return [];
    final entries = <LocalModEntry>[];
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      if (!f.path.endsWith('.jar') && !f.path.endsWith('.disabled')) continue;
      final name = p.basename(f.path);
      entries.add(LocalModEntry(
        path: f.path,
        fileName: name,
        enabled: !name.endsWith('.disabled'),
        sizeBytes: f.lengthSync(),
      ));
    }
    entries.sort((a, b) => a.fileName.compareTo(b.fileName));
    return entries;
  }

  /// 启用/停用 mod（改后缀）
  Future<void> setEnabled(LocalModEntry mod, bool enabled) async {
    final dir = p.dirname(mod.path);
    final currentName = p.basename(mod.path);
    String newName;
    if (enabled && currentName.endsWith('.disabled')) {
      newName =
          currentName.substring(0, currentName.length - '.disabled'.length);
    } else if (!enabled && !currentName.endsWith('.disabled')) {
      newName = '$currentName.disabled';
    } else {
      return;
    }
    await File(mod.path).rename(p.join(dir, newName));
  }

  /// 删除 mod
  Future<void> delete(LocalModEntry mod) async {
    final f = File(mod.path);
    if (f.existsSync()) await f.delete();
  }

  /// 从 jar 内 fabric.mod.json / mods.toml 读取 mod 元信息
  Future<({String? modId, String? name})> readModMeta(String jarPath) async {
    try {
      final bytes = await File(jarPath).readAsBytes();
      final archive = arc.ZipDecoder().decodeBytes(bytes);

      List<int>? find(String name) {
        for (final e in archive) {
          if (e.name == name) return e.content as List<int>;
        }
        return null;
      }

      final fabricJson = find('fabric.mod.json');
      if (fabricJson != null) {
        final json = jsonDecode(utf8.decode(fabricJson)) as Map<String, dynamic>;
        return (modId: json['id'] as String?, name: json['name'] as String?);
      }
      final toml = find('META-INF/mods.toml') ?? find('META-INF/neoforge.mods.toml');
      if (toml != null) {
        final text = utf8.decode(toml);
        final nameMatch =
            RegExp(r'''displayName\s*=\s*"([^"]+)"''').firstMatch(text);
        final idMatch = RegExp(r'''modId\s*=\s*"([^"]+)"''').firstMatch(text);
        return (modId: idMatch?.group(1), name: nameMatch?.group(1));
      }
    } catch (e) {
      AppLogger.debug('Mods', '读取 mod 元信息失败: $e');
    }
    return (modId: null, name: null);
  }
}
