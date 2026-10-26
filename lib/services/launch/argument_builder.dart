import 'dart:convert';

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../data/models/game_account.dart';
import '../../data/models/app_settings.dart';

/// 启动参数构建器。
///
/// 负责把版本 JSON + 账户 + 设置组装成完整的 JVM 参数与游戏参数。
/// 规则参考 Minecraft 官方版本 JSON 的 arguments 模板。
class LaunchArgumentsBuilder {
  const LaunchArgumentsBuilder._();

  /// JVM 参数模板替换映射
  static Map<String, String> _jvmTemplateMap({
    required String nativesDir,
    required String classpath,
    required String classpathSeparator,
  }) {
    return {
      r'${natives_directory}': nativesDir,
      r'${launcher_name}': 'FMCL',
      r'${launcher_version}': '0.1.0',
      r'${classpath}': classpath,
      r'${classpath_separator}': classpathSeparator,
    };
  }

  /// 游戏参数模板替换映射
  static Map<String, String> _gameTemplateMap({
    required GameAccount account,
    required String versionId,
    required String gameDir,
    required String assetsDir,
    required String assetsIndexId,
    required AppSettings settings,
    String serverAddress = '',
  }) {
    // 服务器地址：1.20+ 走 quickPlayMultiplayer 模板；旧版本由 buildGameArgs 手动追加
    final quickPlayMp =
        (serverAddress.isNotEmpty && _isMinecraft120OrLater(versionId))
        ? serverAddress
        : '';
    return {
      r'${auth_player_name}': account.name,
      r'${auth_uuid}': account.uuid,
      r'${auth_access_token}': account.accessToken,
      r'${auth_xuid}': '',
      r'${clientid}': 'fmcl-client',
      r'${auth_session}': 'token:${account.accessToken}:${account.uuid}',
      r'${user_type}': account.type == AccountType.microsoft ? 'msa' : 'legacy',
      r'${version_name}': versionId,
      r'${version_type}': 'FMCL',
      r'${game_directory}': gameDir,
      r'${assets_root}': assetsDir,
      r'${game_assets}': assetsDir,
      r'${assets_index_name}': assetsIndexId,
      r'${user_properties}': '{}',
      r'${resolution_width}': settings.windowWidth.toString(),
      r'${resolution_height}': settings.windowHeight.toString(),
      r'${quickPlayPath}': '',
      r'${quickPlaySingleplayer}': '',
      r'${quickPlayMultiplayer}': quickPlayMp,
      r'${quickPlayRealms}': '',
    };
  }

  /// 从版本 id 提取 Minecraft 基础版本并判断是否 >= 1.20（quickPlay 时代）。
  /// 兼容 "1.20.1"、"1.20.1-forge-47.2.0"、"1.16.5-fabric" 等命名。
  static bool _isMinecraft120OrLater(String versionId) {
    final m = RegExp(r'1\.(\d+)').firstMatch(versionId);
    if (m == null) return false;
    final minor = int.tryParse(m.group(1)!) ?? 0;
    return minor >= 20;
  }

  /// 构建完整 JVM 参数（不含可执行文件本身与主类）。
  ///
  /// `inheritedJvmArgs`：继承链上各版本 JSON 的 jvm arguments（父→子）。
  static List<String> buildJvmArgs({
    required List<List<String>> inheritedJvmArgs,
    required String nativesDir,
    required String classpath,
    required String classpathSeparator,
    required int minMemoryMb,
    required int maxMemoryMb,
    required String extraJvmArgs,
    required String javaAgentArg,
    required String loggingArgument,
  }) {
    final args = <String>[];

    // 基础内存参数
    args.add('-Xmn${minMemoryMb}m');
    args.add('-Xmx${maxMemoryMb}m');

    // 用户自定义 JVM 参数（置于最前部分，允许覆盖默认）
    if (extraJvmArgs.trim().isNotEmpty) {
      args.addAll(_splitArgs(extraJvmArgs));
    }

    // 版本 JSON 的 JVM 模板参数（按继承顺序）
    final template = _jvmTemplateMap(
      nativesDir: nativesDir,
      classpath: classpath,
      classpathSeparator: classpathSeparator,
    );
    for (final segment in inheritedJvmArgs) {
      args.addAll(_applyRules(segment, template));
    }

    // log4j 配置参数（1.7+）
    if (loggingArgument.isNotEmpty) {
      args.add(loggingArgument);
    }

    // authlib-injector
    if (javaAgentArg.isNotEmpty) {
      args.add(javaAgentArg);
    }

    // Windows 默认附加参数
    if (Platform.isWindows) {
      args.add(
        '-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump',
      );
    }
    args.add('-Djava.library.path=$nativesDir');

    return args;
  }

  /// 构建游戏参数（主类之后的部分）。
  ///
  /// 服务器自动加入（借鉴 PCL2/HMCL）：1.20+ 走 quickPlayMultiplayer，
  /// 更旧版本手动追加 --server / --port。
  static List<String> buildGameArgs({
    required List<List<String>> inheritedGameArgs,
    required String legacyMinecraftArguments,
    required GameAccount account,
    required String versionId,
    required String gameDir,
    required String assetsDir,
    required String assetsIndexId,
    required AppSettings settings,
    required bool fullscreen,
  }) {
    final serverAddress = settings.serverAddress.trim();
    final template = _gameTemplateMap(
      account: account,
      versionId: versionId,
      gameDir: gameDir,
      assetsDir: assetsDir,
      assetsIndexId: assetsIndexId,
      settings: settings,
      serverAddress: serverAddress,
    );

    final args = <String>[];

    if (legacyMinecraftArguments.isNotEmpty) {
      // 1.12-：单串参数
      args.addAll(_applyRules(legacyMinecraftArguments.split(' '), template));
    } else {
      for (final segment in inheritedGameArgs) {
        args.addAll(_applyRules(segment, template));
      }
    }
    // 清理模板值缺失产生的悬空标志（如空 quickPlay）
    final cleaned = _dropDanglingFlags(args);
    args.clear();
    args.addAll(cleaned);

    // 服务器自动加入：官方 json 未提供 quickPlay token 时手动追加
    if (serverAddress.isNotEmpty) {
      final hostPort = _splitHostPort(serverAddress);
      final jsonHasQuickPlay = _hasToken(
        inheritedGameArgs,
        'quickPlayMultiplayer',
      );
      final useQuickPlay = legacyMinecraftArguments.isEmpty && jsonHasQuickPlay;
      final alreadyApplied = useQuickPlay && args.contains(hostPort);
      if (!alreadyApplied) {
        if (useQuickPlay) {
          args.addAll(['--quickPlayMultiplayer', hostPort]);
        } else {
          args.addAll([
            '--server',
            hostPort.split(':').first,
            '--port',
            hostPort.contains(':') ? hostPort.split(':').last : '25565',
          ]);
        }
      }
    }

    // 全屏 / 分辨率（旧版本通过 --width/--height）
    if (fullscreen) {
      args.addAll(['--fullscreen']);
    } else if (settings.windowWidth > 0 && settings.windowHeight > 0) {
      final isModern =
          _hasToken(inheritedGameArgs, 'resolution_width') ||
          legacyMinecraftArguments.contains('width');
      if (isModern) {
        // 模板已替换 --width ${resolution_width}
      } else {
        args.addAll([
          '--width',
          settings.windowWidth.toString(),
          '--height',
          settings.windowHeight.toString(),
        ]);
      }
    }

    // 用户自定义游戏参数
    if (settings.gameArguments.trim().isNotEmpty) {
      args.addAll(_splitArgs(settings.gameArguments));
    }

    return args;
  }

  static bool _hasToken(List<List<String>> segments, String token) {
    return segments.any((s) => s.any((e) => e.contains(token)));
  }

  /// 拆分 "host:port"；无端口时默认 25565。兼容裸 IPv6（含多个冒号）。
  static String _splitHostPort(String address) {
    final last = address.lastIndexOf(':');
    if (last <= 0) return '$address:25565';
    final portPart = address.substring(last + 1);
    final port = int.tryParse(portPart);
    if (port == null || port < 1 || port > 65535) {
      return '$address:25565';
    }
    return address;
  }

  /// 需要紧跟值参数的选项集合；当值缺失（空/被跳过/指向另一标志）时丢弃标志本身。
  static const _valueFlags = {
    '--quickPlayPath',
    '--quickPlaySingleplayer',
    '--quickPlayMultiplayer',
    '--quickPlayRealms',
  };

  /// 清理模板值缺失导致的悬空标志对（官方 json 的 quickPlay 系列在未使用时）。
  static List<String> _dropDanglingFlags(List<String> input) {
    final out = <String>[];
    for (var i = 0; i < input.length; i++) {
      final a = input[i];
      if (_valueFlags.contains(a) &&
          (i + 1 >= input.length || input[i + 1].startsWith('--'))) {
        continue; // 丢弃悬空标志（其值位置无内容）
      }
      out.add(a);
    }
    return out;
  }

  /// 展开 ${token} 模板；无法识别的 token 的相邻参数对保留原样（官方语义）
  static List<String> _applyRules(List<String> input, Map<String, String> map) {
    final out = <String>[];
    var i = 0;
    while (i < input.length) {
      var arg = input[i];
      final replaced = _replaceAllTokens(arg, map);
      if (arg.startsWith(r'${') && arg.endsWith('}')) {
        // token 参数：如果值非空则替换，否则跳过该参数与其值
        final value = map[arg] ?? '';
        if (value.isNotEmpty) {
          out.add(value);
          // 若下一个元素是该 token 的值（形如 [--token, value] 结构中 value 是字面量）
          if (i + 1 < input.length && !input[i + 1].startsWith('--')) {
            i += 2;
            continue;
          }
        } else {
          // 跳过 token；若下一个元素不是 flag 也一并跳过
          if (i + 1 < input.length &&
              !input[i + 1].startsWith('--') &&
              !input[i + 1].startsWith(r'${')) {
            i += 2;
            continue;
          }
        }
      } else {
        out.add(replaced);
      }
      i++;
    }
    return out;
  }

  static String _replaceAllTokens(String arg, Map<String, String> map) {
    var result = arg;
    for (final entry in map.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  /// 拆分用户输入参数（支持引号包裹）
  static List<String> _splitArgs(String input) {
    final args = <String>[];
    final pattern = RegExp(r'''(?:[^\s"']+|"[^"]*"|'[^']*')+''');
    for (final m in pattern.allMatches(input)) {
      var a = m.group(0)!;
      if (a.length >= 2 && (a.startsWith('"') && a.endsWith('"'))) {
        a = a.substring(1, a.length - 1);
      }
      if (a.isNotEmpty) args.add(a);
    }
    return args;
  }

  /// 离线模式的 UUID 生成（与 Mojang 离线模式一致的 MD5 哈希算法）
  static String offlineUuid(String playerName) {
    final digest = md5.convert(utf8.encode('OfflinePlayer:$playerName'));
    final md5bytes = digest.bytes;
    md5bytes[6] = (md5bytes[6] & 0x0f) | 0x30;
    md5bytes[8] = (md5bytes[8] & 0x3f) | 0x80;
    final hex = md5bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
