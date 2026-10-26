import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fmcl/data/models/app_settings.dart';

void main() {
  group('AppSettings 新字段向后兼容', () {
    test('旧版本 JSON（无 versionIsolation/autoInstallJava）可解析', () {
      // 模拟 FMCL v1.0 的旧设置文件
      final old = {
        'themeMode': 1,
        'gameDirectory': '/home/user/.minecraft',
        'maxMemoryMb': 4096,
        'minMemoryMb': 1024,
        'downloadSourceIndex': 1,
        'lastVersionId': '1.21.4',
      };
      final s = AppSettings.fromJson(old);
      expect(s.gameDirectory, '/home/user/.minecraft');
      expect(s.maxMemoryMb, 4096);
      // 新字段回退默认值
      expect(s.versionIsolation, isTrue); // PCL2 式默认开启
      expect(s.autoInstallJava, isTrue);
    });

    test('完整 JSON 往返（含新字段）', () {
      const s = AppSettings(
        gameDirectory: '/game',
        versionIsolation: false,
        autoInstallJava: false,
        maxMemoryMb: 8192,
      );
      final json = s.toJson();
      expect(json['versionIsolation'], false);
      expect(json['autoInstallJava'], false);
      final back = AppSettings.fromJson(json);
      expect(back.versionIsolation, false);
      expect(back.autoInstallJava, false);
      expect(back.maxMemoryMb, 8192);
    });

    test('copyWith 保留未指定的新字段', () {
      const base = AppSettings(gameDirectory: '/g');
      final next = base.copyWith(maxMemoryMb: 6144);
      expect(next.versionIsolation, base.versionIsolation);
      expect(next.autoInstallJava, base.autoInstallJava);
      expect(next.maxMemoryMb, 6144);
    });

    test('损坏 JSON 抛出后由上层降级（jsonDecode 行为保障）', () {
      expect(() => jsonDecode('not-json'), throwsFormatException);
    });
  });
}
