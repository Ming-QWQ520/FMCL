/// 账户页（离线 / 微软设备码 / Yggdrasil 外置登录）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(accountsProvider.notifier).reload(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '账户',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 12),
              PclTag('支持离线 / 微软 / 外置（authlib-injector）'),
              const Spacer(),
              PclButton(
                text: '添加离线账户',
                icon: Icons.person_add_alt_1_rounded,
                onTap: () => _addOffline(context),
              ),
              const SizedBox(width: 10),
              PclButton(
                text: '登录微软账户',
                icon: Icons.verified_user_outlined,
                onTap: () => _loginMicrosoft(context),
              ),
              const SizedBox(width: 10),
              PclButton(
                text: '添加外置账户',
                primary: false,
                icon: Icons.dns_rounded,
                onTap: () => _loginYggdrasil(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: accounts.accounts.isEmpty
                ? const EmptyView(
                    icon: Icons.person_off_outlined,
                    text: '尚未添加账户，启动前需要先登录',
                  )
                : ListView.separated(
                    itemCount: accounts.accounts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final a = accounts.accounts[i];
                      final isCurrent = accounts.current?.id == a.id;
                      return PclPanel(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundColor: _typeColor(
                                a.accountType,
                              ).withAlpha(30),
                              child: Icon(
                                a.accountType == 'microsoft'
                                    ? Icons.verified_user_rounded
                                    : a.accountType == 'yggdrasil'
                                    ? Icons.dns_rounded
                                    : Icons.person_rounded,
                                color: _typeColor(a.accountType),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        a.name,
                                        style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PclTag(
                                        _typeLabel(a.accountType),
                                        color: _typeColor(a.accountType),
                                      ),
                                      if (isCurrent) ...[
                                        const SizedBox(width: 6),
                                        PclTag(
                                          '当前使用',
                                          color: kAccent,
                                          filled: true,
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    a.accountType == 'yggdrasil'
                                        ? '${a.yggdrasilServer ?? ""} · ${a.uuid}'
                                        : a.uuid,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white38
                                          : Colors.black38,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (!isCurrent)
                              PclButton(
                                text: '切换',
                                primary: false,
                                height: 30,
                                fontSize: 12.5,
                                onTap: () => ref
                                    .read(accountsProvider.notifier)
                                    .select(a.id),
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                              ),
                              onPressed: () => ref
                                  .read(accountsProvider.notifier)
                                  .remove(a.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'microsoft':
        return '微软';
      case 'yggdrasil':
        return '外置';
      default:
        return '离线';
    }
  }

  Color _typeColor(String t) {
    switch (t) {
      case 'microsoft':
        return Colors.green;
      case 'yggdrasil':
        return Colors.deepPurple;
      default:
        return kAccent;
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _addOffline(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) {
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
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(accountsProvider.notifier).addOffline(name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: kDanger));
      }
    }
  }

  /// 微软设备码登录（事件流展示）
  Future<void> _loginMicrosoft(BuildContext context) async {
    var userCode = '';
    var verifyUri = '';
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        child: StreamBuilder<rust.MsLoginEvent>(
          stream: rust.microsoftLogin(),
          builder: (context, snap) {
            final ev = snap.data;
            if (ev != null) {
              if (ev.step == 'device_code' && ev.userCode.isNotEmpty) {
                userCode = ev.userCode;
                verifyUri = ev.verificationUri;
              }
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
                        color: Theme.of(context).brightness == Brightness.dark
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
                        color: Theme.of(context).brightness == Brightness.dark
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

  /// 外置登录（Yggdrasil）
  Future<void> _loginYggdrasil(BuildContext context) async {
    final serverC = TextEditingController(text: 'https://littleskin.cn');
    final userC = TextEditingController();
    final passC = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('添加外置账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: serverC,
              decoration: const InputDecoration(
                labelText: '认证服务器',
                hintText: 'https://littleskin.cn 或自制服务器',
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
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('登录'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;

    // 登录中提示
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
            Text('正在登录外置认证服务器...'),
          ],
        ),
      ),
    );

    try {
      final session = await rust.yggdrasilLogin(
        serverUrl: serverC.text.trim(),
        username: userC.text.trim(),
        password: passC.text,
      );
      // 选择角色
      if (!context.mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
      final profile = session.profiles.length == 1
          ? session.profiles.first
          : await showDialog<rust.YggdrasilProfile>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('选择角色'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in session.profiles)
                      ListTile(
                        title: Text(p.name),
                        onTap: () => Navigator.of(context).pop(p),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已添加外置账户：${profile.name}')));
      }
      // 对齐 PCL：添加外置账户后立即准备外置登录组件
      // （authlib-injector.jar 自动下载至 exe\FMCL\lib\authlib-injector）
      await _prepareAuthlibInjector(context);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // 关闭 loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: $e'), backgroundColor: kDanger),
        );
      }
    }
  }

  /// 确保 authlib-injector.jar 就绪（下载在 Rust 侧：官方源 + GitHub 回退）。
  /// 成功/失败均给出可见反馈；失败不阻断账户使用（启动游戏时会自动重试）。
  Future<void> _prepareAuthlibInjector(BuildContext context) async {
    if (!context.mounted) return;
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
    );
    String? error;
    try {
      await rust.ensureAuthlibInjector();
    } catch (e) {
      error = '$e';
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关闭下载提示
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
}
