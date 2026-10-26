import 'dart:convert';
import 'dart:io';

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/game_version.dart';
import '../../services/download/http_service.dart';
import 'package:path/path.dart' as p;

/// 版本仓库：负责版本清单获取与本地版本 JSON 的解析。
class VersionRepository {
  VersionRepository._();
  static final VersionRepository instance = VersionRepository._();
  static VersionRepository get I => instance;

  static const String _manifestCacheFile = 'version_manifest_v2.json';
  static const Duration _manifestCacheTtl = Duration(minutes: 30);

  DateTime? _manifestFetchedAt;
  Map<String, dynamic>? _cachedManifest;

  /// 获取版本清单（带内存缓存 + 磁盘缓存 + 双源回退）
  Future<dynamic> fetchManifest({bool forceRefresh = false}) async {
    // 内存缓存
    if (!forceRefresh &&
        _cachedManifest != null &&
        _manifestFetchedAt != null &&
        DateTime.now().difference(_manifestFetchedAt!) < _manifestCacheTtl) {
      return _cachedManifest!;
    }

    // 磁盘缓存
    final cachePath = await _manifestCachePath();
    if (!forceRefresh && cachePath != null) {
      final f = File(cachePath);
      if (f.existsSync()) {
        final age = DateTime.now().difference(f.lastModifiedSync());
        if (age < _manifestCacheTtl * 4) {
          try {
            return jsonDecode(f.readAsStringSync());
          } catch (_) {
            f.deleteSync();
          }
        }
      }
    }

    final data = await HttpService.I.getJsonWithFallback(
      _manifestUrl,
      mapThroughSource: false,
    );
    _cachedManifest = data as Map<String, dynamic>;
    _manifestFetchedAt = DateTime.now();
    if (cachePath != null) {
      try {
        File(cachePath).writeAsStringSync(jsonEncode(data));
      } catch (e) {
        AppLogger.warn('VersionRepo', '写清单缓存失败: $e');
      }
    }
    return data;
  }

  String get _manifestUrl => HttpService.I.primarySource.versionManifestUrl;

  /// 获取指定版本的完整版本 JSON（自动沿 inheritsFrom 链合并解析）
  Future<GameVersionJson> fetchVersionJson(String versionId, String gameDir) async {
    final versionsDir = Directory(p.join(gameDir, 'versions', versionId));
    final jsonFile = File(p.join(versionsDir.path, '$versionId.json'));

    Map<String, dynamic> json;
    if (jsonFile.existsSync()) {
      try {
        json = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      } catch (e) {
        throw ParseException('版本 JSON 损坏: $versionId', technicalDetail: e.toString());
      }
    } else {
      // 从清单找到 URL 下载
      final manifest = await fetchManifest();
      final entries = (manifest['versions'] as List<dynamic>? ?? []);
      final entry = entries.firstWhere(
        (e) => (e as Map<String, dynamic>)['id'] == versionId,
        orElse: () => null,
      );
      if (entry == null) {
        throw ParseException('版本清单中不存在: $versionId');
      }
      final url = (entry as Map<String, dynamic>)['url'] as String;
      json = await HttpService.I.getJsonWithFallback(url, mapThroughSource: true);
      // 落盘
      if (!versionsDir.existsSync()) versionsDir.createSync(recursive: true);
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    }

    return GameVersionJson.fromJson(json);
  }

  /// 沿 inheritsFrom 递归解析出完整继承链（子 → 父顺序）
  Future<List<GameVersionJson>> resolveChain(
    GameVersionJson leaf,
    String gameDir,
  ) async {
    final chain = <GameVersionJson>[leaf];
    var current = leaf;
    var guard = 0;
    while (current.inheritsFrom != null && guard < 16) {
      guard++;
      final parent = await fetchVersionJson(current.inheritsFrom!, gameDir);
      chain.insert(0, parent);
      current = parent;
    }
    if (current.inheritsFrom != null) {
      throw const ParseException('版本继承链过深，可能存在循环引用');
    }
    return chain;
  }

  Future<String?> _manifestCachePath() async {
    try {
      final dir = Directory.systemTemp.path;
      return p.join(dir, 'fmcl_cache_$_manifestCacheFile');
    } catch (_) {
      return null;
    }
  }
}
