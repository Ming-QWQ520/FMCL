/// 账户页（更多 → 账户 子页签）：多账户列表与管理。
/// 登录流程（离线 / 微软设备码 / 外置 authlib-injector）与启动页共用
/// `login_dialogs.dart`（含 90s 兜底超时与 authlib-injector 自动下载）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../dialogs/login_dialogs.dart';
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
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
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
                onTap: () => addOfflineFlow(context, ref),
              ),
              const SizedBox(width: 10),
              PclButton(
                text: '登录微软账户',
                icon: Icons.verified_user_outlined,
                onTap: () => microsoftLoginFlow(context, ref),
              ),
              const SizedBox(width: 10),
              PclButton(
                text: '添加外置账户',
                primary: false,
                icon: Icons.dns_rounded,
                onTap: () => yggdrasilLoginFlow(context, ref),
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
}
