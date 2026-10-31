import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;

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

  /// 下载 authlib-injector jar（返回字节，由调用方落盘）。
  ///
  /// 源顺序（对齐 PCL 的容灾策略）：
  /// 1. 官方 artifact 清单 authlib-injector.yushi.moe（带 SHA1 校验）
  /// 2. GitHub Releases（yushijinhun/authlib-injector）回退
  static Future<({List<int> bytes, String version, String sha1})>
      fetchAuthlibInjector() async {
    try {
      return await _fetchAuthlibInjectorOfficial();
    } catch (e) {
      AppLogger.warn('Yggdrasil', 'authlib-injector 官方源失败，回退 GitHub: $e');
      return _fetchAuthlibInjectorGithub();
    }
  }

  static Future<({List<int> bytes, String version, String sha1})>
      _fetchAuthlibInjectorOfficial() async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client
          .getUrl(Uri.parse(AppConstants.authlibInjectorUrl))
          .timeout(const Duration(seconds: 20));
      final resp = await req.close();
      final meta = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final url = meta['download_url'] as String;
      final sha1 = meta['sha1'] as String;
      final version = meta['version'] as String;

      final bytes = await _downloadBytes(client, url);
      // SHA1 校验（对齐 PCL：不匹配视为下载失败）
      final actual = sha1Hex(bytes);
      if (actual.toLowerCase() != sha1.toLowerCase()) {
        throw NetworkException('authlib-injector SHA1 校验失败',
            technicalDetail: '期望 $sha1 实际 $actual');
      }
      return (bytes: bytes, version: version, sha1: sha1);
    } finally {
      client.close(force: true);
    }
  }

  static Future<({List<int> bytes, String version, String sha1})>
      _fetchAuthlibInjectorGithub() async {
    final client = HttpClient()..userAgent = AppConstants.userAgent;
    try {
      final req = await client
          .getUrl(Uri.parse(
              'https://api.github.com/repos/yushijinhun/authlib-injector/releases/latest'))
          .timeout(const Duration(seconds: 20));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw NetworkException('GitHub Releases 查询失败 (HTTP ${resp.statusCode})');
      }
      final rel = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final version = (rel['tag_name'] as String? ?? '').replaceFirst('v', '');
      final assets = (rel['assets'] as List? ?? []).whereType<Map>().toList();
      final jarAsset = assets.firstWhere(
        (a) => (a['name'] as String? ?? '').endsWith('.jar'),
        orElse: () => throw const NetworkException('GitHub Release 缺少 jar 资产'),
      );
      final jarUrl = jarAsset['browser_download_url'] as String;
      final bytes = await _downloadBytes(client, jarUrl);
      // sha1 校验值（可能存在 <jar>.sha1 资产，缺失时跳过校验）
      var sha1 = '';
      final shaAsset = assets.where((a) =>
          (a['name'] as String? ?? '') == '${jarAsset['name']}.sha1').toList();
      if (shaAsset.isNotEmpty) {
        try {
          final shaBytes = await _downloadBytes(
              client, shaAsset.first['browser_download_url'] as String);
          sha1 = utf8.decode(shaBytes).trim();
          final actual = sha1Hex(bytes);
          if (sha1.isNotEmpty &&
              actual.toLowerCase() != sha1.toLowerCase()) {
            throw NetworkException('authlib-injector SHA1 校验失败',
                technicalDetail: '期望 $sha1 实际 $actual');
          }
        } on NetworkException {
          rethrow;
        } catch (_) {
          sha1 = '';
        }
      }
      AppLogger.info('Yggdrasil',
          'authlib-injector 已从 GitHub 获取: v$version (${bytes.length} 字节)');
      return (bytes: bytes, version: version, sha1: sha1);
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>> _downloadBytes(
      HttpClient client, String url) async {
    final jarReq = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    final jarResp = await jarReq.close();
    if (jarResp.statusCode != 200) {
      throw NetworkException('下载失败 (HTTP ${jarResp.statusCode}): $url');
    }
    final bytes = <int>[];
    await for (final chunk in jarResp) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static String sha1Hex(List<int> bytes) => sha1.convert(bytes).toString();
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
