/// FMCL 全局常量。
class AppConstants {
  AppConstants._();

  /// 应用名称
  static const String appName = 'FMCL';

  /// 应用全称
  static const String appFullName = 'Fluent Minecraft Launcher';

  /// 版本号（与 pubspec version 同步）
  static const String appVersion = '0.1.0';

  /// 仓库地址
  static const String repoUrl = 'https://github.com/Ming-QWQ520/FMCL';

  /// HTTP User-Agent
  static const String userAgent =
      'FMCL/$appVersion (github.com/Ming-QWQ520/FMCL)';

  // ---------------- 默认下载源 ----------------

  /// Mojang 官方版本清单
  static const String officialVersionManifest =
      'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json';

  /// Mojang 官方资源根
  static const String officialResources =
      'https://resources.download.minecraft.net';

  /// Mojang 官方库根
  static const String officialLibraries =
      'https://libraries.minecraft.net';

  /// BMCLAPI 版本清单（bangbang93 镜像）
  static const String bmclapiVersionManifest =
      'https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json';

  /// BMCLAPI 资源根
  static const String bmclapiResources = 'https://bmclapi2.bangbang93.com/assets';

  /// BMCLAPI 库根
  static const String bmclapiLibraries = 'https://bmclapi2.bangbang93.com/maven';

  /// authlib-injector 下载地址
  static const String authlibInjectorUrl =
      'https://authlib-injector.yushi.moe/artifact/latest.json';

  // ---------------- 元数据 API ----------------

  /// Fabric Meta
  static const String fabricMeta = 'https://meta.fabricmc.net/v2';

  /// Quilt Meta
  static const String quiltMeta = 'https://meta.quiltmc.org/v3';

  /// Forge maven
  static const String forgeMaven = 'https://maven.minecraftforge.net';

  /// NeoForge maven
  static const String neoforgeMaven = 'https://maven.neoforged.net/releases';

  /// Modrinth API
  static const String modrinthApi = 'https://api.modrinth.com/v2';

  // ---------------- 默认值 ----------------

  /// 默认最大内存（MiB）
  static const int defaultMemoryMb = 2048;

  /// 默认 JVM 初始堆（MiB）
  static const int defaultMinMemoryMb = 512;

  /// 支持的加载器列表
  static const List<String> supportedLoaders = [
    'vanilla',
    'fabric',
    'forge',
    'neoforge',
    'quilt',
  ];
}
