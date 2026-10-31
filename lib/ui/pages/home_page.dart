/// 主页 —— 100% 对齐 PCL2 启动页（PageLaunchLeft / PageLaunchRight）：
///
/// 左栏（宽 300，PCL2 PageLaunchLeft 原样还原）：
///   1. 顶部登录方式药丸（CornerRadius 13 / 高 27，点击展开：正版 / 离线 / 外置）
///   2. 中部登录区（PanLogin）：已登录 → 头像 + 用户名 + 登录方式；
///      未登录 → 按所选方式显示登录表单
///   3. 大启动按钮（Height 54 / Margin 20，主题色；版本名以 11 号字
///      叠放在按钮内部底部 —— PCL2 LabVersion）
///   4. 底部「版本选择」「版本设置」按钮（Height 35 —— PCL2 BtnVersion/BtnMore）
///
/// 右栏（PCL2 PageLaunchRight）：启动日志卡片 + 运行中会话；
/// 没有公告面板（按需求移除）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../dialogs/login_dialogs.dart';
import '../dialogs/version_settings_dialog.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

/// PCL2 启动按钮绿（与截图一致）
const Color _launchGreen = Color(0xFF3DA039);
const Color _launchGreenHover = Color(0xFF358D32);
const Color _launchGreenDeep = Color(0xFF2E7C2B);

/// 登录方式（PCL2 LoginType）
enum _AuthType { microsoft, offline, yggdrasil }

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 当前登录方式选择（未选中时跟随当前账户）
  _AuthType? _authOverride;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedVersionProvider);
    final accounts = ref.watch(accountsProvider);
    final cur = accounts.current;
    final sessions = ref.watch(launchSessionsProvider);
    final active = sessions.where((s) => s.isActive).toList();

    // 登录方式：优先手动选择，否则跟随当前账户类型
    final authType = _authOverride ?? _typeOf(cur);

    return Padding(
      padding: const EdgeInsets.all(0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ==================== 左栏（PCL2 PageLaunchLeft，宽 300） ====================
          Container(
            width: 300,
            // 左栏加深底色：保证白色文字与蓝色元素在任意背景图/纯色下可读
            //（PCL2 左栏同样为暗色半透明覆盖在背景图上）
            color: Colors.black.withAlpha(90),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                // ---------- 1. 登录方式药丸（可展开单选） ----------
                _AuthTypePill(
                  authType: authType,
                  account: cur,
                  onPick: (t) => setState(() => _authOverride = t),
                ),
                // ---------- 2. 登录区 / 账户区（PanLogin） ----------
                Expanded(
                  child: _LoginArea(authType: authType, account: cur),
                ),
                // ---------- 3. 大启动按钮（Height 54，版本名内嵌底部） ----------
                _LaunchButton(selected: selected, activeCount: active.length),
                const SizedBox(height: 10),
                // ---------- 4. 版本选择 / 版本设置（Height 35） ----------
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: PclButton(
                          text: '版本选择',
                          height: 35,
                          fontSize: 13.5,
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (_) => const _VersionSelectorDialog(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      PclButton(
                        text: '版本设置',
                        height: 35,
                        fontSize: 13.5,
                        onTap: () {
                          if (selected.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('请先选择版本')),
                            );
                            return;
                          }
                          showDialog<void>(
                            context: context,
                            builder: (_) =>
                                VersionSettingsDialog(versionId: selected),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ==================== 右栏（PCL2 PageLaunchRight） ====================
          Expanded(
            child: _LaunchLogPanel(activeSessions: active),
          ),
        ],
      ),
    );
  }

  static _AuthType _typeOf(rust.Account? a) {
    return switch (a?.accountType) {
      'microsoft' => _AuthType.microsoft,
      'yggdrasil' => _AuthType.yggdrasil,
      _ => _AuthType.offline,
    };
  }
}

// ---------------------------------------------------------------------------
// 登录方式药丸（PCL2 PanTypeOne：CornerRadius 13 / MinHeight 27，
// 图标 + 文字；点击展开 PanType 单选：正版 / 离线 / 外置）
// ---------------------------------------------------------------------------
class _AuthTypePill extends StatefulWidget {
  final _AuthType authType;
  final rust.Account? account;
  final ValueChanged<_AuthType> onPick;

  const _AuthTypePill({
    required this.authType,
    required this.account,
    required this.onPick,
  });

  @override
  State<_AuthTypePill> createState() => _AuthTypePillState();
}

class _AuthTypePillState extends State<_AuthTypePill> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // 药丸（半透明圆角 13，高 27）
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                height: 27,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(46),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconOf(widget.authType), size: 15, color: kAccent),
                    const SizedBox(width: 8),
                    Text(
                      _labelOf(widget.authType, widget.account),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: kAccent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(
                        Icons.expand_more_rounded,
                        size: 15,
                        color: kAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 展开的登录方式单选（PCL2 PanType：正版 / 离线）
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 150),
            sizeCurve: Curves.easeOut,
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final t in _AuthType.values) ...[
                    _AuthTypeRadio(
                      selected: widget.authType == t,
                      icon: _iconOf(t),
                      label: switch (t) {
                        _AuthType.microsoft => '正版',
                        _AuthType.offline => '离线',
                        _AuthType.yggdrasil => '外置',
                      },
                      onTap: () {
                        widget.onPick(t);
                        setState(() => _expanded = false);
                      },
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconOf(_AuthType t) {
    return switch (t) {
      _AuthType.microsoft => Icons.verified_user_rounded,
      _AuthType.yggdrasil => Icons.dns_rounded,
      _AuthType.offline => Icons.person_rounded,
    };
  }

  static String _labelOf(_AuthType t, rust.Account? account) {
    final type = account?.accountType;
    return switch (t) {
      _AuthType.microsoft => type == 'microsoft' ? '微软正版' : '正版登录',
      _AuthType.yggdrasil =>
        type == 'yggdrasil' ? _serverLabel(account!) : '外置登录',
      _AuthType.offline => type == 'offline' ? '离线模式' : '离线登录',
    };
  }

  static String _serverLabel(rust.Account a) {
    final server = a.yggdrasilServer ?? '';
    if (server.isEmpty) return '外置登录';
    final host = server
        .replaceFirst(RegExp('^https?://'), '')
        .split('/')
        .first;
    return '$host 登录';
  }
}

/// 登录方式单选项（PCL2 MyRadioButton 小样式）
class _AuthTypeRadio extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AuthTypeRadio({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 27,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected
                ? kAccent.withAlpha(40)
                : Colors.white.withAlpha(36),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected ? kAccent : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? kAccent : Colors.white70,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? kAccent : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 登录区 / 账户区（PCL2 PanLogin）
// ---------------------------------------------------------------------------
class _LoginArea extends ConsumerWidget {
  final _AuthType authType;
  final rust.Account? account;

  const _LoginArea({required this.authType, required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 当前账户与所选登录方式匹配 → 显示账户卡
    if (account != null &&
        account!.accountType == _typeString(authType)) {
      return _AccountView(account: account!);
    }
    return _LoginForm(authType: authType);
  }

  static String _typeString(_AuthType t) {
    return switch (t) {
      _AuthType.microsoft => 'microsoft',
      _AuthType.yggdrasil => 'yggdrasil',
      _AuthType.offline => 'offline',
    };
  }
}

/// 已登录视图（头像 + 用户名 + 登录方式，PCL2 登录完成态）
class _AccountView extends ConsumerWidget {
  final rust.Account account;

  const _AccountView({required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final typeLabel = switch (account.accountType) {
      'microsoft' => '微软正版',
      'yggdrasil' => '外置登录 · ${_host(account.yggdrasilServer)}',
      _ => '离线模式',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: Colors.white.withAlpha(60),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: account.skinUrl != null && account.skinUrl!.isNotEmpty
                  ? Image.network(
                      account.skinUrl!,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.person_rounded,
                        size: 34,
                        color: kAccent,
                      ),
                    )
                  : const Icon(Icons.person_rounded, size: 34, color: kAccent),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            account.name,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.white,
              shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            typeLabel,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white70 : Colors.white.withAlpha(220),
              shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PclButton(
                text: '切换账户',
                primary: false,
                height: 30,
                fontSize: 12.5,
                onTap: () => ref.read(pageIndexProvider.notifier).set(3),
              ),
              const SizedBox(width: 8),
              PclButton(
                text: '刷新令牌',
                primary: false,
                height: 30,
                fontSize: 12.5,
                onTap: () async {
                  try {
                    await ref.read(accountsProvider.notifier).refreshIfNeeded();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('账户令牌校验完成')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('令牌校验失败: $e'),
                          backgroundColor: kDanger,
                        ),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _host(String? server) {
    if (server == null || server.isEmpty) return '外置';
    return server
        .replaceFirst(RegExp('^https?://'), '')
        .split('/')
        .first;
  }
}

/// 未登录表单（按登录方式：离线 / 正版 / 外置）
class _LoginForm extends ConsumerWidget {
  final _AuthType authType;

  const _LoginForm({required this.authType});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (authType) {
      _AuthType.offline => const _OfflineForm(),
      _AuthType.microsoft => _MicrosoftForm(),
      _AuthType.yggdrasil => const _YggdrasilForm(),
    };
  }
}

class _OfflineForm extends ConsumerStatefulWidget {
  const _OfflineForm();

  @override
  ConsumerState<_OfflineForm> createState() => _OfflineFormState();
}

class _OfflineFormState extends ConsumerState<_OfflineForm> {
  final _nameC = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.person_pin_rounded, size: 46, color: kAccent),
          const SizedBox(height: 12),
          TextField(
            controller: _nameC,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              labelText: '玩家名',
              hintText: '离线模式 · 1-16 字符',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          PclButton(text: '登录离线账户', onTap: _submit),
        ],
      ),
    );
  }

  void _submit() {
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入玩家名')));
      return;
    }
    // 表单内已输入玩家名，直接创建，不再弹二次确认框
    _create(name);
  }

  Future<void> _create(String name) async {
    try {
      await ref.read(accountsProvider.notifier).addOffline(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加离线账户：$name')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: kDanger),
        );
      }
    }
  }
}

class _MicrosoftForm extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.verified_user_rounded, size: 46, color: kAccent),
          const SizedBox(height: 12),
          const Text(
            '使用微软账户登录 Minecraft Java 版',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          PclButton(
            text: '登录微软账户',
            icon: Icons.open_in_browser_rounded,
            onTap: () => microsoftLoginFlow(context, ref),
          ),
        ],
      ),
    );
  }
}

class _YggdrasilForm extends ConsumerStatefulWidget {
  const _YggdrasilForm();

  @override
  ConsumerState<_YggdrasilForm> createState() => _YggdrasilFormState();
}

class _YggdrasilFormState extends ConsumerState<_YggdrasilForm> {
  final _serverC = TextEditingController(text: 'https://littleskin.cn');
  final _userC = TextEditingController();
  final _passC = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.dns_rounded, size: 42, color: kAccent),
          const SizedBox(height: 10),
          TextField(
            controller: _serverC,
            decoration: const InputDecoration(
              labelText: '认证服务器',
              hintText: '如 https://littleskin.cn',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _userC,
            decoration: const InputDecoration(
              labelText: '邮箱 / 用户名',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passC,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : PclButton(text: '登录外置账户', onTap: _submit),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    Object? error;
    try {
      final session = await rust
          .yggdrasilLogin(
            serverUrl: _serverC.text.trim(),
            username: _userC.text.trim(),
            password: _passC.text,
          )
          .timeout(const Duration(seconds: 90));
      rust.YggdrasilProfile? profile;
      if (session.profiles.length == 1) {
        profile = session.profiles.first;
      } else if (mounted) {
        profile = await showDialog<rust.YggdrasilProfile>(
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
      }
      if (profile != null) {
        await rust.saveYggdrasilAccount(
          apiRoot: session.apiRoot,
          accessToken: session.accessToken,
          clientToken: session.clientToken,
          profileId: profile.id,
          profileName: profile.name,
        );
        await ref.read(accountsProvider.notifier).reload();
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('已添加外置账户：${profile.name}')),
          );
        }
        // 对齐 PCL：外置登录就绪后自动下载 authlib-injector
        if (mounted) {
          setState(() => _busy = false);
          await ensureAuthlibInjectorFlow(context);
          return;
        }
      }
    } catch (e) {
      error = e;
    }
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('外置登录失败: $error'),
          backgroundColor: kDanger,
        ),
      );
    }
    if (mounted) setState(() => _busy = false);
  }
}

// ---------------------------------------------------------------------------
// 大启动按钮（PCL2 BtnLaunch：Height 54 / Margin 20；版本名内嵌底部）
// ---------------------------------------------------------------------------
class _LaunchButton extends ConsumerStatefulWidget {
  final String selected;
  final int activeCount;

  const _LaunchButton({required this.selected, required this.activeCount});

  @override
  ConsumerState<_LaunchButton> createState() => _LaunchButtonState();
}

class _LaunchButtonState extends ConsumerState<_LaunchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hasVersion = widget.selected.isNotEmpty;
    final busy = widget.activeCount > 0;

    Future<void> doLaunch() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref
            .read(launchSessionsProvider.notifier)
            .launch(widget.selected);
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('启动失败: $e'),
            backgroundColor: kDanger,
          ),
        );
      }
    }

    void onTap() {
      if (!hasVersion) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('尚未安装版本，请先在「下载」页安装')),
        );
        ref.read(pageIndexProvider.notifier).set(1);
        return;
      }
      if (busy) return;
      doLaunch();
    }

    final grad = !hasVersion || busy
        ? [Colors.grey.shade400, Colors.grey.shade500]
        : _hover
        ? const [_launchGreenHover, _launchGreenDeep]
        : const [_launchGreen, _launchGreenDeep];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 54,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: grad,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: hasVersion && !busy
                  ? [
                      BoxShadow(
                        color: _launchGreen.withAlpha(_hover ? 96 : 60),
                        blurRadius: _hover ? 18 : 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                // 主文字（居中）
                Center(
                  child: Text(
                    busy
                        ? '游戏运行中（${widget.activeCount}）'
                        : hasVersion
                        ? '启动游戏'
                        : '没有已安装的版本',
                    style: const TextStyle(
                      fontSize: 17.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                // 版本名（PCL2 LabVersion：按钮内底部，11 号）
                Positioned(
                  left: 15,
                  right: 15,
                  bottom: 4,
                  child: Text(
                    hasVersion ? widget.selected : '点击前往「下载」安装版本',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withAlpha(_hover ? 235 : 200),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 启动日志卡（PCL2 PageLaunchRight 的启动日志 MyCard）+ 运行中会话
// ---------------------------------------------------------------------------
class _LaunchLogPanel extends ConsumerWidget {
  final List<LaunchSession> activeSessions;

  const _LaunchLogPanel({required this.activeSessions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(recentLogsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tail = logs.length > 60 ? logs.sublist(logs.length - 60) : logs;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 运行中的会话（PCL2 启动时顶部进度提示的替代）
          for (final s in activeSessions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PclPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _launchGreen,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Text(
                      s.versionId,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.message,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.white38
                              : Colors.black38,
                        ),
                      ),
                    ),
                    PclButton(
                      text: '终止',
                      danger: true,
                      height: 26,
                      fontSize: 12,
                      onTap: () => ref
                          .read(launchSessionsProvider.notifier)
                          .terminate(s.id),
                    ),
                  ],
                ),
              ),
            ),
          // 启动日志卡（PCL2 PanLog）
          Expanded(
            child: PclPanel(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                    child: Row(
                      children: [
                        const Text(
                          '启动日志',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        PclButton(
                          text: '查看全部',
                          primary: false,
                          height: 26,
                          fontSize: 12,
                          onTap: () =>
                              ref.read(pageIndexProvider.notifier).set(3),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 10),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                      itemCount: tail.length,
                      itemBuilder: (context, i) {
                        final e = tail[i];
                        final color = switch (e.level) {
                          'ERROR' => kDanger,
                          'WARN' => const Color(0xFFB26A00),
                          _ => isDark
                              ? Colors.white54
                              : Colors.black54,
                        };
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            e.message.isEmpty
                                ? '[${e.module}]'
                                : '[${e.module}] ${e.message}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: color,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 版本快速选择弹窗（PCL2 版本列表样式）
// ---------------------------------------------------------------------------
class _VersionSelectorDialog extends ConsumerWidget {
  const _VersionSelectorDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(localVersionsProvider);
    final selected = ref.watch(selectedVersionProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '选择版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  PclButton(
                    text: '安装新版本',
                    primary: false,
                    height: 30,
                    fontSize: 12.5,
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(pageIndexProvider.notifier).set(1);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: versions.when(
                  data: (list) => list.isEmpty
                      ? const EmptyView(text: '尚未安装任何版本')
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final v = list[i];
                            final isSelected = v.id == selected;
                            return Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? kAccent
                                      : Colors.transparent,
                                ),
                              ),
                              child: HoverTile(
                                onTap: () {
                                  ref
                                      .read(selectedVersionProvider.notifier)
                                      .select(v.id);
                                  Navigator.of(context).pop();
                                },
                                child: Row(
                                  children: [
                                    VersionIcon(loader: v.loader),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        v.id,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    PclTag(loaderLabel(v.loader)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyView(text: '加载失败: $e'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
