/// FMCL 统一异常体系。
///
/// 所有可预期错误都应抛出 [AppException] 的子类，UI 层据此展示
/// 友好的错误信息与修复建议（借鉴 PCL2 的"错误报告"思想）。
abstract class AppException implements Exception {
  const AppException(this.userMessage,
      {this.technicalDetail, this.suggestions = const []});

  /// 展示给用户的可读信息
  final String userMessage;

  /// 面向开发者的技术细节（写入日志）
  final String? technicalDetail;

  /// 建议的修复动作（UI 可执行）
  final List<FixSuggestion> suggestions;

  @override
  String toString() => '$runtimeType: $userMessage'
      '${technicalDetail == null ? '' : '\n  detail: $technicalDetail'}';
}

/// 修复建议
class FixSuggestion {
  const FixSuggestion(this.title, this.description, {this.actionId});

  /// 建议标题，如 "重新下载依赖库"
  final String title;

  /// 具体说明
  final String description;

  /// 可执行动作标识（UI 注册对应处理器），null 表示纯提示
  final String? actionId;
}

/// 网络异常（下载失败、API 不可达等）
class NetworkException extends AppException {
  const NetworkException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// 下载源异常：主源与回退源都失败时抛出
class DownloadSourceException extends NetworkException {
  const DownloadSourceException(
    super.message, {
    required this.primaryError,
    required this.fallbackError,
    super.technicalDetail,
  });

  final String primaryError;
  final String fallbackError;
}

/// 文件 IO 异常
class FileSystemException extends AppException {
  const FileSystemException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// 校验失败（SHA1/大小不符）
class VerifyException extends AppException {
  const VerifyException(super.message, {super.technicalDetail});
}

/// JSON 解析异常
class ParseException extends AppException {
  const ParseException(super.message, {super.technicalDetail});
}

/// 安装器异常（Forge 处理器执行失败等）
class InstallerException extends AppException {
  const InstallerException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// 账户认证异常
class AuthException extends AppException {
  const AuthException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// 启动失败异常
class LaunchException extends AppException {
  const LaunchException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// Java 环境异常
class JavaException extends LaunchException {
  const JavaException(super.message, {super.technicalDetail, super.suggestions = const []});
}

/// 用户主动取消
class CancelledException extends AppException {
  const CancelledException([String? message])
      : super(message ?? '操作已取消');
}

/// 平台不支持（如 Android 上的进程启动）
class PlatformUnsupportedException extends AppException {
  const PlatformUnsupportedException(super.message, {this.todoRef});

  /// 对应 TODO 文档条目，便于开发者定位
  final String? todoRef;
}
