import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/logger/app_logger.dart';

/// 本地版本管理。
class LocalVersionManager {
  LocalVersionManager._();
  static final LocalVersionManager instance = LocalVersionManager._();
  static LocalVersionManager get I => instance;

  /// 列出本地已安装版本（有 .json 且可解析的）
  Future<List<LocalVersion>> listVersions(String gameDir) async {
    final dir = Directory(p.join(gameDir, 'versions'));
    if (!dir.existsSync()) return [];
    final result = <LocalVersion>[];
    for (final sub in dir.listSync()) {
      if (sub is! Directory) continue;
      final id = p.basename(sub.path);
      final jsonFile = File(p.join(sub.path, '$id.json'));
      final jarFile = File(p.join(sub.path, '$id.jar'));
      if (!jsonFile.existsSync()) continue;
      try {
        // 基本合法性检查
        final content = jsonFile.readAsStringSync();
        if (!content.contains('"id"')) continue;
        result.add(LocalVersion(
          id: id,
          jsonPath: jsonFile.path,
          jarPath: jarFile.existsSync() ? jarFile.path : null,
          lastModified: jsonFile.lastModifiedSync(),
        ));
      } catch (e) {
        AppLogger.warn('VersionMgr', '跳过损坏版本 $id: $e');
      }
    }
    result.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return result;
  }

  /// 删除版本（含 jar 与 json）
  Future<void> removeVersion(String gameDir, String versionId) async {
    final dir = Directory(p.join(gameDir, 'versions', versionId));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      AppLogger.info('VersionMgr', '已删除版本 $versionId');
    }
  }

  /// 版本是否完整（json + jar）
  Future<bool> isVersionComplete(String gameDir, String versionId) async {
    final base = p.join(gameDir, 'versions', versionId);
    return File(p.join(base, '$versionId.json')).existsSync() &&
        File(p.join(base, '$versionId.jar')).existsSync();
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
}

/// 本地版本条目
class LocalVersion {
  final String id;
  final String jsonPath;
  final String? jarPath;
  final DateTime lastModified;

  const LocalVersion({
    required this.id,
    required this.jsonPath,
    this.jarPath,
    required this.lastModified,
  });

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
