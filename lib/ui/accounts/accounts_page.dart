import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/game_account.dart';
import '../../providers/account_provider.dart';
import '../../services/account/microsoft_auth.dart';
import '../../services/account/yggdrasil_auth.dart';
import '../../widgets/common.dart';

/// 账户页：离线 / 微软 / Yggdrasil 三类登录。
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountsProvider);
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              children: [
                Text('账户', style: context.titleStyle),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _busy ? null : _addOffline,
                  icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                  label: const Text('添加离线账户'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              children: [
                // ---------- 微软登录 ----------
                _LoginActionCard(
                  title: '微软账户登录',
                  description: '正版 Minecraft 账户，支持皮肤与好友功能。'
                      '需要先在设置中配置 Azure Client ID（见 README）。',
                  icon: Icons.verified_user_rounded,
                  color: const Color(0xFF4A9FF5),
                  buttonLabel: '设备码登录',
                  enabled: !_busy,
                  onPressed: _loginMicrosoft,
                ),
                const SizedBox(height: 10),
                // ---------- Yggdrasil ----------
                _LoginActionCard(
                  title: 'Yggdrasil 外置登录',
                  description: 'LittleSkin 等第三方认证服务器（authlib-injector）。',
                  icon: Icons.link_rounded,
                  color: const Color(0xFF9B7BDE),
                  buttonLabel: '外置登录',
                  enabled: !_busy,
                  onPressed: _loginYggdrasil,
                ),
                const SizedBox(height: 18),
                SectionHeader('已保存的账户（${state.accounts.length}）'),
                if (state.accounts.isEmpty)
                  AppCard(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('还没有账户，先添加一个吧',
                            style: context.captionStyle),
                      ),
                    ),
                  )
                else
                  ...state.accounts.map((a) => _AccountTile(
                        account: a,
                        selected: state.currentId == a.id,
                        onSelect: () => ref
                            .read(accountsProvider.notifier)
                            .select(a.id),
                        onDelete: () =>
                            ref.read(accountsProvider.notifier).remove(a.id),
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addOffline() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加离线账户'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(
            hintText: '玩家名（游戏内显示的名字）',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('添加')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(accountsProvider.notifier).addOfflineAccount(name);
      _snack('离线账户 $name 已添加并设为当前');
    } on AppException catch (e) {
      _snack(e.userMessage, error: true);
    }
  }

  Future<void> _loginMicrosoft() async {
    // 检查 client id 配置
    final configured = MicrosoftAuthService.isConfigured;
    if (!configured) {
      _snack('请先在 设置 → 关于 中配置 Azure Client ID（步骤见 README）',
          error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final deviceCode = await MicrosoftAuthService.requestDeviceCode();
      if (!mounted) return;
      // 展示设备码对话框并轮询
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _DeviceCodeDialog(info: deviceCode),
      );
      if (result == true) {
        _snack('微软登录成功');
      }
    } on AppException catch (e) {
      _snack(e.userMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loginYggdrasil() async {
    final serverCtrl = TextEditingController(text: 'https://littleskin.cn/api/yggdrasil');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yggdrasil 外置登录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: serverCtrl,
              decoration: const InputDecoration(labelText: '认证服务器地址'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: userCtrl,
              decoration:
                  const InputDecoration(labelText: '邮箱或用户名'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('登录')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final meta = await YggdrasilAuthService.fetchServerMeta(serverCtrl.text);
      final session = await YggdrasilAuthService.authenticate(
        apiRoot: meta.apiRoot,
        username: userCtrl.text.trim(),
        password: passCtrl.text,
      );
      // 对齐 PCL：多角色时弹出选择列表
      String profileId = session.profileId;
      String profileName = session.profileName;
      if (session.availableProfiles.length > 1) {
        if (!mounted) return;
        final selected = await showDialog<YggdrasilProfile>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('选择角色'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: session.availableProfiles
                  .map((p) => ListTile(
                        leading: CircleAvatar(
                          child: Text(p.name.characters.first.toUpperCase()),
                        ),
                        title: Text(p.name),
                        subtitle: Text(p.id),
                        onTap: () => Navigator.pop(ctx, p),
                      ))
                  .toList(),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消')),
            ],
          ),
        );
        if (selected == null) return;
        profileId = selected.id;
        profileName = selected.name;
      }
      await ref.read(accountsProvider.notifier).addYggdrasilAccount(
            serverUrl: meta.apiRoot,
            name: profileName,
            accessToken: session.accessToken,
            uuid: profileId,
            profileId: profileId,
            expiresAt: 0,
          );
      _snack('外置登录成功：$profileName @ ${meta.serverName}');
    } on AppException catch (e) {
      _snack(e.userMessage, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}

class _LoginActionCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final String buttonLabel;
  final bool enabled;
  final VoidCallback onPressed;

  const _LoginActionCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.buttonLabel,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withAlpha(28),
              borderRadius: BorderRadius.circular(AppTheme.radiusM),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: context.captionStyle,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: enabled ? onPressed : null,
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final GameAccount account;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _AccountTile({
    required this.account,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: onSelect,
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.primary.withAlpha(36),
              child: Text(
                account.name.characters.first.toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(account.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      if (selected)
                        Icon(Icons.check_circle_rounded,
                            size: 17, color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                  Text(
                    '${account.typeLabel}账户 · ${account.uuid}',
                    style: context.captionStyle,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(110)),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 微软设备码对话框（展示 user code + 轮询）
class _DeviceCodeDialog extends ConsumerStatefulWidget {
  final DeviceCodeInfo info;

  const _DeviceCodeDialog({required this.info});

  @override
  ConsumerState<_DeviceCodeDialog> createState() => _DeviceCodeDialogState();
}

class _DeviceCodeDialogState extends ConsumerState<_DeviceCodeDialog> {
  String _status = '等待授权...';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    try {
      final account = await MicrosoftAuthService.fullLogin(widget.info);
      await ref.read(accountsProvider.notifier).addMicrosoftAccount(account);
      if (!mounted) return;
      setState(() {
        _status = '登录成功！';
        _done = true;
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '登录失败: $e';
        _done = true;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('微软设备码登录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1. 在浏览器打开：', style: context.captionStyle),
          Text(widget.info.verificationUri,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.accentBlue)),
          const SizedBox(height: 12),
          Text('2. 输入以下代码：', style: context.captionStyle),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(22),
              borderRadius: BorderRadius.circular(AppTheme.radiusM),
            ),
            child: Text(
              widget.info.userCode,
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 3),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (!_done)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: 8),
              Expanded(child: Text(_status, style: context.captionStyle)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
