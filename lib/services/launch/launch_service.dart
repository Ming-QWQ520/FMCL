import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/game_account.dart';
import '../../data/models/game_version.dart';
import '../../data/models/asset_index.dart';
import '../../data/models/app_settings.dart';
import '../../data/sources/download_source.dart';
import '../../providers/account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../account/yggdrasil_auth.dart';
import '../download/download_manager.dart';
import '../java/java_service.dart';
import '../version/version_repository.dart';
import '../version/version_settings.dart';
import 'argument_builder.dart';
import 'crash_analyzer.dart';

/// 启动阶段
enum LaunchPhase {
  idle,
  preparing,
  downloading,
  extracting,
  buildingArgs,
  launching,
  running,
  exited,
  failed,
}

/// 启动状态
class LaunchState {
  final LaunchPhase phase;
  final String message;
  final double? progress;
  final int? handleId;
  final List<String> recentLogs;
  final CrashReport? crashReport;
  final String? versionId;
  final DateTime? startedAt;

  const LaunchState({
    this.phase = LaunchPhase.idle,
    this.message = '',
    this.progress,
    this.handleId,
    this.recentLogs = const [],
    this.crashReport,
    this.versionId,
    this.startedAt,
  });

  bool get isRunning => phase == LaunchPhase.running;

  LaunchState copyWith({
    LaunchPhase? phase,
    String? message,
    double? progress,
    int? handleId,
    List<String>? recentLogs,
    CrashReport? crashReport,
    String? versionId,
    DateTime? startedAt,
  }) {
    return LaunchState(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      progress: progress ?? this.progress,
      handleId: handleId ?? this.handleId,
      recentLogs: recentLogs ?? this.recentLogs,
      crashReport: crashReport ?? this.crashReport,
      versionId: versionId ?? this.versionId,
      startedAt: startedAt ?? this.startedAt,
    );
  }
}

/// 启动会话（多实例：每次启动一个独立会话）
class LaunchSession {
  final int id;
  final LaunchState state;

  const LaunchSession({required this.id, required this.state});

  bool get isActive =>
      state.phase == LaunchPhase.running ||
      state.phase == LaunchPhase.launching ||
      state.phase == LaunchPhase.preparing ||
      state.phase == LaunchPhase.downloading ||
      state.phase == LaunchPhase.extracting ||
      state.phase == LaunchPhase.buildingArgs;
}

/// 启动服务：完整启动管线（支持多实例并发启动）。
///
/// ```
/// 准备账户 → 解析版本链 → 补全文件(库/natives/assets/日志配置)
/// → 解压 natives → 构建参数 → 启动进程 → 监控日志 → 退出码分析
/// ```
class LaunchService {
  LaunchService(this._ref);

  final Ref _ref;
  static const int _maxLogLines = 400;

  /// 会话注册表：sessionId → 当前状态
  final Map<int, LaunchState> _sessions = {};
  int _nextSessionId = 1;
  int _primarySessionId = 0;

  LaunchState get _state => _ref.read(launchStateProvider);

  void _update(int sessionId, LaunchState Function(LaunchState) mutator) {
    final current = _sessions[sessionId];
    if (current == null) return;
    final next = mutator(current);
    _sessions[sessionId] = next;
    _syncSessions();
    // 主会话（最近一次启动）同步到旧 launchStateProvider，保持既有 UI 兼容
    if (sessionId == _primarySessionId) {
      _ref.read(launchStateProvider.notifier).set(next);
    }
  }

  void _syncSessions() {
    final list = _sessions.entries
        .map((e) => LaunchSession(id: e.key, state: e.value))
        .toList(growable: false);
    _ref.read(launchSessionsProvider.notifier).setAll(list);
  }

  /// 终止指定会话对应的游戏进程
  Future<void> terminateSession(int sessionId) async {
    final st = _sessions[sessionId];
    final handle = st?.handleId;
    if (handle == null) return;
    try {
      await rust.killGameProcess(handleId: handle);
      AppLogger.info('Launch', '已请求终止会话 #$sessionId (handle=$handle)');
    } catch (e) {
      AppLogger.warn('Launch', '终止会话 #$sessionId 失败: $e');
    }
  }

  /// 启动指定版本（多实例：可同时启动多个不同/相同版本）
  Future<void> launch(String versionId) async {
    final sessionId = _nextSessionId++;
    _sessions[sessionId] = LaunchState(
      phase: LaunchPhase.preparing,
      message: '准备启动 $versionId...',
      versionId: versionId,
      startedAt: DateTime.now(),
    );
    _primarySessionId = sessionId;
    _ref
        .read(launchStateProvider.notifier)
        .set(_sessions[sessionId]!);
    _syncSessions();

    try {
      // ---------- 1. 平台检查 ----------
      _checkPlatform();

      // ---------- 2. 账户 ----------
      final account = await _prepareAccount();
      AppLogger.info('Launch', '使用账户: ${account.name} (${account.typeLabel})');

      // ---------- 3. 解析版本链 ----------
      _update(sessionId, (s) => s.copyWith(message: '解析版本依赖链...'));
      final settings = _ref.read(appSettingsProvider);
      final gameDir = settings.gameDirectory;
      // 版本设置（PCL2 式：全局继承 + 每版本覆盖，决定隔离目录与 Java/内存）
      final vOverride = await VersionSettingsService.I.load(gameDir, versionId);
      final effective =
          VersionSettingsService.I.resolve(settings, gameDir, versionId, vOverride);
      AppLogger.info(
          'Launch',
          '版本设置: 隔离=${effective.isolated} workDir=${effective.workDir}');
      final leaf = await VersionRepository.I.fetchVersionJson(versionId, gameDir);
      final chain = await VersionRepository.I.resolveChain(leaf, gameDir);
      final merged = _mergeChain(chain);
      AppLogger.info('Launch', '版本链: ${chain.map((c) => c.id).join(' ← ')}');

      // ---------- 4. 补全文件 ----------
      final missing = await _collectMissingFiles(merged, gameDir);
      if (missing.isNotEmpty) {
        _update(sessionId, (s) => s.copyWith(
              phase: LaunchPhase.downloading,
              message: '补全游戏文件（${missing.length} 个）...',
              progress: 0,
            ));
        await _downloadMissing(sessionId, missing);
      }

      // ---------- 5. 解压 natives ----------
      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.extracting,
            message: '解压本地库...',
          ));
      final nativesDir = await _extractNatives(merged, gameDir);

      // ---------- 6. Java ----------
      _update(sessionId, (s) => s.copyWith(message: '选择 Java 运行时...'));
      final requiredJava = merged.javaVersion?.majorVersion ?? _guessJavaMajor(gameDir, versionId);
      final javaService = _ref.read(javaServiceProvider);
      final javaInfo = await javaService.pickJava(
        requiredJava,
        overrideJavaPath: effective.javaPath,
        autoInstall: true,
      );
      AppLogger.info(
          'Launch', 'Java: ${javaInfo.versionString} (${javaInfo.vendor})');

      // ---------- 7. Yggdrasil 令牌续期 + authlib-injector ----------
      String authlibArg = '';
      if (account.type == AccountType.yggdrasil) {
        authlibArg = await _prepareAuthlibInjector(sessionId, account);
      }

      // ---------- 8. 构建参数 ----------
      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.buildingArgs,
            message: '构建启动参数...',
          ));
      // 版本设置覆盖内存/JVM 参数后传入构建器
      final mergedSettings = settings.copyWith(
        minMemoryMb: effective.minMemoryMb,
        maxMemoryMb: effective.maxMemoryMb,
        jvmArguments: effective.jvmArguments,
      );
      final jvmArgs = _buildJvmArgs(
        merged: merged,
        chain: chain,
        gameDir: gameDir,
        nativesDir: nativesDir,
        settings: mergedSettings,
        authlibArg: authlibArg,
      );
      final gameArgs = LaunchArgumentsBuilder.buildGameArgs(
        inheritedGameArgs: _collectGameArgs(chain),
        legacyMinecraftArguments: merged.minecraftArguments ?? '',
        account: account,
        versionId: merged.id,
        gameDir: effective.workDir,
        assetsDir: effective.assetsDir,
        assetsIndexId: merged.assetIndex?.id ?? merged.assets ?? '',
        settings: mergedSettings,
        fullscreen: settings.fullscreen,
      );

      // ---------- 9. 启动进程 ----------
      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.launching,
            message: '启动 Minecraft...',
          ));

      final logFile = File(p.join(gameDir, 'logs', 'fmcl',
          'game-${DateTime.now().millisecondsSinceEpoch}.log'));
      if (!logFile.parent.existsSync()) logFile.parent.createSync(recursive: true);
      final logSink = logFile.openWrite();

      final config = rust.ProcessSpawnConfig(
        program: javaInfo.javaPath,
        args: [...jvmArgs, merged.mainClass, ...gameArgs],
        workingDir: effective.workDir,
        env: {},
      );
      final handle = await rust.spawnGameProcess(config: config);
      final stream = rust.attachOutputStream(handleId: handle);

      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.running,
            message: '游戏运行中',
            handleId: handle,
          ));

      // 监听日志
      final sub = stream.listen((event) {
        logSink.writeln(event.line);
        _appendLog(sessionId, event.line);
        if (event.stream == 'stderr') {
          AppLogger.debug('Game', event.line);
        }
      });

      // 等待退出（不阻塞 launch 方法返回）
      unawaited(_waitExit(sessionId, handle, sub, logSink, versionId));

      // 启动器行为
      _applyLauncherBehavior();
    } on AppException catch (e) {
      AppLogger.error('Launch', '启动失败: ${e.userMessage}', e.technicalDetail);
      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.failed,
            message: e.userMessage,
          ));
      rethrow;
    } catch (e, s) {
      AppLogger.error('Launch', '启动失败（未预期）', e, s);
      _update(sessionId, (s) => s.copyWith(
            phase: LaunchPhase.failed,
            message: '启动失败: $e',
          ));
      throw LaunchException('启动失败: $e', technicalDetail: s.toString());
    }
  }

  /// 平台能力检查
  void _checkPlatform() {
    if (Platform.isAndroid) {
      throw const PlatformUnsupportedException(
        'Android 平台暂不支持启动游戏（进程与 JRE 管理尚未实现）',
        todoRef: 'TODO.md #A-01',
      );
    }
  }

  /// 账户准备（含微软令牌自动刷新）
  Future<GameAccount> _prepareAccount() async {
    await _ref.read(accountsProvider.notifier).refreshIfNeeded();
    final account = _ref.read(currentAccountProvider);
    if (account == null) {
      throw const LaunchException(
        '尚未登录任何账户',
        suggestions: [
          FixSuggestion('添加账户', '在「账户」页添加离线账户或登录微软/外置账户。',
              actionId: 'goto_accounts'),
        ],
      );
    }
    // Yggdrasil 令牌续期
    if (account.type == AccountType.yggdrasil && account.yggdrasilServer != null) {
      // 简单校验，失败则提示重新登录（不中断启动——离线降级由用户决定）
      try {
        final fresh = await YggdrasilAuthService.validateOrRefresh(
          apiRoot: account.yggdrasilServer!,
          accessToken: account.accessToken,
          clientToken: '',
          profileId: account.profileId ?? '',
          profileName: account.name,
        );
        if (fresh != account.accessToken) {
          await _ref.read(accountsProvider.notifier).addYggdrasilAccount(
            serverUrl: account.yggdrasilServer!,
            name: account.name,
            accessToken: fresh,
            uuid: account.uuid,
            profileId: account.profileId ?? '',
            expiresAt: 0,
          );
          final updated = _ref.read(currentAccountProvider);
          return updated ?? account;
        }
      } catch (e) {
        AppLogger.warn('Launch', '外置令牌校验失败（继续以现有令牌启动）: $e');
      }
    }
    return account;
  }

  /// 合并继承链（父→子覆盖）
  GameVersionJson _mergeChain(List<GameVersionJson> chain) {
    final libs = <Library>[];
    final jvmSegments = <List<String>>[];
    final gameSegments = <List<String>>[];
    String? mainClass;
    String? assetsIndex;
    AssetIndexRef? assetIndexRef;
    String? minecraftArguments;
    JavaVersionRef? javaVersion;
    ClientDownloadRef? downloads;
    LoggingConfig? logging;

    for (final v in chain) {
      libs.addAll(v.libraries);
      if (v.arguments != null) {
        jvmSegments.add(_stringifyArgs(v.arguments!.jvm));
        gameSegments.add(_stringifyArgs(v.arguments!.game));
      }
      mainClass = v.mainClass; // 子类覆盖
      if (v.assetIndex != null) assetIndexRef = v.assetIndex;
      if (v.assets != null) assetsIndex = v.assets;
      if (v.minecraftArguments != null) {
        minecraftArguments = v.minecraftArguments;
      }
      if (v.javaVersion != null) javaVersion = v.javaVersion;
      if (v.downloads != null) downloads = v.downloads;
      if (v.logging != null) logging = v.logging;
    }

    return GameVersionJson(
      id: chain.last.id,
      mainClass: mainClass ?? '',
      type: chain.last.type,
      libraries: libs,
      arguments: ArgumentsSet(
        jvm: jvmSegments.expand((e) => e).toList(),
        game: gameSegments.expand((e) => e).toList(),
      ),
      minecraftArguments: minecraftArguments,
      assetIndex: assetIndexRef,
      assets: assetsIndex,
      javaVersion: javaVersion,
      downloads: downloads,
      logging: logging,
      raw: chain.last.raw,
    );
  }

  List<String> _stringifyArgs(List<dynamic> raw) {
    final out = <String>[];
    for (final item in raw) {
      if (item is String) {
        out.add(item);
      } else if (item is Map<String, dynamic>) {
        // 带规则的参数段
        if (_rulesAllow(item['rules'] as List<dynamic>?)) {
          final value = item['value'];
          if (value is String) {
            out.add(value);
          } else if (value is List) {
            out.addAll(value.map((e) => e.toString()));
          }
        }
      }
    }
    return out;
  }

  bool _rulesAllow(List<dynamic>? rules) {
    if (rules == null || rules.isEmpty) return true;
    var allowed = false;
    final osName = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'osx'
            : 'linux';
    final arch = Platform.version.contains('arm64') || Platform.version.contains('aarch64')
        ? 'aarch64'
        : 'x86_64';
    for (final r in rules.cast<Map<String, dynamic>>()) {
      final os = r['os'] as Map<String, dynamic>?;
      final osMatch = os == null ||
          (os['name'] == osName &&
              (os['arch'] == null || os['arch'] == arch));
      if (!osMatch) continue;
      if (r['action'] == 'allow') allowed = true;
      if (r['action'] == 'disallow') allowed = false;
    }
    return allowed;
  }

  List<List<String>> _collectGameArgs(List<GameVersionJson> chain) {
    return chain
        .where((v) => v.arguments != null)
        .map((v) => _stringifyArgs(v.arguments!.game))
        .toList();
  }

  List<List<String>> _collectJvmArgs(List<GameVersionJson> chain) {
    return chain
        .where((v) => v.arguments != null)
        .map((v) => _stringifyArgs(v.arguments!.jvm))
        .toList();
  }

  int _guessJavaMajor(String gameDir, String versionId) {
    // 从版本 JSON 的 javaVersion 读取（mergeChain 已处理）；此处兜底
    return 8;
  }

  // ---------------- 文件补全 ----------------

  Future<List<DownloadTask>> _collectMissingFiles(
    GameVersionJson merged,
    String gameDir,
  ) async {
    final tasks = <DownloadTask>[];
    final librariesDir = p.join(gameDir, 'libraries');
    final source = _primarySource();

    // 1. 客户端 jar（原版层）：由后续统一检查（继承链原版 jar 在库下载前已确保）

    // 2. 库文件
    for (final lib in merged.libraries) {
      final osName = Platform.isWindows
          ? 'windows'
          : Platform.isMacOS
              ? 'osx'
              : 'linux';
      final arch = Platform.operatingSystemVersion.contains('arm') ? 'aarch64' : 'x86_64';
      if (!lib.isAllowedOn(osName, arch)) continue;

      final artifact = lib.downloads?.artifact;
      if (artifact != null && artifact.url.isNotEmpty) {
        final savePath = p.join(librariesDir, artifact.path ?? lib.path);
        tasks.add(DownloadTask(
          url: source.mapUrl(artifact.url),
          savePath: savePath,
          sha1: settingsOf(_ref).verifyFiles ? artifact.sha1 : null,
          size: artifact.size,
        ));
      } else if (lib.downloads?.artifact == null) {
        // maven 布局推导（Forge 库等）
        final base = lib.url ??
            (source.kind == DownloadSourceKind.bmclapi
                ? AppConstants.bmclapiLibraries
                : AppConstants.officialLibraries);
        tasks.add(DownloadTask(
          url: source.mapUrl('$base/${lib.path}'),
          savePath: p.join(librariesDir, lib.path),
        ));
      }

      // natives 分类器
      if (lib.natives != null) {
        final classifier = lib.nativeClassifierFor(osName, arch);
        if (classifier != null) {
          final nativeFile = lib.downloads?.classifiers[classifier];
          if (nativeFile != null) {
            final savePath = p.join(
                librariesDir, nativeFile.path ?? '${lib.path}.$classifier');
            tasks.add(DownloadTask(
              url: source.mapUrl(nativeFile.url),
              savePath: savePath,
              sha1: settingsOf(_ref).verifyFiles ? nativeFile.sha1 : null,
              size: nativeFile.size,
            ));
          }
        }
      }
    }

    // 3. assets 索引与资源
    final assetIndexRef = merged.assetIndex;
    if (assetIndexRef != null) {
      final indexSavePath = p.join(
          gameDir, 'assets', 'indexes', '${assetIndexRef.id}.json');
      tasks.add(DownloadTask(
        url: source.mapUrl(assetIndexRef.url),
        savePath: indexSavePath,
        sha1: assetIndexRef.sha1,
        size: assetIndexRef.size,
      ));

      if (File(indexSavePath).existsSync()) {
        try {
          final indexJson = await _readAssetIndex(indexSavePath);
          final objectsBase = source.kind == DownloadSourceKind.bmclapi
              ? AppConstants.bmclapiResources
              : AppConstants.officialResources;
          for (final obj in indexJson.values) {
            final savePath = p.join(gameDir, 'assets', obj.storePath);
            tasks.add(DownloadTask(
              url: '$objectsBase/${obj.urlPath}',
              savePath: savePath,
              sha1: obj.hash,
              size: obj.size,
            ));
          }
        } catch (e) {
          AppLogger.warn('Launch', '资源索引解析失败（启动时重新下载）: $e');
        }
      }
    }

    // 4. 日志配置（log4j）
    final loggingFile = merged.logging?.clientFile;
    if (loggingFile != null && loggingFile.url.isNotEmpty) {
      final savePath = p.join(
          gameDir, 'assets', 'log_configs', loggingFile.path?.split('/').last ?? 'client.xml');
      tasks.add(DownloadTask(
        url: source.mapUrl(loggingFile.url),
        savePath: savePath,
        sha1: loggingFile.sha1,
        size: loggingFile.size,
      ));
    }

    // 过滤已存在且校验通过的
    final filtered = <DownloadTask>[];
    for (final t in tasks) {
      final f = File(t.savePath);
      if (!f.existsSync()) {
        filtered.add(t);
        continue;
      }
      if (t.size != null && t.size! > 0 && f.lengthSync() != t.size) {
        filtered.add(t);
        continue;
      }
      if (settingsOf(_ref).verifyFiles && t.sha1 != null && t.sha1!.isNotEmpty) {
        try {
          final sha = await rust.fileSha1(path: t.savePath);
          if (sha != t.sha1) {
            filtered.add(t);
          }
        } catch (_) {
          filtered.add(t);
        }
      }
    }
    AppLogger.info('Launch', '需补全文件: ${filtered.length}/${tasks.length}');
    return filtered;
  }

  Future<Map<String, AssetObject>> _readAssetIndex(String path) async {
    final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final objects = (json['objects'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(
          k, AssetObject(hash: v['hash'] as String, size: v['size'] as int? ?? 0)),
    );
    return objects;
  }

  Future<void> _downloadMissing(int sessionId, List<DownloadTask> tasks) async {
    // 走 DownloadManager（Rust 引擎）
    await _ref.read(downloadManagerForLaunchProvider).downloadAll(
      tasks,
      onProgress: (state) {
        _update(sessionId, (s) => s.copyWith(
              progress: state.progress,
              message:
                  '补全游戏文件 ${state.finishedFiles}/${state.totalFiles}',
            ));
      },
    );
    final st = _ref.read(downloadStateProvider);
    if (st.phase == DownloadPhase.failed) {
      throw NetworkException('游戏文件下载失败: ${st.lastError ?? '未知'}');
    }
  }

  // ---------------- natives ----------------

  Future<String> _extractNatives(GameVersionJson merged, String gameDir) async {
    final versionId = merged.id;
    final nativesDir = p.join(gameDir, 'versions', versionId, 'natives');
    Directory(nativesDir).createSync(recursive: true);
    final librariesDir = p.join(gameDir, 'libraries');

    final osName = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'osx'
            : 'linux';
    final arch = Platform.operatingSystemVersion.contains('arm') ? 'aarch64' : 'x86_64';

    for (final lib in merged.libraries) {
      if (lib.natives == null) continue;
      if (!lib.isAllowedOn(osName, arch)) continue;
      final classifier = lib.nativeClassifierFor(osName, arch);
      if (classifier == null) continue;
      final nativeFile = lib.downloads?.classifiers[classifier];
      if (nativeFile == null) continue;

      final jarPath = p.join(
          librariesDir, nativeFile.path ?? '${lib.path}.$classifier');
      if (!File(jarPath).existsSync()) {
        throw VerifyException('natives 库缺失: ${lib.name}');
      }
      try {
        await rust.extractNatives(
          jarPath: jarPath,
          destDir: nativesDir,
          excludePrefixes: lib.extract?.exclude ?? ['META-INF/'],
          onlyNativeLib: false,
        );
      } catch (e) {
        throw FileSystemException('解压 natives 失败: ${lib.name}',
            technicalDetail: e.toString());
      }
    }
    return nativesDir;
  }

  // ---------------- authlib-injector ----------------

  Future<String> _prepareAuthlibInjector(int sessionId, GameAccount account) async {
    final gameDir = _ref.read(appSettingsProvider).gameDirectory;
    final jarPath = p.join(gameDir, 'fmcl-authlib-injector.jar');

    if (!File(jarPath).existsSync()) {
      _update(sessionId, (s) => s.copyWith(message: '下载 authlib-injector...'));
      final result = await YggdrasilAuthService.fetchAuthlibInjector();
      await File(jarPath).writeAsBytes(result.bytes, flush: true);
      AppLogger.info('Launch', 'authlib-injector ${result.version} 已就绪');
    }

    final serverUrl = account.yggdrasilServer ?? '';
    return '-javaagent:$jarPath=$serverUrl';
  }

  // ---------------- 参数构建 ----------------

  List<String> _buildJvmArgs({
    required GameVersionJson merged,
    required List<GameVersionJson> chain,
    required String gameDir,
    required String nativesDir,
    required AppSettings settings,
    required String authlibArg,
  }) {
    final classpathSep = Platform.isWindows ? ';' : ':';
    final librariesDir = p.join(gameDir, 'libraries');

    // classpath：全部适用库 + 客户端 jar
    final osName = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'osx'
            : 'linux';
    final arch = Platform.operatingSystemVersion.contains('arm') ? 'aarch64' : 'x86_64';

    final cpEntries = <String>[];
    for (final lib in merged.libraries) {
      if (!lib.isAllowedOn(osName, arch)) continue;
      if (lib.natives != null) continue; // natives 不进 classpath
      final artifact = lib.downloads?.artifact;
      final rel = artifact?.path ?? lib.path;
      cpEntries.add(p.join(librariesDir, rel));
    }

    // 客户端 jar：优先继承链原版 jar，其次当前版本 jar
    String clientJar = '';
    for (final v in chain.reversed) {
      final candidate = p.join(gameDir, 'versions', v.id, '${v.id}.jar');
      if (File(candidate).existsSync()) {
        clientJar = candidate;
        break;
      }
    }
    if (clientJar.isEmpty) {
      clientJar = p.join(gameDir, 'versions', merged.id, '${merged.id}.jar');
    }
    cpEntries.add(clientJar);

    // 大 classpath：Windows 使用 @argfile 避免命令行长度限制
    final classpath = cpEntries.join(classpathSep);

    String loggingArg = '';
    final loggingFile = merged.logging?.clientFile;
    if (loggingFile != null && merged.logging?.clientArgument != null) {
      final logPath = p.join(gameDir, 'assets', 'log_configs',
          loggingFile.path?.split('/').last ?? 'client-1.12.xml');
      loggingArg = (merged.logging!.clientArgument!)
          .replaceAll(r'${path}', logPath);
    }

    return LaunchArgumentsBuilder.buildJvmArgs(
      inheritedJvmArgs: _collectJvmArgs(chain),
      nativesDir: nativesDir,
      classpath: classpath,
      classpathSeparator: classpathSep,
      minMemoryMb: settings.minMemoryMb,
      maxMemoryMb: settings.maxMemoryMb,
      extraJvmArgs: settings.jvmArguments,
      javaAgentArg: authlibArg,
      loggingArgument: loggingArg,
    );
  }

  DownloadSource _primarySource() {
    final settings = _ref.read(appSettingsProvider);
    return DownloadSources.of(settings.downloadSourceIndex == 1
        ? DownloadSourceKind.official
        : DownloadSourceKind.bmclapi);
  }

  // ---------------- 进程监控 ----------------

  Future<void> _waitExit(
    int sessionId,
    int handle,
    StreamSubscription<rust.ProcessOutputEvent> sub,
    IOSink logSink,
    String versionId,
  ) async {
    int? exitCode;
    try {
      final exitInfo = await rust.waitGameProcess(handleId: handle);
      exitCode = exitInfo.exitCode;
    } catch (e) {
      AppLogger.error('Launch', '等待进程退出失败', e);
      exitCode = -1;
    }
    await sub.cancel();
    await logSink.flush();
    await logSink.close();

    final logs = _sessions[sessionId]?.recentLogs ?? const <String>[];
    final report = CrashAnalyzer.analyze(
      logTail: logs.join('\n'),
      exitCode: exitCode,
      versionId: versionId,
    );

    _update(sessionId, (s) => s.copyWith(
          phase: report.isNormalExit ? LaunchPhase.exited : LaunchPhase.failed,
          message: report.isNormalExit
              ? '游戏已退出'
              : '游戏异常退出（代码 $exitCode）',
          crashReport: report.isNormalExit ? null : report,
        ));

    if (!report.isNormalExit) {
      // 保存崩溃报告
      final gameDir = _ref.read(appSettingsProvider).gameDirectory;
      final dir = Directory(p.join(gameDir, 'crash-reports', 'fmcl'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File(p.join(dir.path,
          'fmcl-game-${DateTime.now().millisecondsSinceEpoch}.log'));
      await f.writeAsString(logs.join('\n'));
    }
    AppLogger.info('Launch', '游戏退出: code=$exitCode kind=${report.kind}');
  }

  void _appendLog(int sessionId, String line) {
    final cur = _sessions[sessionId];
    if (cur == null) return;
    final logs = [...cur.recentLogs, line];
    if (logs.length > _maxLogLines) {
      logs.removeRange(0, logs.length - _maxLogLines);
    }
    _update(sessionId, (s) => s.copyWith(recentLogs: logs));
  }

  void _applyLauncherBehavior() {
    final behavior = settingsOf(_ref).launcherBehavior;
    // 行为处理由 UI 层监听 launchStateProvider 变化执行（避免服务层依赖窗口管理器）
    AppLogger.debug('Launch', '启动器行为模式: $behavior');
  }
}

/// 启动状态 provider（主会话镜像，兼容既有 UI）
final launchStateProvider = NotifierProvider<LaunchStateNotifier, LaunchState>(
  LaunchStateNotifier.new,
);

/// 多实例会话列表 provider
final launchSessionsProvider =
    NotifierProvider<LaunchSessionsNotifier, List<LaunchSession>>(
  LaunchSessionsNotifier.new,
);

class LaunchSessionsNotifier extends Notifier<List<LaunchSession>> {
  @override
  List<LaunchSession> build() => const [];

  void setAll(List<LaunchSession> sessions) => state = sessions;
}

class LaunchStateNotifier extends Notifier<LaunchState> {
  @override
  LaunchState build() => const LaunchState();

  void reset() => state = const LaunchState();

  /// 整体覆盖
  void set(LaunchState value) => state = value;

  /// 局部更新
  void patchState(LaunchState Function(LaunchState) mutator) =>
      state = mutator(state);
}

/// 启动服务 provider
final launchServiceProvider = Provider<LaunchService>((ref) {
  return LaunchService(ref);
});

/// 下载管理器复用（启动管线使用独立实例避免与安装冲突时互相取消）
final downloadManagerForLaunchProvider = Provider<DownloadManager>((ref) {
  return DownloadManager(ref);
});
