import '../../core/error/app_exception.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;

/// Minecraft 服务器状态查询服务（Rust SLP 实现）。
class ServerPingService {
  ServerPingService._();
  static final ServerPingService instance = ServerPingService._();
  static ServerPingService get I => instance;

  /// 查询服务器状态。
  ///
  /// 支持 `host`、`host:port` 两种输入格式（默认端口 25565）。
  Future<rust.ServerStatus> ping(String address, {int timeoutMs = 5000}) async {
    if (!rust.rustBridgeAvailable) {
      throw const PlatformUnsupportedException(
        '当前平台暂不支持服务器查询',
        todoRef: 'TODO.md #A-02',
      );
    }

    var host = address.trim();
    var port = 25565;
    final idx = host.lastIndexOf(':');
    if (idx > 0 && !host.contains(']')) {
      // 处理 host:port（IPv6 字面量带端口形式暂不支持）
      final portPart = host.substring(idx + 1);
      final parsed = int.tryParse(portPart);
      if (parsed != null && parsed > 0 && parsed < 65536) {
        host = host.substring(0, idx);
        port = parsed;
      }
    }
    host = host.replaceFirst(RegExp(r'^\[|\]$'), '');

    if (host.isEmpty) {
      throw const ParseException('服务器地址不能为空');
    }

    return rust.pingServer(host: host, port: port, timeoutMs: timeoutMs);
  }
}
