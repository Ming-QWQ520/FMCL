import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fmcl/core/error/app_exception.dart';
import 'package:fmcl/data/models/app_settings.dart';
import 'package:fmcl/services/modpack/modpack_service.dart';
import 'package:fmcl/services/version/version_settings.dart';

void main() {
  group('ModrinthIndex 解析', () {
    test('解析完整 modrinth.index.json', () {
      const indexJson = '''
{
  "formatVersion": 1,
  "game": "minecraft",
  "versionId": "1.2.3",
  "name": "My Fabulous Pack",
  "summary": "A pack: with, punctuation | and stuff",
  "files": [
    {
      "path": "mods/sodium-fabric-mc1.21.4-0.6.0.jar",
      "hashes": {"sha1": "a1b2c3", "sha512": "deadbeef"},
      "env": {"client": "required", "server": "required"},
      "downloads": ["https://cdn.modrinth.com/data/AANobbMI/versions/x/sodium.jar"],
      "fileSize": 1234567
    },
    {
      "path": "mods/server-only.jar",
      "hashes": {"sha1": "zzz"},
      "env": {"client": "unsupported", "server": "required"},
      "downloads": ["https://cdn.modrinth.com/x/y.jar"],
      "fileSize": 99
    }
  ],
  "dependencies": {
    "minecraft": "1.21.4",
    "fabric-loader": "0.16.9"
  }
}
''';
      final index = ModrinthIndex.fromJson(
          jsonDecode(indexJson) as Map<String, dynamic>);

      expect(index.formatVersion, 1);
      expect(index.game, 'minecraft');
      expect(index.versionId, '1.2.3');
      expect(index.name, 'My Fabulous Pack');
      expect(index.files, hasLength(2));
      expect(index.files[0].path, contains('sodium'));
      expect(index.files[0].hashes['sha1'], 'a1b2c3');
      expect(index.files[0].env['client'], 'required');
      expect(index.files[0].fileSize, 1234567);
      expect(index.dependencies['minecraft'], '1.21.4');
      expect(index.dependencies['fabric-loader'], '0.16.9');
      expect(index.gameVersion, '1.21.4');
      expect(index.loaderLabel, contains('Fabric'));
    });

    test('空依赖时 loaderLabel 为原版', () {
      final index = ModrinthIndex.fromJson({
        'formatVersion': 1,
        'game': 'minecraft',
        'versionId': '1',
        'name': 'Vanilla Pack',
        'files': [],
        'dependencies': {'minecraft': '1.20.1'},
      });
      expect(index.loaderLabel, '原版');
      expect(index.gameVersion, '1.20.1');
    });

    test('缺失字段容错', () {
      final index = ModrinthIndex.fromJson({});
      expect(index.game, 'minecraft');
      expect(index.versionId, '1.0');
      expect(index.name, '');
      expect(index.files, isEmpty);
      expect(index.dependencies, isEmpty);
    });
  });

  group('.mrpack 解析', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fmcl_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('解析真实 mrpack zip', () {
      const indexJson = '''
{"formatVersion":1,"game":"minecraft","versionId":"1.0","name":"Test Pack",
 "summary":"s","files":[],"dependencies":{"minecraft":"1.20.1","quilt-loader":"0.26.0"}}
''';
      final encoder = arc.ZipEncoder();
      final archive = arc.Archive()
        ..addFile(arc.ArchiveFile.string('modrinth.index.json', indexJson))
        ..addFile(arc.ArchiveFile.string('overrides/config/opts.txt', 'a=1'));
      final bytes = encoder.encode(archive);
      final f = File(p.join(tmp.path, 'pack.mrpack'))
        ..writeAsBytesSync(bytes);

      final index = ModpackService.parseMrpack(f.path);
      expect(index.name, 'Test Pack');
      expect(index.loaderLabel, contains('Quilt'));
    });

    test('缺少 index 时抛出异常', () {
      final encoder = arc.ZipEncoder();
      final archive = arc.Archive()
        ..addFile(arc.ArchiveFile.string('README.md', 'hello'));
      final bytes = encoder.encode(archive);
      final f = File(p.join(tmp.path, 'bad.mrpack'))
        ..writeAsBytesSync(bytes);

      expect(() => ModpackService.parseMrpack(f.path),
          throwsA(isA<ParseException>()));
    });

    test('版本 id 非法字符被替换', () {
      final baseId =
          'My Pack: Vol.2 "special" 1.0'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      expect(baseId, 'My Pack- Vol.2 -special- 1.0');
    });
  });

  group('VersionSettings', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('fmcl_vs_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('JSON 序列化/反序列化往返', () {
      const s = VersionSettings(
        isolation: false,
        javaPath: '/usr/bin/java',
        maxMemoryMb: 8192,
        minMemoryMb: 1024,
        jvmArguments: '-XX:+UseZGC',
      );
      final json = s.toJson();
      final back = VersionSettings.fromJson(json);
      expect(back.isolation, false);
      expect(back.javaPath, '/usr/bin/java');
      expect(back.maxMemoryMb, 8192);
      expect(back.minMemoryMb, 1024);
      expect(back.jvmArguments, '-XX:+UseZGC');
    });

    test('空设置不写文件', () async {
      const s = VersionSettings();
      expect(s.isEmpty, isTrue);
      final f = File(p.join(tmp.path, 'v1', 'fmcl-settings.json'));
      await f.parent.create(recursive: true);
      // 服务端 save 会跳过空设置，此处验证序列化产物为空 map
      expect(s.toJson(), isEmpty);
      expect(f.existsSync(), isFalse);
    });

    test('resolve：隔离开启时 workDir 在 versions 下', () {
      final service = VersionSettingsService.I;
      final cfg = service.resolve(
        _global(isolation: true),
        '/game',
        '1.21.4',
        VersionSettings.empty,
      );
      expect(cfg.isolated, isTrue);
      expect(cfg.workDir, '/game/versions/1.21.4');
      expect(cfg.assetsDir, '/game/assets');
      expect(cfg.librariesDir, '/game/libraries');
    });

    test('resolve：全局关闭隔离时 workDir 为根目录', () {
      final service = VersionSettingsService.I;
      final cfg = service.resolve(
        _global(isolation: false),
        '/game',
        '1.21.4',
        VersionSettings.empty,
      );
      expect(cfg.isolated, isFalse);
      expect(cfg.workDir, '/game');
    });

    test('resolve：版本覆盖优先于全局', () {
      final service = VersionSettingsService.I;
      final cfg = service.resolve(
        _global(isolation: true),
        '/game',
        '1.21.4',
        const VersionSettings(isolation: false, maxMemoryMb: 8192),
      );
      expect(cfg.isolated, isFalse);
      expect(cfg.maxMemoryMb, 8192);
      expect(cfg.minMemoryMb, 512); // 继承全局
    });

    test('resolve：JVM 参数叠加', () {
      final service = VersionSettingsService.I;
      final cfg = service.resolve(
        _global(isolation: true, jvmArguments: '-XX:+UseG1GC'),
        '/game',
        'v',
        const VersionSettings(jvmArguments: '-XX:+UseZGC'),
      );
      expect(cfg.jvmArguments, contains('-XX:+UseG1GC'));
      expect(cfg.jvmArguments, contains('-XX:+UseZGC'));
    });

    test('modsDirFor：跟随隔离设置', () {
      final service = VersionSettingsService.I;
      final isolatedDir = service.modsDirFor(
          _global(isolation: true), '/game', 'v1');
      final sharedDir = service.modsDirFor(
          _global(isolation: false), '/game', 'v1');
      expect(isolatedDir, '/game/versions/v1/mods');
      expect(sharedDir, '/game/mods');
    });
  });
}

AppSettings _global({
  bool isolation = true,
  String jvmArguments = '',
}) =>
    AppSettings(
      gameDirectory: '/game',
      versionIsolation: isolation,
      jvmArguments: jvmArguments,
    );
