/// 登录流程对话框（启动页与账户页共用）——对齐 PCL2 登录交互：
///
/// - 离线：玩家名 → 直接创建（本地 UUID 算法与官方一致）
/// - 微软：设备码流程（事件流展示，浏览器授权）
/// - 外置（authlib-injector）：服务器 + 账号 + 密码 → 登录 → 选角色 →
///   自动下载 authlib-injector.jar 至 exe\FMCL\lib\authlib-injector
///
/// 全部流程带 90s 兜底超时；加载框在任何分支下必定关闭；
/// 错误信息必定可见（SnackBar），绝不静默吞掉。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';

/// 登录请求兜底超时（Rust 侧自身超时更短，此处仅防桥路异常挂起）
const Duration _loginTimeout = Duration(seconds: 90);

// ---------------------------------------------------------------------------
// 离线
// ---------------------------------------------------------------------------

Future<void> addOfflineFlow(BuildContext context, WidgetRef ref) async {
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final controller = TextEditingController();
      return AlertDialog(
        title: const Text('添加离线账户'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '玩家名',
            hintText: '1-16 个字符',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              controller.text.trim(),
            ),
            child: const Text('添加'),
          ),
        ],
      );
    },
  );
  if (name == null || name.isEmpty) return;
  try {
    await ref.read(accountsProvider.notifier).addOffline(name);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已添加离线账户：$name')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: kDanger));
    }
  }
}

// ---------------------------------------------------------------------------
// 微软（设备码）
// ---------------------------------------------------------------------------

Future<void> microsoftLoginFlow(BuildContext context, WidgetRef ref) async {
  var userCode = '';
  var verifyUri = '';
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Dialog(
      child: StreamBuilder<rust.MsLoginEvent>(
        stream: rust.microsoftLogin(),
        builder: (context, snap) {
          final ev = snap.data;
          if (ev != null && ev.step == 'device_code' && ev.userCode.isNotEmpty) {
            userCode = ev.userCode;
            verifyUri = ev.verificationUri;
          }
          final failed = ev?.step == 'failed';
          return Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '微软登录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                if (!failed && userCode.isEmpty) ...[
                  const Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kAccent,
                        ),
                      ),
                      SizedBox(width: 10),
                      Text('正在连接微软服务器...'),
                    ],
                  ),
                ] else if (!failed) ...[
                  Text(
                    '请用浏览器打开以下地址并输入代码：',
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          Theme.of(context).brightness == Brightness.dark
                          ? Colors.white54
                          : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    verifyUri,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('登录代码：', style: TextStyle(fontSize: 13)),
                      SelectableText(
                        userCode,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: kAccent,
                          letterSpacing: 2,
                        ),
                      ),
                      IconButton(
                        tooltip: '复制代码',
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: userCode)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ev?.message ?? '等待授权...',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          Theme.of(context).brightness == Brightness.dark
                          ? Colors.white38
                          : Colors.black38,
                    ),
                  ),
                ] else ...[
                  Text(
                    ev?.message ?? '登录失败',
                    style: const TextStyle(color: kDanger),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PclButton(
                      text: failed ? '关闭' : '取消',
                      primary: false,
                      onTap: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
  ).then((_) => ref.read(accountsProvider.notifier).reload());
}

// ---------------------------------------------------------------------------
// 外置登录（authlib-injector）
// ---------------------------------------------------------------------------

Future<void> yggdrasilLoginFlow(
  BuildContext context,
  WidgetRef ref, {
  String initialServer = 'https://littleskin.cn',
}) async {
  final serverC = TextEditingController(text: initialServer);
  final userC = TextEditingController();
  final passC = TextEditingController();

  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('添加外置账户'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: serverC,
            decoration: const InputDecoration(
              labelText: '认证服务器',
              hintText: '如 https://littleskin.cn',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: userC,
            decoration: const InputDecoration(labelText: '邮箱 / 用户名'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passC,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('登录'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  if (!context.mounted) return;

  await _runWithLoading(
    context,
    '正在登录外置认证服务器...',
    () async {
      final session = await rust
          .yggdrasilLogin(
            serverUrl: serverC.text.trim(),
            username: userC.text.trim(),
            password: passC.text,
          )
          .timeout(_loginTimeout);
      if (!context.mounted) return;
      // 选择角色
      final profile = session.profiles.length == 1
          ? session.profiles.first
          : await showDialog<rust.YggdrasilProfile>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('选择角色'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in session.profiles)
                      ListTile(
                        title: Text(p.name),
                        onTap: () => Navigator.of(dialogContext).pop(p),
                      ),
                  ],
                ),
              ),
            );
      if (profile == null) return;
      await rust.saveYggdrasilAccount(
        apiRoot: session.apiRoot,
        accessToken: session.accessToken,
        clientToken: session.clientToken,
        profileId: profile.id,
        profileName: profile.name,
      );
      await ref.read(accountsProvider.notifier).reload();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加外置账户：${profile.name}')),
        );
      }
      // 对齐 PCL：添加外置账户后立即准备外置登录组件
      if (context.mounted) {
        await ensureAuthlibInjectorFlow(context);
      }
    },
  );
}

// ---------------------------------------------------------------------------
// authlib-injector 下载（Rust 侧官方源 + GitHub 回退）
// ---------------------------------------------------------------------------

Future<void> ensureAuthlibInjectorFlow(BuildContext context) async {
  if (!context.mounted) return;
  // 预先捕获 NavigatorState：即便页面在下载期间被销毁也能关闭提示框
  final nav = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                '正在下载外置登录组件\nauthlib-injector.jar ...',
                style: TextStyle(fontSize: 13.5, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  String? error;
  try {
    await rust
        .ensureAuthlibInjector()
        .timeout(const Duration(seconds: 120));
  } catch (e) {
    error = '$e';
  }
  nav.pop(); // 关闭下载提示
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        error == null
            ? '外置登录组件已就绪（FMCL\\lib\\authlib-injector\\authlib-injector.jar）'
            : 'authlib-injector 下载失败：$error\n启动游戏时会自动重试',
      ),
      backgroundColor: error == null ? kAccent : Colors.orange,
    ),
  );
}

// ---------------------------------------------------------------------------
// 通用「加载框 + 必定关闭 + 错误可见」执行器
// ---------------------------------------------------------------------------

Future<void> _runWithLoading(
  BuildContext context,
  String message,
  Future<void> Function() task,
) async {
  // 预先捕获根 Navigator（对话框栈）：即使页面被销毁也能关闭加载框
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  Object? error;
  try {
    await task();
  } catch (e) {
    error = e;
  }
  // 无论成败（甚至页面已销毁）都关闭加载框
  nav.pop();
  if (error != null) {
    final msg = '登录失败: $error';
    if (messenger != null) {
      // 捕获的 messenger 属于页面 Scaffold；页面销毁后其 SnackBar 不再展示，
      // 但登录失败时页面必然仍在（用户刚点击），此路径可靠
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: kDanger),
      );
    }
  }
}
