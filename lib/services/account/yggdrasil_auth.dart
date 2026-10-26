import 'dart:convert';
import 'dart:io';

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';

/// Yggdrasil（authlib-injector）外置登录服务。
///
/// 兼容 authlib-injector 规范的认证服务器（LittleSkin、Blessing Skin 等）。
/// 服务端元数据通过 `GET {server}/api/yggdrasil` 的 ALI 头解析。
class YggdrasilAuthService {
  YggdrasilAuthService._();

  /// 服务端 API 根地址（规范化：去除路径尾部斜杠与 /api/yggdrasil 后缀）
  static String normalizeServerUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) throw const AuthException('认证服务器地址不能为空');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 探测服务端元数据（返回 yggdrasil API 根）
  static Future<YggdrasilServerMeta> fetchServerMeta(String serverUrl) async {
    final normalized = normalizeServerUrl(serverUrl);
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.getUrl(Uri.parse('$normalized/api/yggdrasil'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw AuthException('无法连接认证服务器 (HTTP ${resp.statusCode})');
      }
      final meta = jsonDecode(body) as Map<String, dynamic>;
      // authlib-injector 规范：X-Authlib-Injector-API-Location 头指向真正 API 根
      final aliHeader = resp.headers.value('x-authlib-injector-api-location');
      var apiRoot = normalized;
      if (aliHeader != null) {
        apiRoot = Uri.parse(normalized).resolve(aliHeader).toString();
        while (apiRoot.endsWith('/')) {
          apiRoot = apiRoot.substring(0, apiRoot.length - 1);
        }
      }
      return YggdrasilServerMeta(
        apiRoot: apiRoot,
        serverName: (meta['meta'] as Map?)?['serverName'] as String? ?? normalized,
      );
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('认证服务器不可达: $normalized',
          technicalDetail: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// 账号密码登录
  static Future<YggdrasilSession> authenticate({
    required String apiRoot,
    required String username,
    required String password,
  }) async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.postUrl(Uri.parse('$apiRoot/authserver/authenticate'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'agent': {'name': 'Minecraft', 'version': 1},
        'username': username,
        'password': password,
        'requestUser': true,
      }));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      if (resp.statusCode != 200) {
        final msg = (data['errorMessage'] as String?) ?? '认证失败';
        throw AuthException(msg);
      }

      final profiles = (data['availableProfiles'] as List? ?? [])
          .whereType<Map>()
          .toList();
      if (profiles.isEmpty) {
        throw const AuthException('该账户没有可用的角色档案');
      }
      final selected = profiles.first;
      final profileId = selected['id'] as String;
      final profileName = selected['name'] as String;

      AppLogger.info('Yggdrasil', '外置登录成功: $profileName@$apiRoot');
      return YggdrasilSession(
        accessToken: data['accessToken'] as String,
        profileId: profileId,
        profileName: profileName,
        clientToken: data['clientToken'] as String? ?? '',
        availableProfiles: profiles
            .map((p) => YggdrasilProfile(
                  id: p['id'] as String,
                  name: p['name'] as String,
                ))
            .toList(),
        apiRoot: apiRoot,
      );
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('登录请求失败', technicalDetail: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// 令牌校验/续期
  static Future<String> validateOrRefresh({
    required String apiRoot,
    required String accessToken,
    required String clientToken,
    required String profileId,
    required String profileName,
  }) async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      // validate
      final validateReq =
          await client.postUrl(Uri.parse('$apiRoot/authserver/validate'));
      validateReq.headers.contentType = ContentType.json;
      validateReq.write(jsonEncode({
        'accessToken': accessToken,
        'clientToken': clientToken,
      }));
      final validateResp = await validateReq.close();
      await validateResp.drain();
      if (validateResp.statusCode == 204) {
        return accessToken;
      }
      // refresh
      final refreshReq =
          await client.postUrl(Uri.parse('$apiRoot/authserver/refresh'));
      refreshReq.headers.contentType = ContentType.json;
      refreshReq.write(jsonEncode({
        'accessToken': accessToken,
        'clientToken': clientToken,
        'requestUser': false,
      }));
      final refreshResp = await refreshReq.close();
      final body = await refreshResp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final newToken = data['accessToken'] as String?;
      if (newToken == null) {
        throw const AuthException('外置登录令牌已失效，请重新登录');
      }
      AppLogger.info('Yggdrasil', '令牌已自动续期');
      return newToken;
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('令牌校验失败', technicalDetail: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// 下载 authlib-injector jar（返回字节，由调用方落盘）
  static Future<({List<int> bytes, String version, String sha1})>
      fetchAuthlibInjector() async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client.getUrl(Uri.parse(AppConstants.authlibInjectorUrl));
      final resp = await req.close();
      final meta = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final url = meta['download_url'] as String;
      final sha1 = meta['sha1'] as String;
      final version = meta['version'] as String;

      final jarReq = await client.getUrl(Uri.parse(url));
      final jarResp = await jarReq.close();
      final bytes = <int>[];
      await for (final chunk in jarResp) {
        bytes.addAll(chunk);
      }
      return (bytes: bytes, version: version, sha1: sha1);
    } catch (e) {
      throw NetworkException('下载 authlib-injector 失败',
          technicalDetail: e.toString());
    } finally {
      client.close(force: true);
    }
  }
}

class YggdrasilServerMeta {
  final String apiRoot;
  final String serverName;

  const YggdrasilServerMeta({required this.apiRoot, required this.serverName});
}

class YggdrasilSession {
  final String accessToken;
  final String profileId;
  final String profileName;
  final String clientToken;
  final List<YggdrasilProfile> availableProfiles;
  final String apiRoot;

  const YggdrasilSession({
    required this.accessToken,
    required this.profileId,
    required this.profileName,
    required this.clientToken,
    required this.availableProfiles,
    required this.apiRoot,
  });
}

class YggdrasilProfile {
  final String id;
  final String name;

  const YggdrasilProfile({required this.id, required this.name});
}
