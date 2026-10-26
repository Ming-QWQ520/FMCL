import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/game_account.dart';

/// 微软账户认证服务（OAuth 2.0 设备码流程）。
///
/// 流程：MSA 设备码 → Azure Token → Xbox Live XSTS → Minecraft Services
/// → Minecraft Profile。
///
/// ⚠️ Client ID 配置：需在 Azure 门户注册"公共客户端"应用
/// （允许 public client flows），在设置中填入 Client ID。详见 README。
class MicrosoftAuthService {
  MicrosoftAuthService._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {Headers.acceptHeader: 'application/json'},
  ));

  static String _clientId = '';

  /// 注入 Azure 应用 Client ID
  static void configureClientId(String clientId) {
    _clientId = clientId.trim();
  }

  static bool get isConfigured => _clientId.isNotEmpty;

  // ---------------- 端点 ----------------

  static const String _deviceCodeUrl =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode';
  static const String _tokenUrl =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
  static const String _xblUrl = 'https://user.auth.xboxlive.com/user/authenticate';
  static const String _xstsUrl = 'https://xsts.auth.xboxlive.com/xsts/authorize';
  static const String _mcLoginUrl =
      'https://api.minecraftservices.com/authentication/login_with_xbox';
  static const String _mcProfileUrl = 'https://api.minecraftservices.com/minecraft/profile';
  static const List<String> _scopes = ['XboxLive.signin', 'offline_access'];

  /// 发起设备码认证，返回设备码信息（UI 展示给用户）
  static Future<DeviceCodeInfo> requestDeviceCode() async {
    if (_clientId.isEmpty) {
      throw const AuthException(
        '请先在设置中配置 Azure Client ID（见 README「微软登录配置」）',
      );
    }
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        _deviceCodeUrl,
        data: {
          'client_id': _clientId,
          'scope': _scopes.join(' '),
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return DeviceCodeInfo(
        deviceCode: resp.data!['device_code'] as String,
        userCode: resp.data!['user_code'] as String,
        verificationUri: resp.data!['verification_uri'] as String,
        expiresIn: resp.data!['expires_in'] as int? ?? 900,
        intervalSeconds: resp.data!['interval'] as int? ?? 5,
        message: resp.data!['message'] as String? ?? '',
      );
    } on DioException catch (e) {
      throw NetworkException('获取设备码失败', technicalDetail: e.toString());
    }
  }

  /// 轮询令牌直至用户完成授权
  static Future<MsaTokens> pollToken(DeviceCodeInfo info) async {
    final deadline = DateTime.now().add(Duration(seconds: info.expiresIn));
    var interval = Duration(seconds: info.intervalSeconds);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      final resp = await _dio.post<Map<String, dynamic>>(
        _tokenUrl,
        data: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': _clientId,
          'device_code': info.deviceCode,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (_) => true,
        ),
      );

      final body = resp.data ?? {};
      final error = body['error'] as String?;
      if (error == null) {
        return MsaTokens(
          accessToken: body['access_token'] as String,
          refreshToken: body['refresh_token'] as String,
          expiresIn: body['expires_in'] as int? ?? 3600,
        );
      }
      switch (error) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'authorization_declined':
          throw const AuthException('用户拒绝了授权');
        case 'expired_token':
          throw const AuthException('设备码已过期，请重试');
        default:
          throw AuthException('微软认证失败: $error',
              technicalDetail: jsonEncode(body));
      }
    }
    throw const AuthException('授权等待超时');
  }

  /// MSA Token → Xbox Live XSTS Token
  static Future<XboxTokens> authenticateXbox(String msaToken) async {
    final xblResp = await _dio.post<Map<String, dynamic>>(
      _xblUrl,
      data: {
        'Properties': {
          'AuthMethod': 'RPS',
          'SiteName': 'user.auth.xboxlive.com',
          'RpsTicket': 'd=$msaToken',
        },
        'RpsTicket': 'd=$msaToken',
      },
    );
    final xblToken = xblResp.data!['Token'] as String;

    final xstsResp = await _dio.post<Map<String, dynamic>>(
      _xstsUrl,
      data: {
        'Properties': {
          'SandboxId': 'RETAIL',
          'UserTokens': [xblToken],
        },
        'RpsTicket': xblToken,
      },
    );
    final xstsToken = xstsResp.data!['Token'] as String;
    final xstsUhs = ((xstsResp.data!['DisplayClaims'] as Map)['xui'] as List)
        .first['uhs'] as String;

    // 处理常见 XSTS 错误（如缺少 Xbox 账户）
    if (xstsToken.isEmpty) {
      throw const AuthException('Xbox Live 认证失败：该账户可能没有 Xbox 档案');
    }
    return XboxTokens(token: xstsToken, userHash: xstsUhs);
  }

  /// XSTS → Minecraft Access Token
  static Future<({String token, int expiresAt})> loginMinecraft(
      XboxTokens xbox) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      _mcLoginUrl,
      data: {'identityToken': 'XBL3.0 x=${xbox.userHash};${xbox.token}'},
    );
    return (
      token: resp.data!['access_token'] as String,
      expiresAt: DateTime.now()
          .add(Duration(seconds: resp.data!['expires_in'] as int? ?? 86400))
          .millisecondsSinceEpoch,
    );
  }

  /// 获取玩家档案
  static Future<MinecraftProfile> fetchProfile(String mcToken) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      _mcProfileUrl,
      options: Options(headers: {'Authorization': 'Bearer $mcToken'}),
    );
    final data = resp.data!;
    final skin = (data['skins'] as List?)?.firstOrNull;
    return MinecraftProfile(
      id: data['id'] as String,
      name: data['name'] as String,
      skinUrl: skin == null ? null : (skin as Map)['url'] as String?,
    );
  }

  /// 完整登录流程
  static Future<GameAccount> fullLogin(DeviceCodeInfo info) async {
    final tokens = await pollToken(info);
    return _completeLogin(tokens);
  }

  static Future<GameAccount> _completeLogin(MsaTokens tokens) async {
    final xbox = await authenticateXbox(tokens.accessToken);
    final mc = await loginMinecraft(xbox);
    final profile = await fetchProfile(mc.token);
    AppLogger.info('MSAuth', '微软登录成功: ${profile.name}');
    return GameAccount(
      id: 'ms_${profile.id}',
      type: AccountType.microsoft,
      name: profile.name,
      accessToken: mc.token,
      uuid: profile.id,
      expiresAt: mc.expiresAt,
      skinUrl: profile.skinUrl,
      refreshToken: tokens.refreshToken,
    );
  }

  /// 使用 Refresh Token 静默刷新
  static Future<GameAccount> refreshAccessToken({
    required String refreshToken,
    required String prevName,
    required String prevUuid,
  }) async {
    if (_clientId.isEmpty) {
      throw const AuthException('未配置 Azure Client ID，无法刷新令牌');
    }
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        _tokenUrl,
        data: {
          'grant_type': 'refresh_token',
          'client_id': _clientId,
          'refresh_token': refreshToken,
          'scope': _scopes.join(' '),
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final tokens = MsaTokens(
        accessToken: resp.data!['access_token'] as String,
        refreshToken: resp.data!['refresh_token'] as String,
        expiresIn: resp.data!['expires_in'] as int? ?? 3600,
      );
      return await _completeLogin(tokens);
    } on DioException catch (e) {
      AppLogger.warn('MSAuth', '刷新令牌失败: $e');
      throw AuthException('微软令牌刷新失败，请重新登录',
          technicalDetail: e.toString());
    }
  }
}

class DeviceCodeInfo {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int intervalSeconds;
  final String message;

  const DeviceCodeInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.intervalSeconds,
    required this.message,
  });
}

class MsaTokens {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  const MsaTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });
}

class XboxTokens {
  final String token;
  final String userHash;

  const XboxTokens({required this.token, required this.userHash});
}

class MinecraftProfile {
  final String id;
  final String name;
  final String? skinUrl;

  const MinecraftProfile({required this.id, required this.name, this.skinUrl});
}
