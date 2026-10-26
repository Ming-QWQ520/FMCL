import 'package:flutter_test/flutter_test.dart';

import 'package:fmcl/services/launch/argument_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FMCL 冒烟测试 - 测试管线可用', () {
    expect(1 + 1, 2);
  });

  test('离线 UUID 生成 - Mojang 离线算法格式', () {
    final uuid = LaunchArgumentsBuilder.offlineUuid('Notch');
    // 离线 UUID 长度 36，version 位为 3（MD5 哈希 UUID）
    expect(uuid.length, 36);
    expect(uuid[14], '3');
    // variant 位为 8/9/a/b
    expect('89ab'.contains(uuid[19]), isTrue);
  });

  test('离线 UUID 对相同名字确定性', () {
    expect(
      LaunchArgumentsBuilder.offlineUuid('Steve'),
      LaunchArgumentsBuilder.offlineUuid('Steve'),
    );
    expect(
      LaunchArgumentsBuilder.offlineUuid('Steve'),
      isNot(LaunchArgumentsBuilder.offlineUuid('Alex')),
    );
  });

  test('参数模板替换', () {
    final args = LaunchArgumentsBuilder.buildJvmArgs(
      inheritedJvmArgs: [
        [r'-Djava.library.path=${natives_directory}'],
      ],
      nativesDir: '/tmp/natives',
      classpath: '/tmp/cp',
      classpathSeparator: ':',
      minMemoryMb: 512,
      maxMemoryMb: 2048,
      extraJvmArgs: '',
      javaAgentArg: '',
      loggingArgument: '',
    );
    expect(args, contains('-Xmx2048m'));
    expect(args, contains('-Xmn512m'));
    expect(args, contains('-Djava.library.path=/tmp/natives'));
  });
}
