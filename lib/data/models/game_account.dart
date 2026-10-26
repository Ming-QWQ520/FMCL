/// 账户类型
enum AccountType { offline, microsoft, yggdrasil }

/// 统一账户模型。
///
/// - 离线账户：本地生成 UUID（离线模式哈希，与官方离线算法一致）
/// - 微软账户：OAuth 设备码流程获取 XSTS → Minecraft Services Token
/// - Yggdrasil 外置账户：authlib-injector 兼容服务端（LittleSkin 等）
class GameAccount {
  final String id;
  final AccountType type;
  final String name;

  /// 访问令牌（微软为 MC Services JWT；离线为 0）
  final String accessToken;

  /// 官方 UUID（离线为离线模式 UUID）
  final String uuid;

  /// Yggdrasil 专用：认证服务器 API 根（如 https://littleskin.cn/api/yggdrasil）
  final String? yggdrasilServer;

  /// Yggdrasil 专用：角色 profile id
  final String? profileId;

  /// 令牌过期时间（毫秒时间戳；离线账户为 0）
  final int expiresAt;

  /// 皮肤 URL（可空）
  final String? skinUrl;

  /// 刷新令牌（微软账户）
  final String? refreshToken;

  const GameAccount({
    required this.id,
    required this.type,
    required this.name,
    required this.accessToken,
    required this.uuid,
    this.yggdrasilServer,
    this.profileId,
    this.expiresAt = 0,
    this.skinUrl,
    this.refreshToken,
  });

  bool get isOffline => type == AccountType.offline;

  bool get isTokenExpired =>
      type == AccountType.microsoft &&
      expiresAt > 0 &&
      DateTime.now().millisecondsSinceEpoch >= expiresAt - 60_000;

  String get typeLabel => switch (type) {
    AccountType.offline => '离线',
    AccountType.microsoft => '微软',
    AccountType.yggdrasil => '外置',
  };

  GameAccount copyWith({
    String? accessToken,
    String? refreshToken,
    int? expiresAt,
    String? name,
    String? skinUrl,
  }) {
    return GameAccount(
      id: id,
      type: type,
      name: name ?? this.name,
      accessToken: accessToken ?? this.accessToken,
      uuid: uuid,
      yggdrasilServer: yggdrasilServer,
      profileId: profileId,
      expiresAt: expiresAt ?? this.expiresAt,
      skinUrl: skinUrl ?? this.skinUrl,
      refreshToken: refreshToken ?? this.refreshToken,
    );
  }

  factory GameAccount.fromJson(Map<String, dynamic> json) => GameAccount(
    id: json['id'] as String,
    type: AccountType.values.byName(json['type'] as String),
    name: json['name'] as String,
    accessToken: json['accessToken'] as String? ?? '',
    uuid: json['uuid'] as String? ?? '',
    yggdrasilServer: json['yggdrasilServer'] as String?,
    profileId: json['profileId'] as String?,
    expiresAt: json['expiresAt'] as int? ?? 0,
    skinUrl: json['skinUrl'] as String?,
    refreshToken: json['refreshToken'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'name': name,
    'accessToken': accessToken,
    'uuid': uuid,
    if (yggdrasilServer != null) 'yggdrasilServer': yggdrasilServer,
    if (profileId != null) 'profileId': profileId,
    'expiresAt': expiresAt,
    if (skinUrl != null) 'skinUrl': skinUrl,
    if (refreshToken != null) 'refreshToken': refreshToken,
  };
}
