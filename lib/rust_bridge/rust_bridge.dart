/// Rust 桥接统一入口（类型化 API）。
///
/// 全部业务逻辑在 Rust 侧；Dart 仅做「渲染与通信」：
/// - 类型化的请求结构体（toJson → JSON 参数）
/// - 类型化的返回/事件模型（fromJson ← JSON 值）
/// - 普通方法：`Future<T>`；流式方法：`Stream<T>`（过程事件）
///
/// 方法名与参数键与 `rust/src/dispatch.rs` 一一对应。
library;

import 'dart:async';

import 'rust_ffi.dart';

RustFfi get _ffi => RustFfi.instance;

/// 是否成功初始化了 Rust 运行时
bool _rustReady = false;

/// Rust 后端是否可用
bool get rustBridgeAvailable => _rustReady;

/// 初始化 Rust 运行时（幂等）。失败时抛出，由调用方决定退出策略。
Future<void> initRustBridge() async {
  if (_rustReady) return;
  _ffi.ensureLoaded();
  _rustReady = true;
}

// ---------------------------------------------------------------------------
// 数据模型（字段名与 Rust serde camelCase 输出一一对应）
// ---------------------------------------------------------------------------

/// 应用路径信息
class AppInfo {
  final String appVersion;
  final String exeDir;
  final String fmclRoot;
  final String defaultGameDir;
  final String logsDir;
  final String gameLogsDir;
  final String crashReportsDir;
  final String authlibInjectorDir;
  final String cacheDir;
  final String javaDir;
  final String osName;
  final String arch;

  const AppInfo({
    this.appVersion = '',
    this.exeDir = '',
    this.fmclRoot = '',
    this.defaultGameDir = '',
    this.logsDir = '',
    this.gameLogsDir = '',
    this.crashReportsDir = '',
    this.authlibInjectorDir = '',
    this.cacheDir = '',
    this.javaDir = '',
    this.osName = '',
    this.arch = '',
  });

  factory AppInfo.fromJson(Map<String, dynamic> j) => AppInfo(
    appVersion: j['appVersion'] as String? ?? '',
    exeDir: j['exeDir'] as String? ?? '',
    fmclRoot: j['fmclRoot'] as String? ?? '',
    defaultGameDir: j['defaultGameDir'] as String? ?? '',
    logsDir: j['logsDir'] as String? ?? '',
    gameLogsDir: j['gameLogsDir'] as String? ?? '',
    crashReportsDir: j['crashReportsDir'] as String? ?? '',
    authlibInjectorDir: j['authlibInjectorDir'] as String? ?? '',
    cacheDir: j['cacheDir'] as String? ?? '',
    javaDir: j['javaDir'] as String? ?? '',
    osName: j['osName'] as String? ?? '',
    arch: j['arch'] as String? ?? '',
  );
}

/// 一条启动器日志
class LogEntry {
  final String time;
  final String level;
  final String module;
  final String message;

  const LogEntry({
    this.time = '',
    this.level = 'INFO',
    this.module = '',
    this.message = '',
  });

  factory LogEntry.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return LogEntry(
      time: m['time'] as String? ?? '',
      level: m['level'] as String? ?? 'INFO',
      module: m['module'] as String? ?? '',
      message: m['message'] as String? ?? '',
    );
  }
}

/// 日志文件元信息
class LogFileMeta {
  final String name;
  final String path;
  final int sizeBytes;
  final int modifiedMs;

  const LogFileMeta({
    this.name = '',
    this.path = '',
    this.sizeBytes = 0,
    this.modifiedMs = 0,
  });

  factory LogFileMeta.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return LogFileMeta(
      name: m['name'] as String? ?? '',
      path: m['path'] as String? ?? '',
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      modifiedMs: (m['modifiedMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 全局设置（与 Rust core::settings::AppSettings 字段一一对应）
class SettingsData {
  final int themeMode;
  final String backgroundImagePath;
  final int backgroundOpacity;
  final int backgroundBlur;
  final String gameDirectory;
  final List<String> javaSearchPaths;
  final int maxMemoryMb;
  final int minMemoryMb;
  final String jvmArguments;
  final String gameArguments;
  final String javaPath;
  final int launcherBehavior;
  final int processPriority;
  final String serverAddress;
  final String preLaunchCommand;
  final List<String> launchEnvironment;
  final String wrapperCommand;
  final bool fullscreen;
  final int windowWidth;
  final int windowHeight;
  final int windowLauncherWidth;
  final int windowLauncherHeight;
  final int downloadSourceIndex;
  final bool autoFallback;
  final int concurrency;
  final bool verifyFiles;
  final bool versionIsolation;
  final bool autoInstallJava;
  final String lastAccountId;
  final String lastVersionId;
  final bool onboarded;

  const SettingsData({
    this.themeMode = 0,
    this.backgroundImagePath = '',
    this.backgroundOpacity = 45,
    this.backgroundBlur = 0,
    this.gameDirectory = '',
    this.javaSearchPaths = const [],
    this.maxMemoryMb = 2048,
    this.minMemoryMb = 512,
    this.jvmArguments = '',
    this.gameArguments = '',
    this.javaPath = '',
    this.launcherBehavior = 1,
    this.processPriority = 0,
    this.serverAddress = '',
    this.preLaunchCommand = '',
    this.launchEnvironment = const [],
    this.wrapperCommand = '',
    this.fullscreen = false,
    this.windowWidth = 0,
    this.windowHeight = 0,
    this.windowLauncherWidth = 1120,
    this.windowLauncherHeight = 720,
    this.downloadSourceIndex = 0,
    this.autoFallback = true,
    this.concurrency = 32,
    this.verifyFiles = true,
    this.versionIsolation = true,
    this.autoInstallJava = true,
    this.lastAccountId = '',
    this.lastVersionId = '',
    this.onboarded = false,
  });

  factory SettingsData.fromJson(Map<String, dynamic> j) => SettingsData(
    themeMode: (j['themeMode'] as num?)?.toInt() ?? 0,
    backgroundImagePath: j['backgroundImagePath'] as String? ?? '',
    backgroundOpacity: (j['backgroundOpacity'] as num?)?.toInt() ?? 45,
    backgroundBlur: (j['backgroundBlur'] as num?)?.toInt() ?? 0,
    gameDirectory: j['gameDirectory'] as String? ?? '',
    javaSearchPaths: _strList(j['javaSearchPaths']),
    maxMemoryMb: (j['maxMemoryMb'] as num?)?.toInt() ?? 2048,
    minMemoryMb: (j['minMemoryMb'] as num?)?.toInt() ?? 512,
    jvmArguments: j['jvmArguments'] as String? ?? '',
    gameArguments: j['gameArguments'] as String? ?? '',
    javaPath: j['javaPath'] as String? ?? '',
    launcherBehavior: (j['launcherBehavior'] as num?)?.toInt() ?? 1,
    processPriority: (j['processPriority'] as num?)?.toInt() ?? 0,
    serverAddress: j['serverAddress'] as String? ?? '',
    preLaunchCommand: j['preLaunchCommand'] as String? ?? '',
    launchEnvironment: _strList(j['launchEnvironment']),
    wrapperCommand: j['wrapperCommand'] as String? ?? '',
    fullscreen: j['fullscreen'] as bool? ?? false,
    windowWidth: (j['windowWidth'] as num?)?.toInt() ?? 0,
    windowHeight: (j['windowHeight'] as num?)?.toInt() ?? 0,
    windowLauncherWidth: (j['windowLauncherWidth'] as num?)?.toInt() ?? 1120,
    windowLauncherHeight: (j['windowLauncherHeight'] as num?)?.toInt() ?? 720,
    downloadSourceIndex: (j['downloadSourceIndex'] as num?)?.toInt() ?? 0,
    autoFallback: j['autoFallback'] as bool? ?? true,
    concurrency: (j['concurrency'] as num?)?.toInt() ?? 32,
    verifyFiles: j['verifyFiles'] as bool? ?? true,
    versionIsolation: j['versionIsolation'] as bool? ?? true,
    autoInstallJava: j['autoInstallJava'] as bool? ?? true,
    lastAccountId: j['lastAccountId'] as String? ?? '',
    lastVersionId: j['lastVersionId'] as String? ?? '',
    onboarded: j['onboarded'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode,
    'backgroundImagePath': backgroundImagePath,
    'backgroundOpacity': backgroundOpacity,
    'backgroundBlur': backgroundBlur,
    'gameDirectory': gameDirectory,
    'javaSearchPaths': javaSearchPaths,
    'maxMemoryMb': maxMemoryMb,
    'minMemoryMb': minMemoryMb,
    'jvmArguments': jvmArguments,
    'gameArguments': gameArguments,
    'javaPath': javaPath,
    'launcherBehavior': launcherBehavior,
    'processPriority': processPriority,
    'serverAddress': serverAddress,
    'preLaunchCommand': preLaunchCommand,
    'launchEnvironment': launchEnvironment,
    'wrapperCommand': wrapperCommand,
    'fullscreen': fullscreen,
    'windowWidth': windowWidth,
    'windowHeight': windowHeight,
    'windowLauncherWidth': windowLauncherWidth,
    'windowLauncherHeight': windowLauncherHeight,
    'downloadSourceIndex': downloadSourceIndex,
    'autoFallback': autoFallback,
    'concurrency': concurrency,
    'verifyFiles': verifyFiles,
    'versionIsolation': versionIsolation,
    'autoInstallJava': autoInstallJava,
    'lastAccountId': lastAccountId,
    'lastVersionId': lastVersionId,
    'onboarded': onboarded,
  };
}

/// 版本设置（缺省字段 = 跟随全局）
class VersionSettingsData {
  final bool? isolation;
  final String? javaPath;
  final int? maxMemoryMb;
  final int? minMemoryMb;
  final String? jvmArguments;

  const VersionSettingsData({
    this.isolation,
    this.javaPath,
    this.maxMemoryMb,
    this.minMemoryMb,
    this.jvmArguments,
  });

  factory VersionSettingsData.fromJson(Map<String, dynamic> j) =>
      VersionSettingsData(
        isolation: j['isolation'] as bool?,
        javaPath: j['javaPath'] as String?,
        maxMemoryMb: (j['maxMemoryMb'] as num?)?.toInt(),
        minMemoryMb: (j['minMemoryMb'] as num?)?.toInt(),
        jvmArguments: j['jvmArguments'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'isolation': isolation,
    'javaPath': javaPath,
    'maxMemoryMb': maxMemoryMb,
    'minMemoryMb': minMemoryMb,
    'jvmArguments': jvmArguments,
  };
}

/// 统一账户模型
class Account {
  final String id;
  final String accountType;
  final String name;
  final String accessToken;
  final String uuid;
  final String? yggdrasilServer;
  final String? profileId;
  final int expiresAt;
  final String? refreshToken;
  final String? clientToken;
  final String? skinUrl;

  const Account({
    required this.id,
    this.accountType = 'offline',
    this.name = '',
    this.accessToken = '0',
    this.uuid = '',
    this.yggdrasilServer,
    this.profileId,
    this.expiresAt = 0,
    this.refreshToken,
    this.clientToken,
    this.skinUrl,
  });

  factory Account.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return Account(
      id: m['id'] as String? ?? '',
      accountType: m['accountType'] as String? ?? 'offline',
      name: m['name'] as String? ?? '',
      accessToken: m['accessToken'] as String? ?? '0',
      uuid: m['uuid'] as String? ?? '',
      yggdrasilServer: m['yggdrasilServer'] as String?,
      profileId: m['profileId'] as String?,
      expiresAt: (m['expiresAt'] as num?)?.toInt() ?? 0,
      refreshToken: m['refreshToken'] as String?,
      clientToken: m['clientToken'] as String?,
      skinUrl: m['skinUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountType': accountType,
    'name': name,
    'accessToken': accessToken,
    'uuid': uuid,
    'yggdrasilServer': yggdrasilServer,
    'profileId': profileId,
    'expiresAt': expiresAt,
    'refreshToken': refreshToken,
    'clientToken': clientToken,
    'skinUrl': skinUrl,
  };

  /// 账户类型展示名
  String get typeLabel {
    switch (accountType) {
      case 'microsoft':
        return '微软正版';
      case 'yggdrasil':
        return '外置登录';
      default:
        return '离线模式';
    }
  }
}

/// 外置角色档案
class YggdrasilProfile {
  final String id;
  final String name;

  const YggdrasilProfile({required this.id, required this.name});

  factory YggdrasilProfile.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return YggdrasilProfile(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
    );
  }
}

/// 外置登录会话
class YggdrasilSession {
  final String accessToken;
  final String clientToken;
  final String apiRoot;
  final List<YggdrasilProfile> profiles;

  const YggdrasilSession({
    required this.accessToken,
    required this.clientToken,
    required this.apiRoot,
    required this.profiles,
  });

  factory YggdrasilSession.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return YggdrasilSession(
      accessToken: m['accessToken'] as String? ?? '',
      clientToken: m['clientToken'] as String? ?? '',
      apiRoot: m['apiRoot'] as String? ?? '',
      profiles: ((m['profiles'] as List?) ?? const [])
          .map(YggdrasilProfile.fromJson)
          .toList(),
    );
  }
}

/// 微软登录事件
class MsLoginEvent {
  /// device_code | polling | profile | done | failed
  final String step;
  final String message;
  final String userCode;
  final String verificationUri;

  const MsLoginEvent({
    required this.step,
    required this.message,
    required this.userCode,
    required this.verificationUri,
  });

  factory MsLoginEvent.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return MsLoginEvent(
      step: m['step'] as String? ?? '',
      message: m['message'] as String? ?? '',
      userCode: m['userCode'] as String? ?? '',
      verificationUri: m['verificationUri'] as String? ?? '',
    );
  }
}

/// 本地版本信息
class LocalVersionInfo {
  final String id;
  final String dir;
  final bool hasJar;

  /// vanilla / forge / neoforge / fabric / quilt / optifine / unknown
  final String loader;
  final String loaderVersion;
  final String gameVersion;
  final int modifiedMs;
  final int sizeBytes;

  const LocalVersionInfo({
    required this.id,
    this.dir = '',
    this.hasJar = false,
    this.loader = 'vanilla',
    this.loaderVersion = '',
    this.gameVersion = '',
    this.modifiedMs = 0,
    this.sizeBytes = 0,
  });

  factory LocalVersionInfo.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return LocalVersionInfo(
      id: m['id'] as String? ?? '',
      dir: m['dir'] as String? ?? '',
      hasJar: m['hasJar'] as bool? ?? false,
      loader: m['loader'] as String? ?? 'vanilla',
      loaderVersion: m['loaderVersion'] as String? ?? '',
      gameVersion: m['gameVersion'] as String? ?? '',
      modifiedMs: (m['modifiedMs'] as num?)?.toInt() ?? 0,
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 远程原版版本条目
class RemoteVersionEntry {
  final String id;
  final String versionType;
  final String releaseTime;
  final String url;

  const RemoteVersionEntry({
    required this.id,
    this.versionType = 'release',
    this.releaseTime = '',
    this.url = '',
  });

  factory RemoteVersionEntry.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return RemoteVersionEntry(
      id: m['id'] as String? ?? '',
      versionType: m['versionType'] as String? ?? 'release',
      releaseTime: m['releaseTime'] as String? ?? '',
      url: m['url'] as String? ?? '',
    );
  }
}

/// 加载器版本条目
class LoaderVersionInfo {
  final String version;
  final bool isRecommended;
  final bool isPreview;

  const LoaderVersionInfo({
    required this.version,
    this.isRecommended = false,
    this.isPreview = false,
  });

  factory LoaderVersionInfo.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return LoaderVersionInfo(
      version: m['version'] as String? ?? '',
      isRecommended: m['isRecommended'] as bool? ?? false,
      isPreview: m['isPreview'] as bool? ?? false,
    );
  }
}

/// 检测到的 Java 运行时
class JavaInfo {
  final String javaPath;
  final int majorVersion;
  final String versionString;
  final String vendor;
  final bool is64bit;
  final bool isJre;

  const JavaInfo({
    required this.javaPath,
    this.majorVersion = 0,
    this.versionString = '',
    this.vendor = '',
    this.is64bit = true,
    this.isJre = false,
  });

  factory JavaInfo.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return JavaInfo(
      javaPath: m['javaPath'] as String? ?? '',
      majorVersion: (m['majorVersion'] as num?)?.toInt() ?? 0,
      versionString: m['versionString'] as String? ?? '',
      vendor: m['vendor'] as String? ?? '',
      is64bit: m['is64bit'] as bool? ?? true,
      isJre: m['isJre'] as bool? ?? false,
    );
  }
}

/// 高清修复（OptiFine）条目
class OptiFineEntry {
  final String inherit;
  final String displayName;
  final String fileName;
  final bool isPreview;

  const OptiFineEntry({
    required this.inherit,
    this.displayName = '',
    this.fileName = '',
    this.isPreview = false,
  });

  Map<String, dynamic> toJson() => {
    'inherit': inherit,
    'displayName': displayName,
    'fileName': fileName,
    'isPreview': isPreview,
  };
}

/// 合并安装请求（原版 + 加载器 + OptiFine 一体）
class InstallRequest {
  final String gameDir;
  final String instanceName;
  final String gameVersion;
  final String? versionJsonUrl;
  final String? fabricVersion;
  final String? quiltVersion;
  final String? forgeVersion;
  final String? neoforgeVersion;
  final OptiFineEntry? optifine;
  final String javaPath;
  final bool useBmclapi;
  final int concurrency;
  final String sessionId;

  const InstallRequest({
    required this.gameDir,
    required this.instanceName,
    required this.gameVersion,
    this.versionJsonUrl,
    this.fabricVersion,
    this.quiltVersion,
    this.forgeVersion,
    this.neoforgeVersion,
    this.optifine,
    this.javaPath = '',
    this.useBmclapi = true,
    this.concurrency = 32,
    this.sessionId = '',
  });

  Map<String, dynamic> toJson() => {
    'gameDir': gameDir,
    'instanceName': instanceName,
    'gameVersion': gameVersion,
    'versionJsonUrl': versionJsonUrl,
    'fabricVersion': fabricVersion,
    'quiltVersion': quiltVersion,
    'forgeVersion': forgeVersion,
    'neoforgeVersion': neoforgeVersion,
    'optifine': optifine?.toJson(),
    'javaPath': javaPath,
    'useBmclapi': useBmclapi,
    'concurrency': concurrency,
    'sessionId': sessionId,
  };
}

/// 安装 / 补全进度事件
class InstallProgressEvent {
  /// resolve | download | process | merge | finalize | done | failed | cancelled
  final String phase;
  final String message;
  final double progress;

  const InstallProgressEvent({
    required this.phase,
    required this.message,
    this.progress = 0,
  });

  factory InstallProgressEvent.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return InstallProgressEvent(
      phase: m['phase'] as String? ?? '',
      message: m['message'] as String? ?? '',
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 启动用账户信息
class LaunchAccount {
  final String accountType;
  final String name;
  final String uuid;
  final String accessToken;
  final String yggdrasilServer;

  const LaunchAccount({
    required this.accountType,
    required this.name,
    this.uuid = '',
    this.accessToken = '',
    this.yggdrasilServer = '',
  });

  Map<String, dynamic> toJson() => {
    'accountType': accountType,
    'name': name,
    'uuid': uuid,
    'accessToken': accessToken,
    'yggdrasilServer': yggdrasilServer,
  };
}

/// 启动请求
class LaunchOptions {
  final String gameDir;
  final String versionId;
  final LaunchAccount? account;
  final String javaPath;
  final bool autoInstallJava;
  final int minMemoryMb;
  final int maxMemoryMb;
  final String jvmArguments;
  final String gameArguments;
  final bool isolated;
  final String serverAddress;
  final bool fullscreen;
  final int windowWidth;
  final int windowHeight;
  final int processPriority;
  final String preLaunchCommand;
  final String wrapperCommand;
  final List<String> launchEnvironment;
  final bool useBmclapi;
  final bool verifyFiles;
  final int concurrency;
  final String sessionId;

  const LaunchOptions({
    required this.gameDir,
    required this.versionId,
    this.account,
    this.javaPath = '',
    this.autoInstallJava = true,
    this.minMemoryMb = 512,
    this.maxMemoryMb = 2048,
    this.jvmArguments = '',
    this.gameArguments = '',
    this.isolated = true,
    this.serverAddress = '',
    this.fullscreen = false,
    this.windowWidth = 854,
    this.windowHeight = 480,
    this.processPriority = 0,
    this.preLaunchCommand = '',
    this.wrapperCommand = '',
    this.launchEnvironment = const [],
    this.useBmclapi = true,
    this.verifyFiles = true,
    this.concurrency = 32,
    this.sessionId = '',
  });

  Map<String, dynamic> toJson() => {
    'gameDir': gameDir,
    'versionId': versionId,
    'account': account?.toJson(),
    'javaPath': javaPath,
    'autoInstallJava': autoInstallJava,
    'minMemoryMb': minMemoryMb,
    'maxMemoryMb': maxMemoryMb,
    'jvmArguments': jvmArguments,
    'gameArguments': gameArguments,
    'isolated': isolated,
    'serverAddress': serverAddress,
    'fullscreen': fullscreen,
    'windowWidth': windowWidth,
    'windowHeight': windowHeight,
    'processPriority': processPriority,
    'preLaunchCommand': preLaunchCommand,
    'wrapperCommand': wrapperCommand,
    'launchEnvironment': launchEnvironment,
    'useBmclapi': useBmclapi,
    'verifyFiles': verifyFiles,
    'concurrency': concurrency,
    'sessionId': sessionId,
  };
}

/// 启动事件
class LaunchEvent {
  /// phase | log | exit
  final String kind;

  /// preparing / downloading / extracting / buildingArgs / launching /
  /// running / exited / failed / cancelled
  final String phase;
  final String message;
  final double progress;
  final String logLine;
  final int exitCode;
  final String crashSummary;

  const LaunchEvent({
    required this.kind,
    required this.phase,
    required this.message,
    this.progress = 0,
    this.logLine = '',
    this.exitCode = 0,
    this.crashSummary = '',
  });

  factory LaunchEvent.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return LaunchEvent(
      kind: m['kind'] as String? ?? 'phase',
      phase: m['phase'] as String? ?? '',
      message: m['message'] as String? ?? '',
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
      logLine: m['logLine'] as String? ?? '',
      exitCode: (m['exitCode'] as num?)?.toInt() ?? 0,
      crashSummary: m['crashSummary'] as String? ?? '',
    );
  }
}

/// 搜索结果条目（Modrinth）
class SearchHit {
  final String projectId;
  final String slug;
  final String title;
  final String description;
  final String author;
  final int downloads;
  final String iconUrl;
  final String category;
  final String dateModified;

  const SearchHit({
    required this.projectId,
    this.slug = '',
    this.title = '',
    this.description = '',
    this.author = '',
    this.downloads = 0,
    this.iconUrl = '',
    this.category = 'mod',
    this.dateModified = '',
  });

  factory SearchHit.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return SearchHit(
      projectId: m['projectId'] as String? ?? '',
      slug: m['slug'] as String? ?? '',
      title: m['title'] as String? ?? '',
      description: m['description'] as String? ?? '',
      author: m['author'] as String? ?? '',
      downloads: (m['downloads'] as num?)?.toInt() ?? 0,
      iconUrl: m['iconUrl'] as String? ?? '',
      category: m['category'] as String? ?? 'mod',
      dateModified: m['dateModified'] as String? ?? '',
    );
  }
}

/// 项目可下载文件版本
class ContentFile {
  final String versionId;
  final String name;
  final String versionNumber;
  final String datePublished;
  final int sizeBytes;
  final String downloadUrl;
  final String filename;
  final List<String> gameVersions;
  final List<String> loaders;
  final String versionType;

  const ContentFile({
    required this.versionId,
    this.name = '',
    this.versionNumber = '',
    this.datePublished = '',
    this.sizeBytes = 0,
    this.downloadUrl = '',
    this.filename = '',
    this.gameVersions = const [],
    this.loaders = const [],
    this.versionType = 'release',
  });

  factory ContentFile.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return ContentFile(
      versionId: m['versionId'] as String? ?? '',
      name: m['name'] as String? ?? '',
      versionNumber: m['versionNumber'] as String? ?? '',
      datePublished: m['datePublished'] as String? ?? '',
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      downloadUrl: m['downloadUrl'] as String? ?? '',
      filename: m['filename'] as String? ?? '',
      gameVersions: _strList(m['gameVersions']),
      loaders: _strList(m['loaders']),
      versionType: m['versionType'] as String? ?? 'release',
    );
  }
}

/// 已安装内容条目
class InstalledContent {
  final String name;
  final String path;
  final int sizeBytes;
  final int modifiedMs;

  const InstalledContent({
    required this.name,
    required this.path,
    this.sizeBytes = 0,
    this.modifiedMs = 0,
  });

  factory InstalledContent.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return InstalledContent(
      name: m['name'] as String? ?? '',
      path: m['path'] as String? ?? '',
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      modifiedMs: (m['modifiedMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 整合包清单
class ModpackManifest {
  final String name;
  final String version;
  final String author;
  final String description;
  final String mcVersion;
  final String loader;
  final String loaderVersion;

  /// modrinth | curseforge
  final String kind;
  final int fileCount;

  const ModpackManifest({
    required this.name,
    this.version = '',
    this.author = '',
    this.description = '',
    this.mcVersion = '',
    this.loader = 'vanilla',
    this.loaderVersion = '',
    this.kind = 'modrinth',
    this.fileCount = 0,
  });

  factory ModpackManifest.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return ModpackManifest(
      name: m['name'] as String? ?? '',
      version: m['version'] as String? ?? '',
      author: m['author'] as String? ?? '',
      description: m['description'] as String? ?? '',
      mcVersion: m['mcVersion'] as String? ?? '',
      loader: m['loader'] as String? ?? 'vanilla',
      loaderVersion: m['loaderVersion'] as String? ?? '',
      kind: m['kind'] as String? ?? 'modrinth',
      fileCount: (m['fileCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 整合包安装进度事件
class ModpackProgressEvent {
  /// extract | download | install | done | failed
  final String phase;
  final String message;
  final double progress;

  const ModpackProgressEvent({
    required this.phase,
    required this.message,
    this.progress = 0,
  });

  factory ModpackProgressEvent.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return ModpackProgressEvent(
      phase: m['phase'] as String? ?? '',
      message: m['message'] as String? ?? '',
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Java 自动安装进度事件
class JavaInstallProgress {
  /// query | download | verify | extract | finalize | done | failed
  final String phase;
  final String message;
  final double? progress;

  const JavaInstallProgress({
    required this.phase,
    required this.message,
    this.progress,
  });

  factory JavaInstallProgress.fromJson(dynamic j) {
    final m = j as Map<String, dynamic>;
    return JavaInstallProgress(
      phase: m['phase'] as String? ?? '',
      message: m['message'] as String? ?? '',
      progress: (m['progress'] as num?)?.toDouble(),
    );
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

List<String> _strList(dynamic v) =>
    (v as List?)
        ?.map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList() ??
    const [];

Future<T> _invoke<T>(
  String method,
  Map<String, dynamic>? params,
  T Function(dynamic) cast,
) async {
  final value = await _ffi.call(method, params);
  return cast(value);
}

Stream<T> _invokeStream<T>(
  String method,
  Map<String, dynamic>? params,
  T Function(dynamic) cast,
) {
  return _ffi.callStream(method, params).map(cast);
}

// ---------------------------------------------------------------------------
// 类型化 API（与 rust/src/dispatch.rs 一一对应）
// ---------------------------------------------------------------------------

/// 应用初始化：解析便携目录、创建子目录、初始化日志
Future<AppInfo> initApp() => _invoke(
  'init_app',
  null,
  (v) => AppInfo.fromJson((v as Map).cast<String, dynamic>()),
);

// ---------- 设置 ----------

Future<SettingsData> getSettings() => _invoke(
  'get_settings',
  null,
  (v) => SettingsData.fromJson((v as Map).cast<String, dynamic>()),
);

Future<void> saveSettings({required SettingsData settings}) =>
    _invoke('save_settings', {'settings': settings.toJson()}, (_) {});

Future<String> effectiveGameDirectory() =>
    _invoke('effective_game_directory', null, (v) => v as String? ?? '');

Future<void> setLastVersion({required String versionId}) =>
    _invoke('set_last_version', {'versionId': versionId}, (_) {});

Future<void> setLastAccount({required String accountId}) =>
    _invoke('set_last_account', {'accountId': accountId}, (_) {});

Future<VersionSettingsData> getVersionSettings({
  required String gameDir,
  required String versionId,
}) => _invoke('get_version_settings', {
  'gameDir': gameDir,
  'versionId': versionId,
}, (v) => VersionSettingsData.fromJson((v as Map).cast<String, dynamic>()));

Future<void> saveVersionSettings({
  required String gameDir,
  required String versionId,
  required VersionSettingsData settings,
}) => _invoke('save_version_settings', {
  'gameDir': gameDir,
  'versionId': versionId,
  'settings': settings.toJson(),
}, (_) {});

// ---------- 账户 ----------

Future<List<Account>> listAccounts() => _invoke(
  'list_accounts',
  null,
  (v) => ((v as List?) ?? const []).map(Account.fromJson).toList(),
);

Future<Account?> getCurrentAccount() => _invoke(
  'get_current_account',
  null,
  (v) => v == null ? null : Account.fromJson(v),
);

Future<Account> addOfflineAccount({required String name}) =>
    _invoke('add_offline_account', {'name': name}, Account.fromJson);

Future<void> selectAccount({required String id}) =>
    _invoke('select_account', {'id': id}, (_) {});

Future<void> removeAccount({required String id}) =>
    _invoke('remove_account', {'id': id}, (_) {});

Future<void> saveAccount({required Account account}) =>
    _invoke('save_account', {'account': account.toJson()}, (_) {});

/// 微软设备码登录（过程事件流；结束时返回已保存账户——流值即账户 JSON）
Stream<MsLoginEvent> microsoftLogin() =>
    _invokeStream('microsoft_login', null, MsLoginEvent.fromJson);

Future<Account> microsoftRefresh({required String refreshToken}) => _invoke(
  'microsoft_refresh',
  {'refreshToken': refreshToken},
  Account.fromJson,
);

Future<YggdrasilSession> yggdrasilLogin({
  required String serverUrl,
  required String username,
  required String password,
}) => _invoke('yggdrasil_login', {
  'serverUrl': serverUrl,
  'username': username,
  'password': password,
}, YggdrasilSession.fromJson);

Future<Account> saveYggdrasilAccount({
  required String apiRoot,
  required String accessToken,
  required String clientToken,
  required String profileId,
  required String profileName,
}) => _invoke('save_yggdrasil_account', {
  'apiRoot': apiRoot,
  'accessToken': accessToken,
  'clientToken': clientToken,
  'profileId': profileId,
  'profileName': profileName,
}, Account.fromJson);

Future<String> yggdrasilValidateOrRefresh({
  required String apiRoot,
  required String accessToken,
  required String clientToken,
}) => _invoke('yggdrasil_validate_or_refresh', {
  'apiRoot': apiRoot,
  'accessToken': accessToken,
  'clientToken': clientToken,
}, (v) => v as String? ?? '');

/// 确保 authlib-injector.jar 就绪（exe 所在目录\FMCL\lib\authlib-injector）
Future<String> ensureAuthlibInjector() =>
    _invoke('ensure_authlib_injector', null, (v) => v as String? ?? '');

// ---------- 版本管理 ----------

Future<List<LocalVersionInfo>> scanLocalVersions({required String gameDir}) =>
    _invoke(
      'scan_local_versions',
      {'gameDir': gameDir},
      (v) => ((v as List?) ?? const []).map(LocalVersionInfo.fromJson).toList(),
    );

Future<String> importExternalVersion({
  required String gameDir,
  required String sourceDir,
  required String newName,
}) => _invoke('import_external_version', {
  'gameDir': gameDir,
  'sourceDir': sourceDir,
  'newName': newName,
}, (v) => v as String? ?? '');

Future<void> deleteVersion({
  required String gameDir,
  required String versionId,
}) => _invoke('delete_version', {
  'gameDir': gameDir,
  'versionId': versionId,
}, (_) {});

Future<void> renameVersion({
  required String gameDir,
  required String versionId,
  required String newName,
}) => _invoke('rename_version', {
  'gameDir': gameDir,
  'versionId': versionId,
  'newName': newName,
}, (_) {});

Future<void> copyVersion({
  required String gameDir,
  required String versionId,
  required String newName,
}) => _invoke('copy_version', {
  'gameDir': gameDir,
  'versionId': versionId,
  'newName': newName,
}, (_) {});

/// 补全版本全部文件（流式进度）
Stream<InstallProgressEvent> completeVersion({
  required String gameDir,
  required String versionId,
  required bool bmclapiFirst,
  required int concurrency,
  required String sessionId,
}) => _invokeStream('complete_version', {
  'gameDir': gameDir,
  'versionId': versionId,
  'bmclapiFirst': bmclapiFirst,
  'concurrency': concurrency,
  'sessionId': sessionId,
}, InstallProgressEvent.fromJson);

// ---------- 清单 ----------

Future<List<RemoteVersionEntry>> fetchRemoteVersions({
  required bool bmclapiFirst,
}) => _invoke('fetch_remote_versions', {
  'bmclapiFirst': bmclapiFirst,
}, (v) => ((v as List?) ?? const []).map(RemoteVersionEntry.fromJson).toList());

Future<List<LoaderVersionInfo>> fetchLoaderVersions({
  required String loader,
  required String mcVersion,
  required bool bmclapiFirst,
}) => _invoke('fetch_loader_versions', {
  'loader': loader,
  'mcVersion': mcVersion,
  'bmclapiFirst': bmclapiFirst,
}, (v) => ((v as List?) ?? const []).map(LoaderVersionInfo.fromJson).toList());

// ---------- Java ----------

Future<List<JavaInfo>> detectJavas({List<String> extraDirs = const []}) =>
    _invoke('detect_javas', {
      'extraDirs': extraDirs,
    }, (v) => ((v as List?) ?? const []).map(JavaInfo.fromJson).toList());

Future<JavaInfo> validateJava({required String javaPath}) =>
    _invoke('validate_java', {'javaPath': javaPath}, JavaInfo.fromJson);

/// 自动安装 Java（Adoptium，流式进度）
Stream<JavaInstallProgress> downloadJava({
  required int major,
  required String sessionId,
}) => _invokeStream('download_java', {
  'major': major,
  'sessionId': sessionId,
}, JavaInstallProgress.fromJson);

Future<void> removeJava({required int major}) =>
    _invoke('remove_java', {'major': major}, (_) {});

// ---------- 安装 / 整合包 ----------

/// 合并安装（原版 + 加载器 + OptiFine，流式进度）
Stream<InstallProgressEvent> installCombined({
  required InstallRequest request,
}) => _invokeStream('install_combined', {
  'request': request.toJson(),
}, InstallProgressEvent.fromJson);

/// 安装整合包（流式进度），流关闭后返回新版本名（经完成值）
Stream<ModpackProgressEvent> installModpack({
  required String zipPath,
  required String gameDir,
  required String instanceName,
  required String javaPath,
  required bool useBmclapi,
  required int concurrency,
  required String sessionId,
}) => _invokeStream('install_modpack', {
  'zipPath': zipPath,
  'gameDir': gameDir,
  'instanceName': instanceName,
  'javaPath': javaPath,
  'useBmclapi': useBmclapi,
  'concurrency': concurrency,
  'sessionId': sessionId,
}, ModpackProgressEvent.fromJson);

Future<ModpackManifest> parseModpack({required String zipPath}) =>
    _invoke('parse_modpack', {'zipPath': zipPath}, ModpackManifest.fromJson);

// ---------- 内容下载 ----------

Future<List<SearchHit>> searchContent({
  required String query,
  required String category,
  required String mcVersion,
  required String loader,
  required int index,
}) => _invoke('search_content', {
  'query': query,
  'category': category,
  'mcVersion': mcVersion,
  'loader': loader,
  'index': index,
}, (v) => ((v as List?) ?? const []).map(SearchHit.fromJson).toList());

Future<List<ContentFile>> listProjectFiles({required String projectId}) =>
    _invoke('list_project_files', {
      'projectId': projectId,
    }, (v) => ((v as List?) ?? const []).map(ContentFile.fromJson).toList());

Future<String> installContentFile({
  required String gameDir,
  required String versionId,
  required String category,
  required String downloadUrl,
  required String filename,
  required String sessionId,
}) => _invoke('install_content_file', {
  'gameDir': gameDir,
  'versionId': versionId,
  'category': category,
  'downloadUrl': downloadUrl,
  'filename': filename,
  'sessionId': sessionId,
}, (v) => v as String? ?? '');

Future<List<InstalledContent>> listInstalledContents({
  required String gameDir,
  required String versionId,
  required String category,
}) => _invoke('list_installed_contents', {
  'gameDir': gameDir,
  'versionId': versionId,
  'category': category,
}, (v) => ((v as List?) ?? const []).map(InstalledContent.fromJson).toList());

Future<void> deleteContentFile({required String path}) =>
    _invoke('delete_content_file', {'path': path}, (_) {});

// ---------- 启动器日志 ----------

/// 订阅启动器实时日志（Rust broadcast → 事件流）
Stream<LogEntry> subscribeAppLogs() => _ffi.appLogEvents.map(LogEntry.fromJson);

Future<List<LogEntry>> readRecentLogs({required int maxLines}) => _invoke(
  'read_recent_logs',
  {'maxLines': maxLines},
  (v) => ((v as List?) ?? const []).map(LogEntry.fromJson).toList(),
);

Future<String> readLogFile({required String path, required int maxLines}) =>
    _invoke('read_log_file', {
      'path': path,
      'maxLines': maxLines,
    }, (v) => v as String? ?? '');

Future<List<LogFileMeta>> listLogFiles() => _invoke(
  'list_log_files',
  null,
  (v) => ((v as List?) ?? const []).map(LogFileMeta.fromJson).toList(),
);

Future<void> openPath({required String path}) =>
    _invoke('open_path', {'path': path}, (_) {});

// ---------- 启动 ----------

/// 启动游戏（完整管线在 Rust；过程事件流）
Stream<LaunchEvent> launchGame({required LaunchOptions options}) =>
    _invokeStream('launch_game', {
      'options': options.toJson(),
    }, LaunchEvent.fromJson);

/// 终止启动会话（下载阶段取消下载；游戏运行阶段终止进程）
Future<void> terminateLaunch({required String sessionId}) =>
    _invoke('terminate_launch', {'sessionId': sessionId}, (_) {});
