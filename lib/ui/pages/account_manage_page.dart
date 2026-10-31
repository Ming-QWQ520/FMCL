/// 账户管理页 —— 100% 借鉴参照项目 AccountPage 布局（PCL2 主题化）：
///
/// - 顶部标题栏：返回 + 「账户管理」
/// - 左栏（宽 210）导航：
///   · 离线账户 —— 添加离线账户
///   · 微软账户 —— 设备码正版登录
///   · LittleSkin（littleskin.cn）—— 外置登录（预设服务器）
///   · 底部「添加认证服务器」—— 任意 authlib-injector 皮肤站
/// - 右栏：已添加的账户列表（外置账户使用皮肤站头像 API），
///   支持切换 / 删除；登录流程与启动页共用 login_dialogs
///
/// 账户数据与登录逻辑全部在 Rust（store/auth_api），Flutter 仅渲染与通信。
/// 外置登录组件 authlib-injector.jar 自动下载至 exe\FMCL\lib\authlib-injector。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../dialogs/login_dialogs.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class AccountManagePage extends ConsumerStatefulWidget {
  const AccountManagePage({super.key});

  @override
  ConsumerState<AccountManagePage> createState() => _AccountManagePageState();
}

class _AccountManagePageState extends ConsumerState<AccountManagePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(accountsProvider.notifier).reload(),
    );
  }

  // ---------------------------------------------------------------------------
  // 左栏动作（参照项目 _navBtn 一一对应）
  // ---------------------------------------------------------------------------

  void _addOffline() => addOfflineFlow(context, ref);

  void _loginMicrosoft() => microsoftLoginFlow(context, ref);

  /// LittleSkin 预设外置登录（服务器固定，对齐参照项目 _showLittleSkinLogin）
  Future<void> _loginLittleSkin() async {
    final ok = await ensureAuthlibInjectorFlow(context);
    if (!ok || !mounted) return;
    await yggdrasilLoginFlow(
      context,
      ref,
      title: 'LittleSkin 外置登录',
      presetServer: 'https://littleskin.cn',
    );
  }

  /// 任意 authlib-injector 认证服务器（对齐参照项目 _showCustomServerLogin）
  Future<void> _loginCustomServer() async {
    final ok = await ensureAuthlibInjectorFlow(context);
    if (!ok || !mounted) return;
    await yggdrasilLoginFlow(context, ref, title: '添加认证服务器');
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? kDarkBg : kLightBg,
      body: Column(
        children: [
          // ---------- 标题栏（返回 + 账户管理） ----------
          Container(
            height: 48,
            color: kAccent,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _CircleBarIcon(
                  icon: Icons.arrow_back_rounded,
                  tooltip: '返回',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '账户管理',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildLeftNav(context, isDark),
                Expanded(child: _buildAccountList(context, isDark)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftNav(BuildContext context, bool isDark) {
    final accounts = ref.watch(accountsProvider);
    final offlineCount = accounts.accounts
        .where((a) => a.accountType == 'offline')
        .length;
    final subText = isDark ? Colors.white38 : Colors.black38;
    return Container(
      width: 212,
      decoration: BoxDecoration(
        color: isDark ? kDarkPanel : kLightPanel,
        border: Border(
          right: BorderSide(
            color: isDark
                ? Colors.white.withAlpha(16)
                : Colors.black.withAlpha(16),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          _navBtn(
            context,
            Icons.person_add_alt_1_rounded,
            '离线账户',
            '添加（$offlineCount）',
            _addOffline,
          ),
          _navBtn(
            context,
            Icons.verified_user_outlined,
            '微软账户',
            '正版登录 · 设备码',
            _loginMicrosoft,
          ),
          _navBtn(
            context,
            Icons.cloud_outlined,
            'LittleSkin',
            'littleskin.cn',
            _loginLittleSkin,
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                PclButton(
                  text: '添加认证服务器',
                  primary: false,
                  height: 34,
                  fontSize: 12.5,
                  icon: Icons.dns_rounded,
                  onTap: _loginCustomServer,
                ),
                const SizedBox(height: 8),
                Text(
                  '外置登录（authlib-injector）',
                  style: TextStyle(fontSize: 11, color: subText),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navBtn(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Row(
              children: [
                Icon(icon, size: 19, color: kAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountList(BuildContext context, bool isDark) {
    final accounts = ref.watch(accountsProvider);
    final subText = isDark ? Colors.white38 : Colors.black38;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已添加的账户',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: accounts.accounts.isEmpty
                ? Center(
                    child: PclPanel(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.account_circle_outlined,
                            size: 40,
                            color: subText,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '暂无账户',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '点击左侧添加离线 / 微软 / 外置登录账户',
                            style: TextStyle(fontSize: 12.5, color: subText),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: accounts.accounts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final a = accounts.accounts[i];
                      final isCurrent = accounts.current?.id == a.id;
                      return _accountTile(context, a, isCurrent, isDark);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _accountTile(
    BuildContext context,
    rust.Account a,
    bool isCurrent,
    bool isDark,
  ) {
    final subText = isDark ? Colors.white38 : Colors.black38;
    final isExternal = a.accountType == 'yggdrasil';
    final host = _hostOf(a.yggdrasilServer);
    final subtitle = switch (a.accountType) {
      'microsoft' => '微软正版登录 · ${a.uuid}',
      'yggdrasil' => '$host · ${a.uuid}',
      _ => '离线登录',
    };
    // 外置账户头像：皮肤站 avatar API（参照项目同款；加载失败回退图标）
    final avatarUrl = isExternal && host.contains('littleskin')
        ? 'https://littleskin.cn/avatar/player/${Uri.encodeComponent(a.name)}?size=64'
        : null;

    return PclPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: isCurrent ? null : () async {
        await ref.read(accountsProvider.notifier).select(a.id);
      },
      child: Row(
        children: [
          _avatar(avatarUrl, a, isCurrent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        a.name,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    PclTag(_typeLabel(a.accountType), color: _typeColor(a.accountType)),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      PclTag('当前使用', color: kAccent, filled: true),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: subText),
                  maxLines: 1,
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
              onTap: () async {
                await ref.read(accountsProvider.notifier).select(a.id);
              },
            ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '删除',
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
            hoverColor: kDanger.withAlpha(30),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('删除账户'),
                  content: Text('确定删除账户「${a.name}」吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: kDanger),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(accountsProvider.notifier).remove(a.id);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _avatar(String? avatarUrl, rust.Account a, bool isCurrent) {
    final fallback = Icon(
      switch (a.accountType) {
        'microsoft' => Icons.verified_user_rounded,
        'yggdrasil' => Icons.dns_rounded,
        _ => Icons.person_rounded,
      },
      color: isCurrent ? kAccent : _typeColor(a.accountType),
      size: 22,
    );
    Widget inner;
    if (avatarUrl != null) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          avatarUrl,
          width: 38,
          height: 38,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    } else {
      inner = fallback;
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: _typeColor(a.accountType).withAlpha(26),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: inner,
    );
  }

  static String _hostOf(String? server) {
    if (server == null || server.isEmpty) return '外置';
    return server.replaceFirst(RegExp('^https?://'), '').split('/').first;
  }

  static String _typeLabel(String t) {
    switch (t) {
      case 'microsoft':
        return '微软';
      case 'yggdrasil':
        return '外置';
      default:
        return '离线';
    }
  }

  static Color _typeColor(String t) {
    switch (t) {
      case 'microsoft':
        return Colors.green;
      case 'yggdrasil':
        return Colors.deepPurple;
      default:
        return kAccent;
    }
  }
}

/// 标题栏圆形图标按钮（PCL2 MyIconButton：CornerRadius 1000，hover 白 α50）
class _CircleBarIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CircleBarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_CircleBarIcon> createState() => _CircleBarIconState();
}

class _CircleBarIconState extends State<_CircleBarIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hover ? Colors.white.withAlpha(50) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 15, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
