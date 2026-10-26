import '../../core/constants/app_constants.dart';

/// 下载源类型
enum DownloadSourceKind { official, bmclapi }

/// 下载源抽象。
///
/// FMCL 采用"镜像优先 + 官方回退"策略：
/// 所有资源 URL 在拼装阶段即经过 [map] 映射，
/// 下载失败时由上层自动切换到备用源重试。
abstract class DownloadSource {
  const DownloadSource();

  DownloadSourceKind get kind;
  String get displayName;

  /// 版本清单 URL
  String get versionManifestUrl;

  /// 库文件根（maven 布局）
  String get librariesBase;

  /// 资源（assets）根
  String get assetsBase;

  /// 客户端 jar 等版本文件的 URL 映射（launchermeta → 镜像）
  String mapVersionJsonUrl(String url);

  /// 通用 URL 映射（把官方域替换为镜像域）
  String mapUrl(String url) {
    if (kind == DownloadSourceKind.official) return url;
    return url
        .replaceFirst('launchermeta.mojang.com', 'bmclapi2.bangbang93.com')
        .replaceFirst('piston-meta.mojang.com', 'bmclapi2.bangbang93.com')
        .replaceFirst('resources.download.minecraft.net', 'bmclapi2.bangbang93.com/assets')
        .replaceFirst('libraries.minecraft.net', 'bmclapi2.bangbang93.com/maven')
        .replaceFirst('piston-data.mojang.com', 'bmclapi2.bangbang93.com');
  }
}

/// Mojang 官方源
class OfficialSource extends DownloadSource {
  const OfficialSource();

  @override
  DownloadSourceKind get kind => DownloadSourceKind.official;

  @override
  String get displayName => 'Mojang 官方';

  @override
  String get versionManifestUrl => AppConstants.officialVersionManifest;

  @override
  String get librariesBase => AppConstants.officialLibraries;

  @override
  String get assetsBase => AppConstants.officialResources;

  @override
  String mapVersionJsonUrl(String url) => url;
}

/// BMCLAPI 镜像源
class BmclapiSource extends DownloadSource {
  const BmclapiSource();

  @override
  DownloadSourceKind get kind => DownloadSourceKind.bmclapi;

  @override
  String get displayName => 'BMCLAPI 镜像';

  @override
  String get versionManifestUrl => AppConstants.bmclapiVersionManifest;

  @override
  String get librariesBase => AppConstants.bmclapiLibraries;

  @override
  String get assetsBase => AppConstants.bmclapiResources;

  @override
  String mapVersionJsonUrl(String url) => mapUrl(url);
}

/// 下载源注册表
class DownloadSources {
  DownloadSources._();

  static const DownloadSource official = OfficialSource();
  static const DownloadSource bmclapi = BmclapiSource();

  /// 按类型取源
  static DownloadSource of(DownloadSourceKind kind) =>
      kind == DownloadSourceKind.bmclapi ? bmclapi : official;

  /// 主源 + 回退源（镜像主用 → 官方回退；官方主用 → 镜像回退）
  static (DownloadSource, DownloadSource) pairOf(DownloadSourceKind kind) =>
      kind == DownloadSourceKind.bmclapi
          ? (bmclapi, official)
          : (official, bmclapi);
}
