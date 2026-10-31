import 'package:flutter/material.dart';

/// 加载器 / 原版图标（HMCL 图片资产，assets/img/hmcl/）。
///
/// - 原版 → 草方块（grass.png）
/// - Forge / Fabric / NeoForge / Quilt / OptiFine / LegacyFabric → 对应官方图标
class LoaderIcons {
  LoaderIcons._();

  /// 根据加载器类型取资产路径（fallback = 草方块）。
  static String assetForLoader(String loaderType) => switch (loaderType) {
        'forge' => 'assets/img/hmcl/forge.png',
        'fabric' => 'assets/img/hmcl/fabric.png',
        'neoforge' => 'assets/img/hmcl/neoforge.png',
        'quilt' => 'assets/img/hmcl/quilt.png',
        'optifine' => 'assets/img/hmcl/optifine.png',
        'legacyfabric' => 'assets/img/hmcl/legacyfabric.png',
        _ => 'assets/img/hmcl/grass.png',
      };

  /// 从版本 id 猜测加载器类型（PCL 式模糊识别）：
  /// `1.20.1-forge-47.2.0` / `fabric-loader-...` / `1.20.1-Forge` 等。
  static String loaderTypeOfVersionId(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('neoforge')) return 'neoforge';
    if (lower.contains('forge')) return 'forge';
    if (lower.contains('fabric')) return 'fabric';
    if (lower.contains('quilt')) return 'quilt';
    if (lower.contains('optifine') || lower.contains('optifine_')) {
      return 'optifine';
    }
    if (lower.contains('legacyfabric')) return 'legacyfabric';
    return 'vanilla';
  }

  /// 根据版本 id 取资产路径。
  static String assetForVersionId(String id) =>
      assetForLoader(loaderTypeOfVersionId(id));

  /// 加载器图标 Widget（像素风渲染，尺寸自适应）。
  static Widget icon(String loaderType, {double size = 20}) => Image.asset(
        assetForLoader(loaderType),
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Icon(
          Icons.videogame_asset_rounded,
          size: size,
        ),
      );
}
