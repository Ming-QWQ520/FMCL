/// Minecraft 版本 JSON 完整模型。
///
/// 支持 `inheritsFrom` 依赖链解析（Forge/Fabric 版本 JSON 继承原版）。
class GameVersionJson {
  final String id;
  final String mainClass;
  final String? inheritsFrom;
  final String? type;
  final String? releaseTime;
  final int? complianceLevel;
  final AssetIndexRef? assetIndex;
  final String? assets;
  final ClientDownloadRef? downloads;
  final List<Library> libraries;
  final ArgumentsSet? arguments;

  /// 1.13 前的旧版合并参数串
  final String? minecraftArguments;
  final JavaVersionRef? javaVersion;
  final LoggingConfig? logging;
  final Map<String, dynamic> raw;

  const GameVersionJson({
    required this.id,
    required this.mainClass,
    this.inheritsFrom,
    this.type,
    this.releaseTime,
    this.complianceLevel,
    this.assetIndex,
    this.assets,
    this.downloads,
    this.libraries = const [],
    this.arguments,
    this.minecraftArguments,
    this.javaVersion,
    this.logging,
    this.raw = const {},
  });

  factory GameVersionJson.fromJson(Map<String, dynamic> json) {
    return GameVersionJson(
      id: json['id'] as String? ?? '',
      mainClass: json['mainClass'] as String? ?? '',
      inheritsFrom: json['inheritsFrom'] as String?,
      type: json['type'] as String?,
      releaseTime: json['releaseTime'] as String?,
      complianceLevel: json['complianceLevel'] as int?,
      assetIndex: json['assetIndex'] == null
          ? null
          : AssetIndexRef.fromJson(json['assetIndex'] as Map<String, dynamic>),
      assets: json['assets'] as String?,
      downloads: json['downloads'] == null
          ? null
          : ClientDownloadRef.fromJson(
              json['downloads'] as Map<String, dynamic>,
            ),
      libraries: (json['libraries'] as List<dynamic>? ?? [])
          .map((e) => Library.fromJson(e as Map<String, dynamic>))
          .toList(),
      arguments: json['arguments'] == null
          ? null
          : ArgumentsSet.fromJson(json['arguments'] as Map<String, dynamic>),
      minecraftArguments: json['minecraftArguments'] as String?,
      javaVersion: json['javaVersion'] == null
          ? null
          : JavaVersionRef.fromJson(
              json['javaVersion'] as Map<String, dynamic>,
            ),
      logging: json['logging'] == null
          ? null
          : LoggingConfig.fromJson(json['logging'] as Map<String, dynamic>),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw;
}

/// 资源索引引用
class AssetIndexRef {
  final String id;
  final String url;
  final String? sha1;
  final int size;
  final int totalSize;

  const AssetIndexRef({
    required this.id,
    required this.url,
    this.sha1,
    this.size = 0,
    this.totalSize = 0,
  });

  factory AssetIndexRef.fromJson(Map<String, dynamic> json) => AssetIndexRef(
    id: json['id'] as String? ?? '',
    url: json['url'] as String? ?? '',
    sha1: json['sha1'] as String?,
    size: json['size'] as int? ?? 0,
    totalSize: json['totalSize'] as int? ?? 0,
  );
}

/// 客户端/服务端下载引用
class ClientDownloadRef {
  final DownloadableFile? client;
  final DownloadableFile? server;

  const ClientDownloadRef({this.client, this.server});

  factory ClientDownloadRef.fromJson(Map<String, dynamic> json) =>
      ClientDownloadRef(
        client: json['client'] == null
            ? null
            : DownloadableFile.fromJson(json['client'] as Map<String, dynamic>),
        server: json['server'] == null
            ? null
            : DownloadableFile.fromJson(json['server'] as Map<String, dynamic>),
      );
}

/// 可下载文件描述
class DownloadableFile {
  final String url;
  final String? sha1;
  final int size;
  final String? path;

  const DownloadableFile({
    required this.url,
    this.sha1,
    this.size = 0,
    this.path,
  });

  factory DownloadableFile.fromJson(Map<String, dynamic> json) =>
      DownloadableFile(
        url: json['url'] as String? ?? '',
        sha1: json['sha1'] as String?,
        size: json['size'] as int? ?? 0,
        path: json['path'] as String?,
      );
}

/// 库规则中的操作系统信息
class OsRule {
  final String? name;
  final String? arch;

  const OsRule({this.name, this.arch});

  factory OsRule.fromJson(Map<String, dynamic> json) =>
      OsRule(name: json['name'] as String?, arch: json['arch'] as String?);
}

/// 库加载规则（allow/disallow）
class LibraryRule {
  final String action;
  final OsRule? os;

  const LibraryRule({required this.action, this.os});

  factory LibraryRule.fromJson(Map<String, dynamic> json) => LibraryRule(
    action: json['action'] as String,
    os: json['os'] == null ? null : OsRule.fromJson(json['os']),
  );
}

/// natives 分类器描述
class NativesMap {
  final String? linux;
  final String? windows;
  final String? osx;

  const NativesMap({this.linux, this.windows, this.osx});

  factory NativesMap.fromJson(Map<String, dynamic> json) => NativesMap(
    linux: json['linux'] as String?,
    windows: json['windows'] as String?,
    osx: json['osx'] as String?,
  );
}

/// 解压规则
class ExtractRule {
  final List<String> exclude;

  const ExtractRule({this.exclude = const []});

  factory ExtractRule.fromJson(Map<String, dynamic> json) => ExtractRule(
    exclude: (json['exclude'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList(),
  );
}

class LibraryDownloads {
  final DownloadableFile? artifact;
  final Map<String, DownloadableFile> classifiers;

  const LibraryDownloads({this.artifact, this.classifiers = const {}});

  factory LibraryDownloads.fromJson(Map<String, dynamic> json) =>
      LibraryDownloads(
        artifact: json['artifact'] == null
            ? null
            : DownloadableFile.fromJson(
                json['artifact'] as Map<String, dynamic>,
              ),
        classifiers: (json['classifiers'] as Map<String, dynamic>? ?? {}).map(
          (k, v) =>
              MapEntry(k, DownloadableFile.fromJson(v as Map<String, dynamic>)),
        ),
      );
}

/// 库条目
class Library {
  final String name;
  final List<LibraryRule>? rules;
  final NativesMap? natives;
  final LibraryDownloads? downloads;

  /// Forge 等自定义 maven 根（无 downloads 键时按 maven 布局拼接）
  final String? url;
  final ExtractRule? extract;

  const Library({
    required this.name,
    this.rules,
    this.natives,
    this.downloads,
    this.url,
    this.extract,
  });

  factory Library.fromJson(Map<String, dynamic> json) => Library(
    name: json['name'] as String,
    rules: (json['rules'] as List<dynamic>?)
        ?.map((e) => LibraryRule.fromJson(e as Map<String, dynamic>))
        .toList(),
    natives: json['natives'] == null
        ? null
        : NativesMap.fromJson(json['natives'] as Map<String, dynamic>),
    downloads: json['downloads'] == null
        ? null
        : LibraryDownloads.fromJson(json['downloads'] as Map<String, dynamic>),
    url: json['url'] as String?,
    extract: json['extract'] == null
        ? null
        : ExtractRule.fromJson(json['extract'] as Map<String, dynamic>),
  );

  /// maven 坐标: group:artifact:version[:classifier][@ext]
  ///
  /// 支持 Forge 安装器的 @ext 记法（如
  /// `de.oceanlabs.mcp:mcp_config:1.20.1-...@zip`、`...:mappings@txt`）。
  static (String group, String artifact, String version, String? classifier,
      String ext)
  parseMaven(String name) {
    // 拆分 @ext 后缀（最后一个 @，且不与坐标段落冲突）
    var base = name;
    var ext = 'jar';
    final at = base.lastIndexOf('@');
    if (at > 0) {
      final e = base.substring(at + 1);
      if (e.isNotEmpty && !e.contains(':') && _isSafeExt(e)) {
        ext = e;
        base = base.substring(0, at);
      }
    }
    final segs = base.split(':');
    final group = segs[0];
    final artifact = segs[1];
    final version = segs[2];
    String? classifier = segs.length > 3 ? segs[3] : null;
    // 处理 version-classifier 连写（如 1.2.3-client）
    if (classifier == null && version.contains('-')) {
      final parts = version.split('-');
      if (parts.length == 2 && (parts[1] == 'client' || parts[1] == 'server')) {
        // 谨慎：部分库版本号本身含连字符，仅在匹配已知后缀时拆分
        classifier = parts[1];
      }
    }
    return (group, artifact, version, classifier, ext);
  }

  static bool _isSafeExt(String ext) {
    return ext.length <= 8 &&
        ext.codeUnits.every((c) =>
            (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39));
  }

  /// 相对路径（maven 布局）
  String get path {
    final (g, a, v, c, ext) = parseMaven(name);
    final fileName = c == null ? '$a-$v.$ext' : '$a-$v-$c.$ext';
    return '${g.replaceAll('.', '/')}/$a/$v/$fileName';
  }

  /// 按当前平台取 natives 分类器名（如 natives-windows）
  String? nativeClassifierFor(String osName, String arch) {
    final key = switch (osName) {
      'windows' => natives?.windows,
      'linux' => natives?.linux,
      'osx' => natives?.osx,
      _ => null,
    };
    if (key == null) return null;
    // 处理 arch 后缀（1.19+ 分离 arm64/x86_64）
    if (arch == 'aarch64') {
      final armKey = key.contains('-arm64') ? key : '$key-arm64';
      final f = downloads?.classifiers[armKey];
      if (f != null) return armKey;
    }
    return key;
  }

  /// 规则判断（os: windows/linux/osx）
  bool isAllowedOn(String osName, String arch) {
    if (rules == null || rules!.isEmpty) return true;
    var allowed = false;
    for (final rule in rules!) {
      final osMatch =
          rule.os == null ||
          (rule.os!.name == osName && _archMatch(rule.os!.arch, arch));
      if (!osMatch) continue;
      if (rule.action == 'allow') {
        allowed = true;
      } else if (rule.action == 'disallow') {
        allowed = false;
      }
    }
    return allowed;
  }

  static bool _archMatch(String? ruleArch, String arch) {
    if (ruleArch == null) return true;
    return ruleArch == arch;
  }
}

/// 新版参数集（1.13+）
class ArgumentsSet {
  final List<dynamic> game;
  final List<dynamic> jvm;

  const ArgumentsSet({this.game = const [], this.jvm = const []});

  factory ArgumentsSet.fromJson(Map<String, dynamic> json) => ArgumentsSet(
    game: json['game'] as List<dynamic>? ?? [],
    jvm: json['jvm'] as List<dynamic>? ?? [],
  );
}

class JavaVersionRef {
  final String component;
  final int majorVersion;

  const JavaVersionRef({required this.component, required this.majorVersion});

  factory JavaVersionRef.fromJson(Map<String, dynamic> json) => JavaVersionRef(
    component: json['component'] as String? ?? 'java-runtime-gamma',
    majorVersion: json['majorVersion'] as int? ?? 8,
  );
}

/// 日志配置（log4j xml，用于 1.12+ 崩溃信息规范化）
class LoggingConfig {
  final Map<String, dynamic> raw;

  const LoggingConfig({this.raw = const {}});

  factory LoggingConfig.fromJson(Map<String, dynamic> json) =>
      LoggingConfig(raw: json);

  DownloadableFile? get clientFile {
    final client = raw['client'] as Map<String, dynamic>?;
    final file = client?['file'] as Map<String, dynamic>?;
    if (file == null) return null;
    return DownloadableFile.fromJson(file);
  }

  String? get clientArgument {
    final client = raw['client'] as Map<String, dynamic>?;
    return client?['argument'] as String?;
  }
}
