/// 更多页 —— 对齐 PCL2「更多」页结构（PageOther）：
/// 子页签：账户 / 日志 / 关于。
/// - 账户：多账户管理（离线 / 微软 / 外置），登录流程与启动页共用
/// - 日志：实时日志 + 日志文件浏览（完整日志位于 exe\FMCL\logs\）
/// - 关于：版本信息、开源地址、打开游戏文件夹
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';
import 'account_manage_page.dart';
import 'logs_page.dart';

class MorePage extends ConsumerStatefulWidget {
  const MorePage({super.key});

  @override
  ConsumerState<MorePage> createState() => _MorePageState();
}

class _MorePageState extends ConsumerState<MorePage> {
  int _tab = 0;

  static const _tabs = ['账户', '日志', '关于'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: Segmented(
            items: _tabs,
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
        ),
        Expanded(
          child: switch (_tab) {
            0 => const _AccountEntryTab(),
            1 => const LogsPage(),
            _ => const _AboutTab(),
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 账户管理入口（完整管理页为独立全屏页，参照项目 AccountPage 布局）
// ---------------------------------------------------------------------------
class _AccountEntryTab extends ConsumerWidget {
  const _AccountEntryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final cur = accounts.current;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subText = isDark ? Colors.white38 : Colors.black38;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PclPanel(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.account_circle_rounded,
                        size: 40,
                        color: kAccent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cur?.name ?? '尚未登录',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              cur == null
                                  ? '启动前需要先登录离线 / 微软 / 外置账户'
                                  : switch (cur.accountType) {
                                      'microsoft' => '微软正版登录',
                                      'yggdrasil' =>
                                        '外置登录 · ${cur.yggdrasilServer ?? ""}',
                                      _ => '离线模式',
                                    },
                              style: TextStyle(fontSize: 12.5, color: subText),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      PclTag('共 ${accounts.accounts.length} 个账户'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  PclButton(
                    text: '打开账户管理',
                    icon: Icons.manage_accounts_rounded,
                    onTap: () => Navigator.of(context)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AccountManagePage(),
                          ),
                        )
                        .then((_) {
                          ref.read(accountsProvider.notifier).reload();
                        }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 关于（PCL2 关于卡风格）
// ---------------------------------------------------------------------------
class _AboutTab extends ConsumerWidget {
  const _AboutTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider).value;
    final gameDir = ref.watch(gameDirProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      children: [
        PclPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/img/hmcl/grass.png',
                      width: 46,
                      height: 46,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'FMCL',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Fluent Minecraft Launcher ${info?.appVersion ?? ''}',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white38
                              : Colors.black38,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  PclTag('架构：Rust 核心 + Flutter 界面'),
                ],
              ),
              const SizedBox(height: 12),
              _aboutLine(context, 'FMCL 根目录', info?.fmclRoot ?? '-'),
              _aboutLine(context, '游戏目录', gameDir),
              _aboutLine(context, 'authlib-injector', info?.authlibInjectorDir ?? '-'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        PclPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '开源与致谢',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              _aboutLine(context, '项目地址', 'github.com/Ming-QWQ520/FMCL'),
              _aboutLine(
                context,
                '交互与界面',
                '对齐 Plain Craft Launcher 2（Meloong-Git/PCL）',
              ),
              _aboutLine(context, '图标资产', 'HMCL 图片资源（img.zip）'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PclButton(
                    text: '打开游戏文件夹',
                    icon: Icons.folder_open_rounded,
                    primary: false,
                    onTap: () async {
                      try {
                        await rust.openPath(path: gameDir);
                      } catch (_) {}
                    },
                  ),
                  PclButton(
                    text: '打开日志文件夹',
                    icon: Icons.article_outlined,
                    primary: false,
                    onTap: () async {
                      try {
                        await rust.openPath(path: info?.logsDir ?? '');
                      } catch (_) {}
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _aboutLine(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white54
                    : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
