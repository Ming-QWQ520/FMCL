import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';

/// 每版本独立设置（借鉴 PCL2「版本设置」：全局继承 + 局部覆盖）。
///
/// 持久化到 `versions/<id>/fmcl-settings.json`。
/// 各字段为 null 时表示「跟随全局设置」。
class VersionSettings {
  /// 版本隔离覆盖（null = 跟随全局）
  final bool? isolation;

  /// Java 可执行文件覆盖（null/空 = 跟随全局）
  final String? javaPath;

  /// 最大内存覆盖（MiB，null 或 0 = 跟随全局）
  final int? maxMemoryMb;

  /// 最小内存覆盖（MiB，null 或 0 = 跟随全局）
  final int? minMemoryMb;

  /// 额外 JVM 参数（叠加在全局之后）
  final String? jvmArguments;

  const VersionSettings({
    this.isolation,
    this.javaPath,
    this.maxMemoryMb,
    this.minMemoryMb,
    this.jvmArguments,
  });

  static const VersionSettings empty = VersionSettings();

  /// 持久化文件名（位于 `versions/<版本id>/` 目录内）
  static const String fileName = 'fmcl-settings.json';

  bool get isEmpty =>
      isolation == null &&
      (javaPath == null || javaPath!.isEmpty) &&
      (maxMemoryMb == null || maxMemoryMb == 0) &&
      (minMemoryMb == null || minMemoryMb == 0) &&
      (jvmArguments == null || jvmArguments!.isEmpty);

  VersionSettings copyWith({
    bool? isolation,
    String? javaPath,
    int? maxMemoryMb,
    int? minMemoryMb,
    String? jvmArguments,
  }) {
    return VersionSettings(
      isolation: isolation ?? this.isolation,
      javaPath: javaPath ?? this.javaPath,
      maxMemoryMb: maxMemoryMb ?? this.maxMemoryMb,
      minMemoryMb: minMemoryMb ?? this.minMemoryMb,
      jvmArguments: jvmArguments ?? this.jvmArguments,
    );
  }

  Map<String, dynamic> toJson() => {
        if (isolation != null) 'isolation': isolation,
        if (javaPath != null && javaPath!.isNotEmpty) 'javaPath': javaPath,
        if (maxMemoryMb != null && maxMemoryMb != 0) 'maxMemoryMb': maxMemoryMb,
        if (minMemoryMb != null && minMemoryMb != 0) 'minMemoryMb': minMemoryMb,
        if (jvmArguments != null && jvmArguments!.isNotEmpty)
          'jvmArguments': jvmArguments,
      };

  factory VersionSettings.fromJson(Map<String, dynamic> json) {
    return VersionSettings(
      isolation: json['isolation'] as bool?,
      javaPath: json['javaPath'] as String?,
      maxMemoryMb: json['maxMemoryMb'] as int?,
      minMemoryMb: json['minMemoryMb'] as int?,
      jvmArguments: json['jvmArguments'] as String?,
    );
  }
}

/// 启动时实际生效的配置（全局 + 版本覆盖合并结果）。
class EffectiveLaunchConfig {
  /// 该版本的工作目录（隔离时为 `versions/<id>`，否则为游戏根目录）
  final String workDir;

  /// assets 目录（始终位于根目录，多版本共享）
  final String assetsDir;

  /// libraries 目录（始终位于根目录）
  final String librariesDir;

  /// 是否隔离
  final bool isolated;

  /// 版本级 Java 路径覆盖（空 = 跟随全局手动指定或自动选择；
  /// 全局手动路径由 JavaService.pickJava 内部处理，避免错误提示语义混淆）
  final String javaPath;

  /// 生效的内存参数
  final int minMemoryMb;
  final int maxMemoryMb;

  /// 叠加后的额外 JVM 参数
  final String jvmArguments;

  const EffectiveLaunchConfig({
    required this.workDir,
    required this.assetsDir,
    required this.librariesDir,
    required this.isolated,
    required this.javaPath,
    required this.minMemoryMb,
    required this.maxMemoryMb,
    required this.jvmArguments,
  });
}

/// 版本设置服务。
class VersionSettingsService {
  VersionSettingsService._();
  static final VersionSettingsService instance = VersionSettingsService._();
  static VersionSettingsService get I => instance;

  final Map<String, VersionSettings> _cache = {};

  /// 设置文件路径
  String _settingsPath(String gameDir, String versionId) =>
      p.join(gameDir, 'versions', versionId, VersionSettings.fileName);

  /// 读取版本设置（文件缺失返回 empty）
  Future<VersionSettings> load(String gameDir, String versionId) async {
    final key = '$gameDir/$versionId';
    if (_cache.containsKey(key)) return _cache[key]!;
    final f = File(_settingsPath(gameDir, versionId));
    if (!f.existsSync()) {
      _cache[key] = VersionSettings.empty;
      return VersionSettings.empty;
    }
    try {
      final json =
          jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final s = VersionSettings.fromJson(json);
      _cache[key] = s;
      return s;
    } catch (e) {
      AppLogger.warn('VersionSettings', '解析版本设置失败 $versionId: $e');
      return VersionSettings.empty;
    }
  }

  /// 同步读取（UI 快捷方式，无缓存时读盘）
  VersionSettings loadSync(String gameDir, String versionId) {
    final key = '$gameDir/$versionId';
    if (_cache.containsKey(key)) return _cache[key]!;
    final f = File(_settingsPath(gameDir, versionId));
    if (!f.existsSync()) return VersionSettings.empty;
    try {
      final json =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final s = VersionSettings.fromJson(json);
      _cache[key] = s;
      return s;
    } catch (_) {
      return VersionSettings.empty;
    }
  }

  /// 保存版本设置
  Future<void> save(
      String gameDir, String versionId, VersionSettings s) async {
    final key = '$gameDir/$versionId';
    _cache[key] = s;
    final f = File(_settingsPath(gameDir, versionId));
    if (s.isEmpty) {
      if (f.existsSync()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f
        .writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  }

  /// 使缓存失效（删除版本 / 刷新时）
  void invalidate(String gameDir, String versionId) {
    _cache.remove('$gameDir/$versionId');
  }

  /// 合并全局与版本设置，得到启动实际生效配置。
  ///
  /// 隔离规则（PCL2 式）：
  /// - 生效隔离 = 版本覆盖 ?? 全局开关
  /// - 隔离时：workDir = `versions/<id>`，saves/config/options.txt/mods 均落在其中
  /// - libraries 与 assets 始终使用根目录（多版本共享，节省磁盘）
  EffectiveLaunchConfig resolve(
    AppSettings global,
    String gameDir,
    String versionId,
    VersionSettings override,
  ) {
    final isolated = override.isolation ?? global.versionIsolation;
    final workDir = isolated
        ? p.join(gameDir, 'versions', versionId)
        : gameDir;
    return EffectiveLaunchConfig(
      workDir: workDir,
      assetsDir: p.join(gameDir, 'assets'),
      librariesDir: p.join(gameDir, 'libraries'),
      isolated: isolated,
      javaPath: (override.javaPath?.isNotEmpty ?? false)
          ? override.javaPath!
          : '',
      minMemoryMb: (override.minMemoryMb ?? 0) > 0
          ? override.minMemoryMb!
          : global.minMemoryMb,
      maxMemoryMb: (override.maxMemoryMb ?? 0) > 0
          ? override.maxMemoryMb!
          : global.maxMemoryMb,
      jvmArguments: [
        if (global.jvmArguments.trim().isNotEmpty) global.jvmArguments.trim(),
        if (override.jvmArguments?.trim().isNotEmpty ?? false)
          override.jvmArguments!.trim(),
      ].join(' '),
    );
  }

  /// 该版本的 mods 目录（随隔离变化）
  String modsDirFor(
      AppSettings global, String gameDir, String versionId) {
    final s = loadSync(gameDir, versionId);
    final isolated = s.isolation ?? global.versionIsolation;
    return isolated
        ? p.join(gameDir, 'versions', versionId, 'mods')
        : p.join(gameDir, 'mods');
  }

  /// 该版本的任意子目录（随隔离变化）。
  ///
  /// 借鉴 PCL2「版本隔离」的统一推广：mods / shaderpacks / resourcepacks /
  /// saves / config 等均落在生效游戏目录内。
  String dirFor(
      AppSettings global, String gameDir, String versionId, String sub) {
    final s = loadSync(gameDir, versionId);
    final isolated = s.isolation ?? global.versionIsolation;
    return isolated
        ? p.join(gameDir, 'versions', versionId, sub)
        : p.join(gameDir, sub);
  }
}

/// Provider
final versionSettingsProvider = Provider<VersionSettingsService>(
    (ref) => VersionSettingsService.I);
