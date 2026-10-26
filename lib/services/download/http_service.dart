import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/app_settings.dart';
import '../../data/sources/download_source.dart';

/// 统一 HTTP 客户端。
///
/// - JSON API 请求（版本清单、Fabric/Quilt Meta、Modrinth 等）
/// - 带自动源回退的 GET（JSON 文本）
///
/// 大批量文件下载走 Rust 下载引擎（见 services/download/download_manager.dart）。
class HttpService {
  HttpService._();
  static final HttpService instance = HttpService._();
  static HttpService get I => instance;

  late Dio _dio;
  AppSettings _settings = const AppSettings(gameDirectory: '');
  int _timeoutSeconds = 20;

  void configure(AppSettings settings) {
    _settings = settings;
    _dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: _timeoutSeconds),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'user-agent': AppConstants.userAgent,
        'accept': 'application/json',
      },
      validateStatus: (code) => code != null && code < 500,
    ));
  }

  Dio get dio => _dio;

  DownloadSource get primarySource =>
      DownloadSources.of(_settings.downloadSourceIndex == 1
          ? DownloadSourceKind.official
          : DownloadSourceKind.bmclapi);

  /// GET JSON：自动双源回退（镜像失败回官方，反之亦然）
  Future<dynamic> getJsonWithFallback(
    String url, {
    bool mapThroughSource = false,
  }) async {
    final (primary, fallback) = DownloadSources.pairOf(
      _settings.downloadSourceIndex == 1
          ? DownloadSourceKind.official
          : DownloadSourceKind.bmclapi,
    );
    final primaryUrl = mapThroughSource ? primary.mapVersionJsonUrl(url) : url;
    final fallbackUrl = mapThroughSource ? fallback.mapVersionJsonUrl(url) : url;

    Object? primaryError;
    try {
      return await _getJson(primaryUrl);
    } catch (e) {
      primaryError = e;
      AppLogger.warn('Http', '主源请求失败: $primaryUrl → $e');
      if (!_settings.autoFallback || fallbackUrl == primaryUrl) rethrow;
    }
    try {
      return await _getJson(fallbackUrl);
    } catch (e) {
      throw DownloadSourceException(
        '主源与备用源均请求失败',
        primaryError: primaryError.toString(),
        fallbackError: e.toString(),
        technicalDetail: 'url=$url',
      );
    }
  }

  Future<dynamic> _getJson(String url) async {
    final resp = await _dio.get<dynamic>(url);
    if (resp.statusCode != 200) {
      throw NetworkException('HTTP ${resp.statusCode}: $url');
    }
    final data = resp.data;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (e) {
        throw ParseException('响应不是合法 JSON: $url', technicalDetail: e.toString());
      }
    }
    return data;
  }

  /// 下载小文件到内存（安装器 jar 等，最大 ~100MB 量级）
  Future<Uint8List> getBytesWithFallback(
    String url, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final source = primarySource;
    final mapped = source.mapUrl(url);
    try {
      return await _getBytes(mapped, onProgress);
    } catch (e) {
      if (!_settings.autoFallback) rethrow;
      AppLogger.warn('Http', '字节下载失败，尝试备用源: $url → $e');
      final (primary, fallback) = DownloadSources.pairOf(source.kind);
      final alt = fallback.mapUrl(url);
      if (alt == mapped) throw NetworkException('下载失败: $url');
      return await _getBytes(alt, onProgress);
    }
  }

  Future<Uint8List> _getBytes(
    String url,
    void Function(int, int?)? onProgress,
  ) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );
    if (resp.statusCode != 200) {
      throw NetworkException('HTTP ${resp.statusCode}: $url');
    }
    return Uint8List.fromList(resp.data ?? []);
  }
}

/// 便捷顶层访问
HttpService get http => HttpService.I;
