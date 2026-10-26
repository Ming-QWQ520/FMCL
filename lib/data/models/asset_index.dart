/// 资源索引（assets index json）与资源对象。
class AssetIndex {
  final Map<String, AssetObject> objects;
  final bool virtual;
  final Map<String, dynamic> mappings;

  const AssetIndex({
    required this.objects,
    this.virtual = false,
    this.mappings = const {},
  });

  factory AssetIndex.fromJson(Map<String, dynamic> json) => AssetIndex(
        objects: (json['objects'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, AssetObject.fromJson(v as Map<String, dynamic>)),
        ),
        virtual: json['virtual'] as bool? ?? false,
        mappings: json['map_to_resources'] == null
            ? (json['mappings'] as Map<String, dynamic>? ?? {})
            : {},
      );

  /// 全部资源总大小
  int get totalSize =>
      objects.values.fold(0, (sum, o) => sum + o.size);
}

class AssetObject {
  /// 资源哈希（同时是存储相对路径的一部分）
  final String hash;
  final int size;

  const AssetObject({required this.hash, required this.size});

  factory AssetObject.fromJson(Map<String, dynamic> json) => AssetObject(
        hash: json['hash'] as String,
        size: json['size'] as int? ?? 0,
      );

  /// 存储相对路径：objects/<hash前2位>/<hash>
  String get storePath =>
      'objects/${hash.substring(0, 2)}/$hash';

  /// 下载 URL 路径段
  String get urlPath =>
      '${hash.substring(0, 2)}/$hash';
}
