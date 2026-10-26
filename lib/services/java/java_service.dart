import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;

/// Java 运行时服务：检测 + 智能选择 + 自动安装（Adoptium）。
///
/// 自动安装借鉴 PCL2 2.13 的 Java 管理策略：
/// 缺失所需版本时自动从 Adoptium 下载 JRE 并托管到
/// `<gameDir>/runtime/java-<major>`，供所有版本共享。
class JavaService {
  JavaService(this._ref);

  final Ref _ref;
  List<rust.JavaInfo>? _cache;

  AppSettings get _settings => _ref.read(appSettingsProvider);

  /// 全量检测（扫描 + 探测版本）
  Future<List<rust.JavaInfo>> detectAll({bool force = false}) async {
    if (!force && _cache != null) return _cache!;

    if (!rust.rustBridgeAvailable) {
      // Android 桩：无法扫描与执行
      // TODO(ANDROID)：对接移动端 JRE 探测方案，见 TODO.md #A-05
      throw const PlatformUnsupportedException(
        '当前平台暂不支持 Java 自动检测',
        todoRef: 'TODO.md #A-05',
      );
    }

    final candidates = await rust.findJavaCandidates(
      extraDirs: _settings.javaSearchPaths,
    );
    final infos = <rust.JavaInfo>[];
    for (final candidate in candidates) {
      try {
        final info = await rust.probeJava(javaPath: candidate);
        infos.add(info);
      } catch (e) {
        AppLogger.debug('Java', '探测失败 $candidate: $e');
      }
    }
    // 版本降序
    infos.sort((a, b) => b.majorVersion.compareTo(a.majorVersion));
    _cache = infos;
    AppLogger.info('Java', '检测到 ${infos.length} 个 Java 运行时');
    return infos;
  }

  /// 为指定主版本选择最合适的 Java。
  ///
  /// 规则（PCL2 式）：
  /// 1. 版本覆盖的 javaPath（若有效）优先于全局手动指定
  /// 2. 全局手动指定的 javaPath 优先（若可执行）
  /// 3. 版本恰好匹配优先
  /// 4. 向上兼容（>= required 的最小版本）
  /// 5. 全部缺失时：若 [autoInstall] 且全局设置允许，自动从 Adoptium 安装
  Future<rust.JavaInfo> pickJava(
    int requiredMajor, {
    String? overrideJavaPath,
    bool autoInstall = false,
  }) async {
    // 版本覆盖 Java 优先
    final override = overrideJavaPath;
    if (override != null && override.isNotEmpty) {
      if (File(override).existsSync()) {
        try {
          return await rust.probeJava(javaPath: override);
        } catch (_) {
          /* 覆盖无效，回退自动选择 */
          AppLogger.warn('Java', '版本覆盖 Java 无效，回退自动选择: $override');
        }
      } else {
        throw JavaException(
          '版本设置的 Java 路径无效: $override',
          suggestions: [
            const FixSuggestion(
              '修改版本设置',
              '在「版本管理 → 版本设置」中清除或更正该版本的 Java 路径。',
              actionId: 'open_version_settings',
            ),
          ],
        );
      }
    }

    // 用户指定优先
    final manual = _settings.javaPath;
    if (manual.isNotEmpty) {
      final file = File(manual);
      if (file.existsSync()) {
        try {
          return await rust.probeJava(javaPath: manual);
        } catch (_) {/* 回退自动选择 */}
      } else {
        throw JavaException(
          '指定的 Java 路径无效: $manual',
          suggestions: [
            const FixSuggestion(
              '清除手动配置',
              '在 设置 → Java 中清除无效路径，或重新选择有效路径。',
              actionId: 'open_java_settings',
            ),
          ],
        );
      }
    }

    final all = await detectAll();
    final selected = _selectFrom(all, requiredMajor);
    if (selected != null) return selected;

    // ---------- 自动安装（PCL2 式）----------
    if (autoInstall && _settings.autoInstallJava) {
      AppLogger.info('Java', '未找到 Java $requiredMajor，尝试自动安装...');
      final installed = await installJava(requiredMajor);
      if (installed != null) return installed;
    }

    throw JavaException(
      '未找到可用的 Java 运行时（需要 Java $requiredMajor）',
      suggestions: [
        if (_settings.autoInstallJava)
          FixSuggestion(
            '自动安装 Java $requiredMajor',
            'FMCL 将从 Adoptium (Eclipse Temurin) 下载官方 JRE 并托管，'
                '也可在 设置 → Java 中关闭此行为。',
            actionId: 'install_java_$requiredMajor',
          ),
        const FixSuggestion(
          '手动指定 Java',
          '前往 adoptium.net 下载对应版本，然后在 设置 → Java 中指定路径。',
          actionId: 'open_java_settings',
        ),
      ],
    );
  }

  /// 从候选列表中选择最合适的 Java（精确 → 向上兼容 → 同版本 32 位 → 最高）
  rust.JavaInfo? _selectFrom(List<rust.JavaInfo> all, int requiredMajor) {
    if (all.isEmpty) return null;
    for (final info in all) {
      if (info.majorVersion == requiredMajor && info.is64Bit) return info;
    }
    for (final info in all) {
      if (info.majorVersion > requiredMajor && info.is64Bit) return info;
    }
    for (final info in all) {
      if (info.majorVersion == requiredMajor) return info;
    }
    return all.first;
  }

  /// 自动安装指定主版本的 Java（Adoptium JRE）。
  ///
  /// 返回安装后的 JavaInfo；失败返回 null（进度/错误通过 [onProgress] 回传）。
  Future<rust.JavaInfo?> installJava(
    int major, {
    void Function(String phase, String message, double? progress)? onProgress,
  }) async {
    if (!rust.rustBridgeAvailable) {
      throw const PlatformUnsupportedException(
        '当前平台暂不支持 Java 自动安装',
        todoRef: 'TODO.md #A-02',
      );
    }
    final gameDir = _settings.gameDirectory;
    final runtimeRoot = p.join(gameDir, 'runtime');
    final sessionId = await rust.createDownloadSession();
    try {
      final stream = rust.installJava(
        major: major,
        runtimeRoot: runtimeRoot,
        sessionId: sessionId,
      );
      await for (final event in stream) {
        onProgress?.call(event.phase, event.message, event.progress);
        AppLogger.debug('Java', '[${event.phase}] ${event.message}');
        if (event.phase == 'failed') {
          AppLogger.error('Java', '自动安装失败: ${event.message}');
          return null;
        }
      }
    } finally {
      rust.disposeDownloadSession(sessionId: sessionId);
    }

    // 安装完成后探测
    invalidate();
    final exe = p.join(
        runtimeRoot, 'java-$major', 'bin', Platform.isWindows ? 'java.exe' : 'java');
    if (!File(exe).existsSync()) {
      AppLogger.error('Java', '安装完成但未找到 java 可执行文件: $exe');
      return null;
    }
    final info = await rust.probeJava(javaPath: exe);
    _cache = [...?_cache, info]..sort((a, b) => b.majorVersion.compareTo(a.majorVersion));
    AppLogger.info('Java', 'Java ${info.versionString} 自动安装完成: $exe');
    return info;
  }

  /// 清空缓存
  void invalidate() => _cache = null;
}

/// Java 服务实例
final javaServiceProvider = Provider<JavaService>(JavaService.new);

/// 目录下可执行文件名工具
String javaExecutableIn(String javaHome) {
  final bin = p.join(javaHome, 'bin');
  return Platform.isWindows ? p.join(bin, 'java.exe') : p.join(bin, 'java');
}
