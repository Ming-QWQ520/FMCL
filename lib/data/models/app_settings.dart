/// 启动器全局设置模型（持久化到 JSON）。
class AppSettings {
  // ---------- 外观 ----------
  /// 0=跟随系统 1=浅色 2=深色
  final int themeMode;

  /// 自定义背景图片绝对路径（空 = 无背景）
  final String backgroundImagePath;

  /// 背景图不透明度 0~100
  final int backgroundOpacity;

  /// 背景图模糊强度 0~50
  final int backgroundBlur;

  // ---------- 目录 ----------
  /// 游戏根目录（.minecraft 位置）
  final String gameDirectory;

  /// 自定义 Java 搜索目录
  final List<String> javaSearchPaths;

  // ---------- 启动 ----------
  /// 最大内存（MiB）
  final int maxMemoryMb;

  /// 最小内存（MiB）
  final int minMemoryMb;

  /// 额外 JVM 参数
  final String jvmArguments;

  /// 额外游戏参数
  final String gameArguments;

  /// Java 可执行文件（空=自动选择）
  final String javaPath;

  /// 启动后行为：0=保持启动器 1=隐藏 2=关闭
  final int launcherBehavior;

  /// 全屏启动
  final bool fullscreen;

  /// 窗口宽高（0=默认）
  final int windowWidth;
  final int windowHeight;

  // ---------- 下载 ----------
  /// 下载源：0=BMCLAPI优先(默认) 1=官方优先
  final int downloadSourceIndex;

  /// 自动回退到备用源
  final bool autoFallback;

  /// 下载并发数
  final int concurrency;

  /// 是否校验文件（关闭可提速，但 risking 损坏）
  final bool verifyFiles;

  // ---------- 版本管理 ----------
  /// 版本隔离（PCL2 式）：每个版本使用独立的游戏目录（saves/config/mods 等），
  /// libraries/assets 仍共享根目录。默认开启。
  final bool versionIsolation;

  /// 缺失 Java 时自动从 Adoptium 下载安装
  final bool autoInstallJava;

  // ---------- 账户 ----------
  /// 上次使用的账户 UUID
  final String lastAccountId;

  // ---------- 其它 ----------
  /// 上次启动的版本 id
  final String lastVersionId;

  /// 首次启动完成标记
  final bool onboarded;

  const AppSettings({
    this.themeMode = 0,
    this.backgroundImagePath = '',
    this.backgroundOpacity = 45,
    this.backgroundBlur = 0,
    required this.gameDirectory,
    this.javaSearchPaths = const [],
    this.maxMemoryMb = 2048,
    this.minMemoryMb = 512,
    this.jvmArguments = '',
    this.gameArguments = '',
    this.javaPath = '',
    this.launcherBehavior = 1,
    this.fullscreen = false,
    this.windowWidth = 0,
    this.windowHeight = 0,
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

  AppSettings copyWith({
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
    bool? fullscreen,
    int? windowWidth,
    int? windowHeight,
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
    return AppSettings(
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
      fullscreen: fullscreen ?? this.fullscreen,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
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

  // ---------------- JSON ----------------

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        themeMode: json['themeMode'] as int? ?? 0,
        backgroundImagePath: json['backgroundImagePath'] as String? ?? '',
        backgroundOpacity: json['backgroundOpacity'] as int? ?? 45,
        backgroundBlur: json['backgroundBlur'] as int? ?? 0,
        gameDirectory:
            json['gameDirectory'] as String? ?? '',
        javaSearchPaths: (json['javaSearchPaths'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        maxMemoryMb: json['maxMemoryMb'] as int? ?? 2048,
        minMemoryMb: json['minMemoryMb'] as int? ?? 512,
        jvmArguments: json['jvmArguments'] as String? ?? '',
        gameArguments: json['gameArguments'] as String? ?? '',
        javaPath: json['javaPath'] as String? ?? '',
        launcherBehavior: json['launcherBehavior'] as int? ?? 1,
        fullscreen: json['fullscreen'] as bool? ?? false,
        windowWidth: json['windowWidth'] as int? ?? 0,
        windowHeight: json['windowHeight'] as int? ?? 0,
        downloadSourceIndex: json['downloadSourceIndex'] as int? ?? 0,
        autoFallback: json['autoFallback'] as bool? ?? true,
        concurrency: json['concurrency'] as int? ?? 32,
        verifyFiles: json['verifyFiles'] as bool? ?? true,
        versionIsolation: json['versionIsolation'] as bool? ?? true,
        autoInstallJava: json['autoInstallJava'] as bool? ?? true,
        lastAccountId: json['lastAccountId'] as String? ?? '',
        lastVersionId: json['lastVersionId'] as String? ?? '',
        onboarded: json['onboarded'] as bool? ?? false,
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
        'fullscreen': fullscreen,
        'windowWidth': windowWidth,
        'windowHeight': windowHeight,
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
