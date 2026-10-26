import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../data/models/game_version.dart';
import '../../data/sources/download_source.dart';
import '../../providers/settings_provider.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../download/download_manager.dart';
import '../download/http_service.dart';
import 'installer_base.dart';

/// Forge / NeoForge 安装器。
///
/// 支持：
/// - 现代安装器（1.13+，含 install_profile.json 处理器链）：
///   * 处理器执行（下载工具链、读 MANIFEST Main-Class、token 替换、输出校验）
///   * 断点续装（已通过 SHA1 校验的处理器输出自动跳过）
/// - 旧版安装器（1.12-）：versionInfo 直接落盘 + universal jar 下载
///
/// NeoForge（1.20.1 及更早使用同构格式）复用本安装器。
class ForgeInstaller extends BaseInstaller {
  final bool isNeoForge;

  ForgeInstaller(
    super.ref,
    super.downloadManager,
    super.source, {
    this.isNeoForge = false,
  });

  String get loaderName => isNeoForge ? 'NeoForge' : 'Forge';

  String _installerUrl(String gameVersion, String loaderVersion) {
    if (isNeoForge) {
      return '${AppConstants.neoforgeMaven}/net/neoforged/neoforge/'
          '$loaderVersion/neoforge-$loaderVersion-installer.jar';
    }
    final path = 'net/minecraftforge/forge/'
        '$gameVersion-$loaderVersion/forge-$gameVersion-$loaderVersion-installer.jar';
    // Forge maven 直连较慢时 BMCLAPI 提供镜像
    return mapUrl('${AppConstants.forgeMaven}/$path');
  }

  /// 获取 Forge 推广版本（promotions）
  Future<List<String>> fetchRecommendedVersions(String gameVersion) async {
    // promotions_slim.json 给出 latest/recommended
    final url = isNeoForge
        ? '${AppConstants.neoforgeMaven}/net/neoforged/neoforge/promotions_slim.json'
        : 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json';
    try {
      final data = await HttpService.I.getBytesWithFallback(url);
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final promos = json['promos'] as Map<String, dynamic>? ?? {};
      final recommended = promos['$gameVersion-recommended'] as String?;
      final latest = promos['$gameVersion-latest'] as String?;
      return [
        if (recommended != null && recommended != latest) recommended,
        ?latest,
      ];
    } catch (e) {
      AppLogger.warn('Forge', '获取推荐版本失败: $e');
      return [];
    }
  }

  /// 安装入口。返回最终版本 id。
  Future<String> install({
    required String gameVersion,
    required String loaderVersion,
    required void Function(InstallProgress) onProgress,
  }) async {
    // 1. 下载安装器 jar
    final installerUrl = _installerUrl(gameVersion, loaderVersion);
    final installerPath = p.join(
      Directory.systemTemp.path,
      'fmcl_installer_'
          '${isNeoForge ? 'neoforge' : 'forge'}_'
          '${gameVersion}_$loaderVersion.jar',
    );
    onProgress(const InstallProgress('download', '下载安装器...'));
    await downloadTasks([
      DownloadTask(url: installerUrl, savePath: installerPath),
    ], onProgress);

    // 2. 读取 install_profile.json 与 version.json
    onProgress(const InstallProgress('resolve', '解析安装器...'));
    final profile = await readInstallerJson(installerPath, 'install_profile.json');

    final hasProcessors = profile['processors'] != null;

    if (!hasProcessors) {
      return _installLegacy(
        profile: profile,
        gameVersion: gameVersion,
        loaderVersion: loaderVersion,
        installerPath: installerPath,
        onProgress: onProgress,
      );
    }

    // 现代（1.13+）
    final versionJsonEntry = await _tryReadVersionJson(installerPath);
    return _installModern(
      profile: profile,
      versionJson: versionJsonEntry,
      gameVersion: gameVersion,
      loaderVersion: loaderVersion,
      installerPath: installerPath,
      onProgress: onProgress,
    );
  }

  Future<Map<String, dynamic>?> _tryReadVersionJson(String installerPath) async {
    try {
      final bytes = await rust.readZipEntry(
        jarPath: installerPath,
        entryName: 'version.json',
      );
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // 旧版（1.12-）
  // ------------------------------------------------------------------

  Future<String> _installLegacy({
    required Map<String, dynamic> profile,
    required String gameVersion,
    required String loaderVersion,
    required String installerPath,
    required void Function(InstallProgress) onProgress,
  }) async {
    final install = profile['install'] as Map<String, dynamic>? ?? {};
    final versionInfo =
        profile['versionInfo'] as Map<String, dynamic>? ?? {};
    if (versionInfo.isEmpty) {
      throw const InstallerException('旧版安装器缺少 versionInfo');
    }

    final versionId = install['versionId'] as String? ??
        'forge-$gameVersion-$loaderVersion';

    // 下载 Forge universal/client jar
    final pathCoord = install['path'] as String? ?? '';
    final filePath = install['filePath'] as String?;
    if (pathCoord.isNotEmpty) {
      final repoUrl = install['url'] as String? ??
          (source.kind == DownloadSourceKind.bmclapi
              ? AppConstants.bmclapiLibraries
              : AppConstants.forgeMaven);
      final base = repoUrl.endsWith('/') ? repoUrl.substring(0, repoUrl.length - 1) : repoUrl;
      final rel = BaseInstaller.mavenToPath(pathCoord);
      final jarSave = p.join(gameDir, 'versions', versionId,
          filePath ?? '$versionId.jar');
      // 尝试不带 classifier 与 -universal 两种
      final tryUrls = <String>[
        '$base/$rel',
      ];
      final universalRel = _withUniversalClassifier(rel);
      if (universalRel != null) tryUrls.add('$base/$universalRel');

      var downloaded = false;
      Object? lastError;
      for (final url in tryUrls) {
        try {
          await downloadTasks([
            DownloadTask(url: mapUrl(url), savePath: jarSave),
          ], onProgress);
          downloaded = true;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (!downloaded) {
        throw InstallerException('下载 Forge 主体 jar 失败',
            technicalDetail: lastError.toString());
      }
    }

    // 版本 JSON 落盘
    versionInfo['id'] = versionId;
    await writeVersionJson(versionId, versionInfo);
    onProgress(InstallProgress('done', '$loaderName $loaderVersion 安装完成'));
    return versionId;
  }

  String? _withUniversalClassifier(String relPath) {
    if (!relPath.endsWith('.jar')) return null;
    final base = relPath.substring(0, relPath.length - 4);
    return '$base-universal.jar';
  }

  // ------------------------------------------------------------------
  // 现代（1.13+）处理器链
  // ------------------------------------------------------------------

  Future<String> _installModern({
    required Map<String, dynamic> profile,
    required Map<String, dynamic>? versionJson,
    required String gameVersion,
    required String loaderVersion,
    required String installerPath,
    required void Function(InstallProgress) onProgress,
  }) async {
    final install = profile['install'] as Map<String, dynamic>? ?? {};
    final versionId = install['versionId'] as String? ??
        (isNeoForge
            ? 'neoforge-$gameVersion-$loaderVersion'
            : 'forge-$gameVersion-$loaderVersion');
    final mcVersion = install['minecraft'] as String? ?? gameVersion;

    final librariesDir = p.join(gameDir, 'libraries');
    final versionsDir = p.join(gameDir, 'versions', versionId);
    final clientJar = p.join(gameDir, 'versions', mcVersion, '$mcVersion.jar');
    final binDir = p.join(versionsDir, 'bin');
    Directory(binDir).createSync(recursive: true);

    // 确保原版客户端 jar 存在（Forge 处理器需要）
    if (!File(clientJar).existsSync()) {
      throw InstallerException(
        '缺少 Minecraft $mcVersion 客户端文件',
        suggestions: [
          FixSuggestion(
            '先安装原版',
            '请先在「下载」页安装 Minecraft $mcVersion 原版，再安装 $loaderName。',
            actionId: 'goto_download:$mcVersion',
          ),
        ],
      );
    }

    // 1. 下载 install_profile.libraries（工具链库）
    final profileLibs = (profile['libraries'] as List<dynamic>? ?? [])
        .map((e) => Library.fromJson(e as Map<String, dynamic>))
        .toList();
    onProgress(InstallProgress('download',
        '下载处理工具链（${profileLibs.length} 个库）...'));
    await _downloadLibraries(profileLibs, librariesDir, onProgress);

    // 2. 下载 version.json.libraries（运行时库）
    if (versionJson != null) {
      final runtimeLibs = (versionJson['libraries'] as List<dynamic>? ?? [])
          .map((e) => Library.fromJson(e as Map<String, dynamic>))
          .toList();
      await _downloadLibraries(runtimeLibs, librariesDir, onProgress);
    }

    // 3. 解析 data map
    final data = _resolveData(
      profile['data'] as Map<String, dynamic>? ?? {},
      gameDir: gameDir,
      clientJar: clientJar,
      installerPath: installerPath,
      librariesDir: librariesDir,
      binDir: binDir,
      mcVersion: mcVersion,
    );

    // 4. 执行处理器链（仅 client 侧；sides 缺省视为 client）
    final processors =
        (profile['processors'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
    final clientProcessors = processors
        .where((proc) =>
            ((proc['sides'] as List<dynamic>? ?? const ['client']))
                .contains('client'))
        .toList();
    AppLogger.info('Forge', '待执行处理器: ${clientProcessors.length}/${processors.length}');

    var index = 0;
    for (final proc in clientProcessors) {
      index++;
      final main = (proc['jar'] as String?) ?? '';
      onProgress(InstallProgress(
        'process',
        '执行处理器 $index/${clientProcessors.length}: ${main.split(':').length > 1 ? main.split(':')[1] : main}',
        progress: index / clientProcessors.length,
      ));
      await _runProcessor(
        proc: proc,
        data: data,
        librariesDir: librariesDir,
        binDir: binDir,
        installerPath: installerPath,
        clientJar: clientJar,
        mcVersion: mcVersion,
      );
    }

    // 5. version.json 落盘（保留继承链）
    Map<String, dynamic> finalJson;
    if (versionJson != null) {
      finalJson = Map<String, dynamic>.from(versionJson);
    } else {
      // 无内嵌 version.json：由 install 信息构造
      finalJson = {
        'id': versionId,
        'inheritsFrom': mcVersion,
        'mainClass': install['mainClass'] ?? '',
        'libraries': (profile['libraries'] as List<dynamic>? ?? []),
      };
    }
    finalJson['id'] = versionId;
    await writeVersionJson(versionId, finalJson);

    // 清理 bin 目录
    try {
      Directory(binDir).deleteSync(recursive: true);
    } catch (_) {}

    onProgress(InstallProgress('done', '$loaderName $loaderVersion 安装完成'));
    AppLogger.info('Forge', '$loaderName 安装完成 → $versionId');
    return versionId;
  }

  Future<void> _downloadLibraries(
    List<Library> libs,
    String librariesDir,
    void Function(InstallProgress) onProgress,
  ) async {
    final tasks = <DownloadTask>[];
    for (final lib in libs) {
      // Forge 处理器链库含平台规则，仅下载适用当前平台的
      final osName = Platform.isWindows
          ? 'windows'
          : Platform.isMacOS
              ? 'osx'
              : 'linux';
      if (!lib.isAllowedOn(osName, 'x86_64')) continue;

      final artifact = lib.downloads?.artifact;
      if (artifact != null && artifact.url.isNotEmpty) {
        tasks.add(DownloadTask(
          url: mapUrl(artifact.url),
          savePath: p.join(librariesDir, artifact.path ?? lib.path),
          sha1: artifact.sha1,
          size: artifact.size,
        ));
      } else {
        final base = lib.url ??
            (source.kind == DownloadSourceKind.bmclapi
                ? AppConstants.bmclapiLibraries
                : AppConstants.officialLibraries);
        tasks.add(DownloadTask(
          url: mapUrl('$base/${lib.path}'),
          savePath: p.join(librariesDir, lib.path),
        ));
      }
    }
    await downloadTasks(tasks, onProgress);
  }

  /// 解析 install_profile.data
  Map<String, String> _resolveData(
    Map<String, dynamic> rawData, {
    required String gameDir,
    required String clientJar,
    required String installerPath,
    required String librariesDir,
    required String binDir,
    required String mcVersion,
  }) {
    final known = <String, String>{
      'SIDE': 'client',
      'MINECRAFT_VERSION': mcVersion,
      'ROOT': gameDir,
      'MINECRAFT_JAR': clientJar,
      'INSTALLER': installerPath,
      'LIBRARY_DIR': librariesDir,
      'BIN': binDir,
      'OUTPUTS': binDir,
    };

    String resolveKnown(String input) {
      var out = input;
      for (final e in known.entries) {
        out = out.replaceAll('{${e.key}}', e.value);
      }
      return out;
    }

    final resolved = <String, String>{};
    rawData.forEach((key, value) {
      final sideValue =
          (value as Map)['client'] as String? ?? value['server'] as String? ?? '';
      var v = resolveKnown(sideValue);

      // "[maven:coord]" → 库绝对路径
      if (v.startsWith('[') && v.endsWith(']')) {
        final coord = v.substring(1, v.length - 1);
        v = BaseInstaller.mavenToAbs(coord, librariesDir);
      } else if (v.startsWith('/')) {
        // 安装器内条目（如 /data/client.lzma）→ 解压到 bin 后替换
        final entry = v.substring(1);
        final target = p.join(binDir, entry.split('/').last);
        _extractInstallerEntry(installerPath, entry, target);
        v = target;
      }
      resolved[key] = v;
    });
    return resolved;
  }

  void _extractInstallerEntry(
      String installerPath, String entry, String target) {
    // 同步提取（Rust FFI 同步接口）；失败时抛出
    try {
      final bytes = _readZipSync(installerPath, entry);
      final f = File(target);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsBytesSync(bytes);
    } catch (e) {
      throw InstallerException('从安装器提取 $entry 失败',
          technicalDetail: e.toString());
    }
  }

  // 通过 archive 包同步读取安装器内条目（条目小，性能足够）
  static List<int> _readZipSync(String jarPath, String entryName) {
    final bytes = File(jarPath).readAsBytesSync();
    final archive = arc.ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      if (entry.name == entryName) {
        return entry.content as List<int>;
      }
    }
    throw InstallerException('安装器中不存在条目: $entryName');
  }

  Future<void> _runProcessor({
    required Map<String, dynamic> proc,
    required Map<String, String> data,
    required String librariesDir,
    required String binDir,
    required String installerPath,
    required String clientJar,
    required String mcVersion,
  }) async {
    final mainCoord = proc['jar'] as String? ?? '';
    final classpathCoords = (proc['classpath'] as List? ?? []).cast<String>();
    final rawArgs = (proc['args'] as List? ?? []).map((e) => e.toString()).toList();
    final outputs = proc['outputs'] as Map<String, dynamic>? ?? {};

    // 输出校验 → 断点续装
    if (outputs.isNotEmpty) {
      var allValid = true;
      outputs.forEach((key, sha) {
        final path = _resolveOutputPath(key, data, librariesDir);
        if (path == null || !File(path).existsSync()) {
          allValid = false;
          return;
        }
        // SHA 校验在运行前异步进行会拖慢，这里只检查存在性 + 运行后再校验
      });
      if (allValid) {
        // 深度校验（串行 sha1，失败则重跑）
        var deepValid = true;
        for (final e in outputs.entries) {
          final path = _resolveOutputPath(e.key, data, librariesDir);
          if (path == null) {
            deepValid = false;
            break;
          }
          final actual = await sha1OfFile(path);
          if (actual != e.value.toString()) {
            deepValid = false;
            break;
          }
        }
        if (deepValid) {
          AppLogger.info('Forge', '处理器输出已存在且校验通过，跳过: $mainCoord');
          return;
        }
      }
    }

    // 主类（读处理器 jar 的 MANIFEST.MF）
    final mainJar = BaseInstaller.mavenToAbs(mainCoord, librariesDir);
    if (!File(mainJar).existsSync()) {
      throw InstallerException('处理器 jar 缺失: $mainCoord',
          technicalDetail: mainJar);
    }
    final mainClass = await _readMainClass(mainJar);
    if (mainClass == null) {
      throw InstallerException('处理器 jar 缺少 Main-Class: $mainCoord');
    }

    // classpath
    final cp = <String>[mainJar];
    for (final c in classpathCoords) {
      cp.add(BaseInstaller.mavenToAbs(c, librariesDir));
    }

    // 参数 token 替换
    final args = rawArgs.map((arg) {
      var a = arg;
      // data 键优先
      data.forEach((key, value) {
        a = a.replaceAll('{$key}', value);
      });
      // 剩余已知 token
      a = a
          .replaceAll('{SIDE}', 'client')
          .replaceAll('{MINECRAFT_VERSION}', mcVersion)
          .replaceAll('{ROOT}', gameDir)
          .replaceAll('{MINECRAFT_JAR}', clientJar)
          .replaceAll('{INSTALLER}', installerPath)
          .replaceAll('{LIBRARY_DIR}', librariesDir)
          .replaceAll('{BIN}', binDir)
          .replaceAll('{OUTPUTS}', binDir);
      // 嵌套 maven 坐标（含于方括号）
      a = a.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]'),
        (m) => BaseInstaller.mavenToAbs(m.group(1)!, librariesDir),
      );
      return a;
    }).toList();

    // 运行 java
    final java = _findJavaForProcessors();
    final result = await Process.run(java, [
      '-cp',
      cp.join(Platform.isWindows ? ';' : ':'),
      mainClass,
      ...args,
    ]);
    if (result.exitCode != 0) {
      throw InstallerException(
        '处理器执行失败: $mainCoord',
        technicalDetail: 'exit=${result.exitCode}\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}\n'
            'args: ${args.join(' ')}',
      );
    }
    AppLogger.info('Forge', '处理器完成: $mainCoord');

    // 运行后输出校验
    if (outputs.isNotEmpty) {
      outputs.forEach((key, sha) {
        final path = _resolveOutputPath(key, data, librariesDir);
        if (path == null || !File(path).existsSync()) {
          throw InstallerException('处理器输出缺失: $key',
              technicalDetail: 'path=$path');
        }
      });
    }
  }

  String? _resolveOutputPath(
      String key, Map<String, String> data, String librariesDir) {
    if (data.containsKey(key)) return data[key];
    if (key.startsWith('[') && key.endsWith(']')) {
      return BaseInstaller.mavenToAbs(key.substring(1, key.length - 1), librariesDir);
    }
    return key;
  }

  Future<String?> _readMainClass(String jarPath) async {
    try {
      final manifest = await rust.readZipEntry(
        jarPath: jarPath,
        entryName: 'META-INF/MANIFEST.MF',
      );
      final text = utf8.decode(manifest);
      final match = RegExp(r'Main-Class\s*:\s*([^\r\n]+)').firstMatch(text);
      return match?.group(1)?.trim();
    } catch (e) {
      AppLogger.warn('Forge', '读取 Main-Class 失败: $e');
      return null;
    }
  }

  /// 处理器执行用 Java：优先使用用户设置的，否则 PATH
  String _findJavaForProcessors() {
    final javaPath = ref.read(appSettingsProvider).javaPath;
    if (javaPath.isNotEmpty) return javaPath;
    return Platform.isWindows ? 'javaw' : 'java';
  }
}
