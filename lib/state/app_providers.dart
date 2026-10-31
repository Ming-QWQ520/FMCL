/// 全局状态（Riverpod）——仅做「通信与镜像」，业务决策全部在 Rust。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../rust_bridge/rust_bridge.dart' as rust;

export '../rust_bridge/rust_bridge.dart'
    show
        Account,
        AppInfo,
        ContentFile,
        InstallProgressEvent,
        InstalledContent,
        JavaInfo,
        LaunchEvent,
        LaunchOptions,
        LoaderVersionInfo,
        LocalVersionInfo,
        LogEntry,
        LogFileMeta,
        ModpackManifest,
        ModpackProgressEvent,
        RemoteVersionEntry,
        SearchHit,
        SettingsData,
        VersionSettingsData;

// ---------------------------------------------------------------------------
// 应用信息
// ---------------------------------------------------------------------------

/// 外壳当前页面索引（0 主页 / 1 下载 / 2 账户 / 3 日志 / 4 设置）
class PageIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) => state = index;
}

final pageIndexProvider = NotifierProvider<PageIndexNotifier, int>(
  PageIndexNotifier.new,
);

/// 应用路径信息（main 已调用 initApp，这里幂等再取）
final appInfoProvider = FutureProvider<rust.AppInfo>((ref) => rust.initApp());

/// 生效的游戏根目录（设置优先，缺省 exe 所在目录\.minecraft）
final gameDirProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider);
  if (settings.gameDirectory.trim().isNotEmpty) {
    return settings.gameDirectory.trim();
  }
  return ref.watch(appInfoProvider).value?.defaultGameDir ?? '.minecraft';
});

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

/// 全局设置（Rust 持久化的镜像）
class SettingsNotifier extends Notifier<rust.SettingsData> {
  @override
  rust.SettingsData build() => const rust.SettingsData();

  Future<void> reload() async {
    state = await rust.getSettings();
  }

  Future<void> update(rust.SettingsData next) async {
    state = next;
    await rust.saveSettings(settings: next);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, rust.SettingsData>(
  SettingsNotifier.new,
);

// ---------------------------------------------------------------------------
// 账户
// ---------------------------------------------------------------------------

class AccountsState {
  final List<rust.Account> accounts;
  final rust.Account? current;
  const AccountsState({this.accounts = const [], this.current});
}

class AccountsNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() => const AccountsState();

  Future<void> reload() async {
    final list = await rust.listAccounts();
    final cur = await rust.getCurrentAccount();
    state = AccountsState(accounts: list, current: cur);
  }

  Future<void> addOffline(String name) async {
    await rust.addOfflineAccount(name: name);
    await reload();
  }

  Future<void> select(String id) async {
    await rust.selectAccount(id: id);
    await rust.setLastAccount(accountId: id);
    await reload();
  }

  Future<void> remove(String id) async {
    await rust.removeAccount(id: id);
    await reload();
  }

  /// 微软令牌需要刷新时自动续期；外置令牌校验/续期
  Future<void> refreshIfNeeded() async {
    final cur = state.current;
    if (cur == null) return;
    if (cur.accountType == 'microsoft' &&
        (cur.refreshToken ?? '').isNotEmpty &&
        cur.expiresAt > 0 &&
        DateTime.now().millisecondsSinceEpoch >= cur.expiresAt - 60000) {
      try {
        await rust.microsoftRefresh(refreshToken: cur.refreshToken!);
        await reload();
      } catch (_) {
        // 刷新失败不阻断启动（Rust 侧已记录日志）
      }
    }
    if (cur.accountType == 'yggdrasil' &&
        (cur.yggdrasilServer ?? '').isNotEmpty) {
      try {
        final fresh = await rust.yggdrasilValidateOrRefresh(
          apiRoot: cur.yggdrasilServer!,
          accessToken: cur.accessToken,
          clientToken: cur.clientToken ?? '',
        );
        if (fresh != cur.accessToken) {
          await rust.saveAccount(
            account: rust.Account(
              id: cur.id,
              accountType: cur.accountType,
              name: cur.name,
              accessToken: fresh,
              uuid: cur.uuid,
              yggdrasilServer: cur.yggdrasilServer,
              profileId: cur.profileId,
              expiresAt: cur.expiresAt,
              refreshToken: cur.refreshToken,
              clientToken: cur.clientToken,
              skinUrl: cur.skinUrl,
            ),
          );
          await reload();
        }
      } catch (_) {
        // 校验失败时继续以现有令牌启动
      }
    }
  }
}

final accountsProvider = NotifierProvider<AccountsNotifier, AccountsState>(
  AccountsNotifier.new,
);

// ---------------------------------------------------------------------------
// 本地版本
// ---------------------------------------------------------------------------

/// 本地版本列表（手动/操作后刷新）
final localVersionsProvider =
    NotifierProvider<
      LocalVersionsNotifier,
      AsyncValue<List<rust.LocalVersionInfo>>
    >(LocalVersionsNotifier.new);

class LocalVersionsNotifier
    extends Notifier<AsyncValue<List<rust.LocalVersionInfo>>> {
  @override
  AsyncValue<List<rust.LocalVersionInfo>> build() => const AsyncLoading();

  Future<void> refresh() async {
    state = const AsyncLoading();
    try {
      final dir = ref.read(gameDirProvider);
      final list = await rust.scanLocalVersions(gameDir: dir);
      state = AsyncData(list);
    } catch (e, s) {
      state = AsyncError(e, s);
    }
  }
}

// ---------------------------------------------------------------------------
// 启动会话（多实例）
// ---------------------------------------------------------------------------

/// 单个启动会话的 UI 状态
class LaunchSession {
  final int id;
  final String versionId;
  final String sessionId;
  final String phase;
  final String message;
  final double progress;
  final List<String> recentLogs;
  final bool isActive;
  final int? exitCode;

  const LaunchSession({
    required this.id,
    required this.versionId,
    required this.sessionId,
    this.phase = 'preparing',
    this.message = '',
    this.progress = 0,
    this.recentLogs = const [],
    this.isActive = true,
    this.exitCode,
  });

  LaunchSession copyWith({
    String? phase,
    String? message,
    double? progress,
    List<String>? recentLogs,
    bool? isActive,
    int? exitCode,
  }) {
    return LaunchSession(
      id: id,
      versionId: versionId,
      sessionId: sessionId,
      phase: phase ?? this.phase,
      message: message ?? this.message,
      progress: progress ?? this.progress,
      recentLogs: recentLogs ?? this.recentLogs,
      isActive: isActive ?? this.isActive,
      exitCode: exitCode ?? this.exitCode,
    );
  }
}

class LaunchSessionsNotifier extends Notifier<List<LaunchSession>> {
  int _nextId = 1;
  static const int _maxLogLines = 300;

  @override
  List<LaunchSession> build() => const [];

  /// 启动指定版本（完整管线在 Rust；此处组装通信参数并镜像事件）
  Future<void> launch(String versionId) async {
    final accounts = ref.read(accountsProvider);
    if (accounts.current == null) {
      throw Exception('尚未登录任何账户，请先在「账户」页添加');
    }
    await ref.read(accountsProvider.notifier).refreshIfNeeded();

    final sessionId = _nextId++;
    final sessionKey =
        'launch-$sessionId-${DateTime.now().millisecondsSinceEpoch}';
    final settings = ref.read(settingsProvider);
    final gameDir = ref.read(gameDirProvider);

    // 版本设置（Rust 侧持久化；合并逻辑也在 Rust，这里只取覆盖值）
    rust.VersionSettingsData vOverride;
    try {
      vOverride = await rust.getVersionSettings(
        gameDir: gameDir,
        versionId: versionId,
      );
    } catch (_) {
      vOverride = const rust.VersionSettingsData();
    }
    final isolated = vOverride.isolation ?? settings.versionIsolation;
    final minMem = (vOverride.minMemoryMb ?? 0) > 0
        ? vOverride.minMemoryMb!
        : settings.minMemoryMb;
    final maxMem = (vOverride.maxMemoryMb ?? 0) > 0
        ? vOverride.maxMemoryMb!
        : settings.maxMemoryMb;
    final jvmArgs = [
      settings.jvmArguments.trim(),
      (vOverride.jvmArguments ?? '').trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    final session = LaunchSession(
      id: sessionId,
      versionId: versionId,
      sessionId: sessionKey,
      phase: 'preparing',
      message: '准备启动 $versionId...',
    );
    state = [...state, session];

    final stream = rust.launchGame(
      options: rust.LaunchOptions(
        gameDir: gameDir,
        versionId: versionId,
        account: rust.LaunchAccount(
          accountType: accounts.current!.accountType,
          name: accounts.current!.name,
          uuid: accounts.current!.uuid,
          accessToken: accounts.current!.accessToken,
          yggdrasilServer: accounts.current!.yggdrasilServer ?? '',
        ),
        javaPath: vOverride.javaPath ?? '',
        autoInstallJava: settings.autoInstallJava,
        minMemoryMb: minMem,
        maxMemoryMb: maxMem,
        jvmArguments: jvmArgs,
        gameArguments: settings.gameArguments,
        isolated: isolated,
        serverAddress: settings.serverAddress,
        fullscreen: settings.fullscreen,
        windowWidth: settings.windowWidth,
        windowHeight: settings.windowHeight,
        processPriority: settings.processPriority,
        preLaunchCommand: settings.preLaunchCommand,
        wrapperCommand: settings.wrapperCommand,
        launchEnvironment: settings.launchEnvironment,
        useBmclapi: settings.downloadSourceIndex == 0,
        verifyFiles: settings.verifyFiles,
        concurrency: settings.concurrency,
        sessionId: sessionKey,
      ),
    );

    unawaited(_consume(sessionId, sessionKey, stream));
  }

  Future<void> _consume(
    int sessionId,
    String sessionKey,
    Stream<rust.LaunchEvent> stream,
  ) async {
    try {
      await for (final ev in stream) {
        _apply(sessionId, ev);
      }
    } catch (e) {
      _patch(
        sessionId,
        (s) =>
            s.copyWith(phase: 'failed', message: '启动失败: $e', isActive: false),
      );
    }
    _applyLauncherBehavior();
  }

  void _apply(int sessionId, rust.LaunchEvent ev) {
    _patch(sessionId, (s) {
      switch (ev.kind) {
        case 'phase':
          return s.copyWith(
            phase: ev.phase,
            message: ev.message.isNotEmpty ? ev.message : s.message,
            progress: ev.progress > 0 ? ev.progress : s.progress,
            isActive:
                ev.phase != 'exited' &&
                ev.phase != 'failed' &&
                ev.phase != 'cancelled',
          );
        case 'log':
          final logs = [...s.recentLogs, ev.logLine];
          if (logs.length > _maxLogLines) {
            logs.removeRange(0, logs.length - _maxLogLines);
          }
          return s.copyWith(recentLogs: logs);
        case 'exit':
          return s.copyWith(
            phase: ev.phase,
            message: ev.message,
            isActive: false,
            exitCode: ev.exitCode,
          );
        default:
          return s;
      }
    });
  }

  /// 启动后行为（PCL2：保持 / 隐藏 / 关闭）
  void _applyLauncherBehavior() {
    if (!kIsWeb && Platform.isWindows) {
      final behavior = ref.read(settingsProvider).launcherBehavior;
      if (behavior == 1) {
        windowManager.hide();
      } else if (behavior == 2) {
        windowManager.close();
      }
    }
  }

  void _patch(int sessionId, LaunchSession Function(LaunchSession) f) {
    state = [
      for (final s in state)
        if (s.id == sessionId) f(s) else s,
    ];
  }

  /// 终止会话（下载阶段取消 / 游戏阶段杀进程，逻辑在 Rust）
  Future<void> terminate(int sessionId) async {
    final s = state.where((x) => x.id == sessionId).firstOrNull;
    if (s == null) return;
    await rust.terminateLaunch(sessionId: s.sessionId);
  }

  /// 清理已结束的会话
  void clearFinished() {
    state = state.where((s) => s.isActive).toList();
  }
}

final launchSessionsProvider =
    NotifierProvider<LaunchSessionsNotifier, List<LaunchSession>>(
      LaunchSessionsNotifier.new,
    );

// ---------------------------------------------------------------------------
// 安装任务（版本安装 / 补全 / 整合包）
// ---------------------------------------------------------------------------

/// 安装任务状态（进度对话框）
class InstallTaskState {
  final String title;
  final String phase;
  final String message;
  final double progress;
  final bool running;
  final String? error;

  const InstallTaskState({
    this.title = '',
    this.phase = '',
    this.message = '',
    this.progress = 0,
    this.running = false,
    this.error,
  });

  InstallTaskState copyWith({
    String? title,
    String? phase,
    String? message,
    double? progress,
    bool? running,
    String? error,
  }) {
    return InstallTaskState(
      title: title ?? this.title,
      phase: phase ?? this.phase,
      message: message ?? this.message,
      progress: progress ?? this.progress,
      running: running ?? this.running,
      error: error,
    );
  }
}

class InstallTaskNotifier extends Notifier<InstallTaskState> {
  @override
  InstallTaskState build() => const InstallTaskState();

  void reset() => state = const InstallTaskState();

  /// 合并安装（原版+加载器，Rust 全量管线）
  Future<void> install(rust.InstallRequest request, String title) async {
    state = InstallTaskState(title: title, running: true, message: '准备安装...');
    try {
      await for (final ev in rust.installCombined(request: request)) {
        state = state.copyWith(
          phase: ev.phase,
          message: ev.message,
          progress: ev.progress,
          running:
              ev.phase != 'done' &&
              ev.phase != 'failed' &&
              ev.phase != 'cancelled',
        );
        if (ev.phase == 'failed') {
          state = state.copyWith(error: ev.message, running: false);
        }
      }
    } catch (e) {
      state = state.copyWith(error: '$e', running: false);
    }
  }

  /// 补全文件
  Future<void> complete({
    required String gameDir,
    required String versionId,
    required bool bmclapiFirst,
    required int concurrency,
  }) async {
    state = InstallTaskState(
      title: '补全文件 - $versionId',
      running: true,
      message: '校验文件...',
    );
    try {
      await for (final ev in rust.completeVersion(
        gameDir: gameDir,
        versionId: versionId,
        bmclapiFirst: bmclapiFirst,
        concurrency: concurrency,
        sessionId:
            'complete-$versionId-${DateTime.now().millisecondsSinceEpoch}',
      )) {
        state = state.copyWith(
          phase: ev.phase,
          message: ev.message,
          progress: ev.progress,
          running:
              ev.phase != 'done' &&
              ev.phase != 'failed' &&
              ev.phase != 'cancelled',
        );
        if (ev.phase == 'failed') {
          state = state.copyWith(error: ev.message, running: false);
        }
      }
    } catch (e) {
      state = state.copyWith(error: '$e', running: false);
    }
  }

  /// 安装整合包
  Future<void> installModpack({
    required String zipPath,
    required String gameDir,
    required String instanceName,
    required String javaPath,
    required bool useBmclapi,
    required int concurrency,
  }) async {
    state = InstallTaskState(
      title: '安装整合包',
      running: true,
      message: '解析整合包...',
    );
    try {
      final stream = rust.installModpack(
        zipPath: zipPath,
        gameDir: gameDir,
        instanceName: instanceName,
        javaPath: javaPath,
        useBmclapi: useBmclapi,
        concurrency: concurrency,
        sessionId: 'modpack-${DateTime.now().millisecondsSinceEpoch}',
      );
      await for (final ev in stream) {
        state = state.copyWith(
          phase: ev.phase,
          message: ev.message,
          progress: ev.progress,
          running: ev.phase != 'done' && ev.phase != 'failed',
        );
        if (ev.phase == 'failed') {
          state = state.copyWith(error: ev.message, running: false);
        }
      }
      await ref.read(localVersionsProvider.notifier).refresh();
    } catch (e) {
      state = state.copyWith(error: '$e', running: false);
    }
  }
}

final installTaskProvider =
    NotifierProvider<InstallTaskNotifier, InstallTaskState>(
      InstallTaskNotifier.new,
    );

// ---------------------------------------------------------------------------
// 启动器日志（实时流）
// ---------------------------------------------------------------------------

/// 启动器实时日志（Rust broadcast → Flutter）
final appLogStreamProvider = StreamProvider<rust.LogEntry>((ref) {
  return rust.subscribeAppLogs();
});

/// 最近日志缓存（主页底部条 / 日志页首屏）
final recentLogsProvider =
    NotifierProvider<RecentLogsNotifier, List<rust.LogEntry>>(
      RecentLogsNotifier.new,
    );

class RecentLogsNotifier extends Notifier<List<rust.LogEntry>> {
  static const int max = 600;
  bool _subscribed = false;

  @override
  List<rust.LogEntry> build() {
    _ensureSubscribed();
    ref.onDispose(() {
      _subscribed = false;
      _cancelListen?.close();
      _cancelListen = null;
    });
    return const [];
  }

  ProviderSubscription<AsyncValue<rust.LogEntry>>? _cancelListen;

  void _ensureSubscribed() {
    if (_subscribed) return;
    _subscribed = true;
    // 首屏：读最近日志
    rust
        .readRecentLogs(maxLines: 150)
        .then((rows) {
          if (state.isEmpty) state = rows;
        })
        .catchError((_) {});
    // 订阅实时流
    _cancelListen = ref.listen(appLogStreamProvider, (prev, next) {
      next.whenData((entry) {
        final list = [...state, entry];
        if (list.length > max) {
          list.removeRange(0, list.length - max);
        }
        state = list;
      });
    });
  }

  Future<void> loadFile(String path, {int limit = 800}) async {
    final text = await rust.readLogFile(path: path, maxLines: limit);
    final rows = text
        .split('\n')
        .map(
          (l) => rust.LogEntry(
            time: '',
            level: 'INFO',
            module: 'File',
            message: l,
          ),
        )
        .toList();
    state = rows;
  }

  Future<void> reloadDisk() async {
    final rows = await rust.readRecentLogs(maxLines: max);
    state = rows;
  }
}

// ---------------------------------------------------------------------------
// 下载源 / Java
// ---------------------------------------------------------------------------

/// 远程原版版本清单
final remoteVersionsProvider = FutureProvider<List<rust.RemoteVersionEntry>>((
  ref,
) async {
  final settings = ref.watch(settingsProvider);
  // UI 侧兜底超时：杜绝任何网络/桥路异常导致的永久转圈
  return rust
      .fetchRemoteVersions(bmclapiFirst: settings.downloadSourceIndex == 0)
      .timeout(const Duration(seconds: 150));
});

/// 加载器版本列表（loader/mc 变化时重新拉取）
final loaderVersionsProvider = FutureProvider.autoDispose
    .family<List<rust.LoaderVersionInfo>, (String, String)>((ref, key) async {
      final settings = ref.watch(settingsProvider);
      return rust.fetchLoaderVersions(
        loader: key.$1,
        mcVersion: key.$2,
        bmclapiFirst: settings.downloadSourceIndex == 0,
      );
    });

/// Java 运行时列表
final javasProvider = FutureProvider<List<rust.JavaInfo>>((ref) async {
  final settings = ref.watch(settingsProvider);
  return rust.detectJavas(extraDirs: settings.javaSearchPaths);
});

// ---------------------------------------------------------------------------
// 版本管理操作（导入/删除/重命名等）
// ---------------------------------------------------------------------------

/// 版本管理服务（薄封装，操作后自动刷新列表）
class VersionOps {
  final Ref ref;
  const VersionOps(this.ref);

  Future<void> importExternal(String sourceDir, String newName) async {
    await rust.importExternalVersion(
      gameDir: ref.read(gameDirProvider),
      sourceDir: sourceDir,
      newName: newName,
    );
    await ref.read(localVersionsProvider.notifier).refresh();
  }

  Future<void> delete(String versionId) async {
    await rust.deleteVersion(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
    );
    await ref.read(localVersionsProvider.notifier).refresh();
  }

  Future<void> rename(String versionId, String newName) async {
    await rust.renameVersion(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
      newName: newName,
    );
    await ref.read(localVersionsProvider.notifier).refresh();
  }

  Future<void> copy(String versionId, String newName) async {
    await rust.copyVersion(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
      newName: newName,
    );
    await ref.read(localVersionsProvider.notifier).refresh();
  }

  Future<rust.VersionSettingsData> settings(String versionId) {
    return rust.getVersionSettings(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
    );
  }

  Future<void> saveSettings(
    String versionId,
    rust.VersionSettingsData data,
  ) async {
    await rust.saveVersionSettings(
      gameDir: ref.read(gameDirProvider),
      versionId: versionId,
      settings: data,
    );
  }
}

final versionOpsProvider = Provider<VersionOps>(VersionOps.new);

/// 上次选中版本（持久化在 Rust 设置里）
final selectedVersionProvider =
    NotifierProvider<SelectedVersionNotifier, String>(
      SelectedVersionNotifier.new,
    );

class SelectedVersionNotifier extends Notifier<String> {
  @override
  String build() {
    // 延迟初始化：设置加载后取 lastVersionId，否则取列表第一个
    Future.microtask(() async {
      if (state.isNotEmpty) return;
      final s = ref.read(settingsProvider);
      if (s.lastVersionId.isNotEmpty) {
        state = s.lastVersionId;
      } else {
        await ref.read(localVersionsProvider.notifier).refresh();
        final list = ref.read(localVersionsProvider).value ?? const [];
        if (list.isNotEmpty) {
          state = list.first.id;
        }
      }
    });
    return '';
  }

  Future<void> select(String versionId) async {
    state = versionId;
    try {
      await rust.setLastVersion(versionId: versionId);
    } catch (_) {}
  }
}

/// SettingsData 本地 copyWith 辅助（桥接结构无 copyWith，此处集中管理）
extension SettingsCopy on rust.SettingsData {
  rust.SettingsData copyWithLocal({
    int? themeMode,
    String? backgroundImagePath,
    int? backgroundOpacity,
    int? backgroundBlur,
    String? gameDirectory,
    List<String>? javaSearchPaths,
    int? maxMemoryMb,
    int? minMemoryMb,
    String? jvmArguments,
    String? gameArguments,
    String? javaPath,
    int? launcherBehavior,
    int? processPriority,
    String? serverAddress,
    String? preLaunchCommand,
    List<String>? launchEnvironment,
    String? wrapperCommand,
    bool? fullscreen,
    int? windowWidth,
    int? windowHeight,
    int? windowLauncherWidth,
    int? windowLauncherHeight,
    int? downloadSourceIndex,
    bool? autoFallback,
    int? concurrency,
    bool? verifyFiles,
    bool? versionIsolation,
    bool? autoInstallJava,
    String? lastAccountId,
    String? lastVersionId,
    bool? onboarded,
  }) {
    return rust.SettingsData(
      themeMode: themeMode ?? this.themeMode,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      backgroundBlur: backgroundBlur ?? this.backgroundBlur,
      gameDirectory: gameDirectory ?? this.gameDirectory,
      javaSearchPaths: javaSearchPaths ?? this.javaSearchPaths,
      maxMemoryMb: maxMemoryMb ?? this.maxMemoryMb,
      minMemoryMb: minMemoryMb ?? this.minMemoryMb,
      jvmArguments: jvmArguments ?? this.jvmArguments,
      gameArguments: gameArguments ?? this.gameArguments,
      javaPath: javaPath ?? this.javaPath,
      launcherBehavior: launcherBehavior ?? this.launcherBehavior,
      processPriority: processPriority ?? this.processPriority,
      serverAddress: serverAddress ?? this.serverAddress,
      preLaunchCommand: preLaunchCommand ?? this.preLaunchCommand,
      launchEnvironment: launchEnvironment ?? this.launchEnvironment,
      wrapperCommand: wrapperCommand ?? this.wrapperCommand,
      fullscreen: fullscreen ?? this.fullscreen,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowLauncherWidth: windowLauncherWidth ?? this.windowLauncherWidth,
      windowLauncherHeight: windowLauncherHeight ?? this.windowLauncherHeight,
      downloadSourceIndex: downloadSourceIndex ?? this.downloadSourceIndex,
      autoFallback: autoFallback ?? this.autoFallback,
      concurrency: concurrency ?? this.concurrency,
      verifyFiles: verifyFiles ?? this.verifyFiles,
      versionIsolation: versionIsolation ?? this.versionIsolation,
      autoInstallJava: autoInstallJava ?? this.autoInstallJava,
      lastAccountId: lastAccountId ?? this.lastAccountId,
      lastVersionId: lastVersionId ?? this.lastVersionId,
      onboarded: onboarded ?? this.onboarded,
    );
  }
}
