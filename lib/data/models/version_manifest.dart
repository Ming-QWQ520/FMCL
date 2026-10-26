/// 版本清单模型（version_manifest_v2.json）
class VersionManifest {
  final Latest latest;
  final List<VersionEntry> versions;

  const VersionManifest({required this.latest, required this.versions});

  factory VersionManifest.fromJson(Map<String, dynamic> json) =>
      VersionManifest(
        latest: Latest.fromJson(json['latest'] as Map<String, dynamic>? ?? {}),
        versions: (json['versions'] as List<dynamic>? ?? [])
            .map((e) => VersionEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'latest': latest.toJson(),
    'versions': versions.map((e) => e.toJson()).toList(),
  };
}

class Latest {
  final String release;
  final String snapshot;

  const Latest({required this.release, required this.snapshot});

  factory Latest.fromJson(Map<String, dynamic> json) => Latest(
    release: json['release'] as String? ?? '',
    snapshot: json['snapshot'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'release': release, 'snapshot': snapshot};
}

class VersionEntry {
  final String id;
  final String type;
  final String url;
  final String? releaseTime;

  const VersionEntry({
    required this.id,
    required this.type,
    required this.url,
    this.releaseTime,
  });

  factory VersionEntry.fromJson(Map<String, dynamic> json) => VersionEntry(
    id: json['id'] as String,
    type: json['type'] as String? ?? 'release',
    url: json['url'] as String? ?? '',
    releaseTime: json['releaseTime'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'url': url,
    if (releaseTime != null) 'releaseTime': releaseTime,
  };

  bool get isRelease => type == 'release';
  bool get isSnapshot => type == 'snapshot';
  bool get isOld => type == 'old_alpha' || type == 'old_beta';
}
