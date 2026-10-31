import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/logger/app_logger.dart';
import '../data/models/app_settings.dart';
import '../services/download/download_manager.dart';
import '../services/download/http_service.dart';

/// SharedPreferences 实例（main 中预初始化）
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('必须在 main 中覆盖初始化');
});

/// 应用设置（AppSettings 不可变对象 + Notifier 持久化）
///
/// 持久化借鉴 PCL.Core 配置系统：状态立即生效，磁盘写入防抖 600ms，
/// 避免拖动滑块等高频操作导致的频繁 IO。
class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_key);
    if (raw == null) {
      return _defaults();
    }
    try {
      return AppSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      AppLogger.warn('Settings', '设置解析失败，使用默认值: $e');
      return _defaults();
    }
  }

  static const String _key = 'fmcl.app_settings';
  static const Duration _debounceDelay = Duration(milliseconds: 600);
  Timer? _debounce;

  /// 默认设置（默认游戏目录在首次进入时由 initGameDirectory 设置）
  AppSettings _defaults() {
    return AppSettings(gameDirectory: '');
  }

  Future<void> update(AppSettings next) async {
    state = next;
    // 同步热更新依赖组件（立即）
    HttpService.I.configure(next);
    // 磁盘写入防抖
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      _persist(next);
    });
  }

  Future<void> _persist(AppSettings next) async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(_key, jsonEncode(next.toJson()));
      AppLogger.info('Settings', '设置已持久化');
    } catch (e) {
      AppLogger.warn('Settings', '设置持久化失败: $e');
    }
  }

  /// 立即落盘（应用退出前调用，防止防抖窗口内的改动丢失）
  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    await _persist(state);
  }

  Future<void> patch(AppSettings Function(AppSettings) mutator) async {
    await update(mutator(state));
  }

  /// 首次启动：初始化默认游戏目录。
  ///
  /// 借鉴 PCL2 / HMCL 的便携模式（需求：下载目录 = exe 所在目录\.minecraft）：
  /// - Windows / Linux：可执行文件所在目录\.minecraft（随启动器移动）
  /// - macOS：.app 包内不可写，回退 ~/minecraft（HMCL 式）
  /// - Android：应用文档目录\.minecraft（无 exe 概念）
  /// exe 目录不可写时自动回退到系统标准位置。
  Future<void> initGameDirectory() async {
    if (state.gameDirectory.isNotEmpty) return;
    String base;
    try {
      if (Platform.isWindows) {
        base = await _portableDir(
          fallback: p.join(
              Platform.environment['APPDATA'] ?? '.', '.minecraft'),
        );
      } else if (Platform.isMacOS) {
        base = p.join(
          Platform.environment['HOME'] ?? '.', 'Library', 'Application Support',
          'minecraft',
        );
      } else if (Platform.isAndroid) {
        // TODO(ANDROID)：接入 SAF / 应用私有目录策略，见 TODO.md #A-04
        final dir = await getApplicationDocumentsDirectory();
        base = p.join(dir.path, '.minecraft');
      } else if (Platform.isLinux) {
        // Flutter Linux 发行包：exe 与其依赖同目录，便携 .minecraft 就近创建
        base = await _portableDir(
          fallback: p.join(
              Platform.environment['HOME'] ?? '.', '.minecraft'),
        );
      } else {
        base = p.join(
            Platform.environment['HOME'] ?? '.', '.minecraft');
      }
    } catch (_) {
      base = p.join(Directory.systemTemp.path, 'fmcl', '.minecraft');
    }
    await update(state.copyWith(gameDirectory: base));
  }

  /// 便携目录：exe 所在目录\.minecraft（PCL2 式），不可写则回退。
  Future<String> _portableDir({required String fallback}) async {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final dir = Directory(p.join(exeDir, '.minecraft'));
      final probe = File(p.join(exeDir, '.fmcl_write_probe'));
      probe.writeAsStringSync('ok', flush: true);
      probe.deleteSync();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.path;
    } catch (e) {
      AppLogger.warn(
          'Settings', 'exe 目录不可写，回退系统目录: $e');
      return fallback;
    }
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

/// 便捷访问器
AppSettings settingsOf(Ref ref) => ref.read(appSettingsProvider);

/// 游戏目录快捷 provider
final gameDirectoryProvider = Provider<String>((ref) {
  return ref.watch(appSettingsProvider).gameDirectory;
});

/// 下载状态
final downloadStateProvider =
    NotifierProvider<DownloadStateNotifier, DownloadState>(
  DownloadStateNotifier.new,
);

class DownloadStateNotifier extends Notifier<DownloadState> {
  @override
  DownloadState build() => const DownloadState();

  /// 整体覆盖状态
  void set(DownloadState value) => state = value;

  /// 局部更新状态
  void patchState(DownloadState Function(DownloadState) mutator) =>
      state = mutator(state);
}

/// 下载管理器实例
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  return DownloadManager(ref);
});

/// 当前账户 id（由 accountsProvider.currentId 管理的主要状态）
final currentAccountIdProvider = NotifierProvider<CurrentAccountIdNotifier, String>(
  CurrentAccountIdNotifier.new,
);

class CurrentAccountIdNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String id) => state = id;
}

/// 主题模式：0=跟随系统 1=浅色 2=深色
final themeModeIndexProvider = Provider<int>((ref) {
  return ref.watch(appSettingsProvider).themeMode;
});

/// 应用信息
final appInfoProvider = Provider<AppInfo>((ref) => const AppInfo());

class AppInfo {
  final String name = AppConstants.appName;
  final String fullName = AppConstants.appFullName;
  final String version = AppConstants.appVersion;
  final String repoUrl = AppConstants.repoUrl;

  const AppInfo();
}
