import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../ui/accounts/accounts_page.dart';
import '../../ui/download/download_page.dart';
import '../../ui/error/crash_report_page.dart';
import '../../ui/home/home_page.dart';
import '../../ui/logs/logs_page.dart';
import '../../ui/mods/mods_page.dart';
import '../../ui/settings/settings_page.dart';
import '../../ui/versions/versions_page.dart';
import '../../ui/shell/app_shell.dart';

/// 路由路径常量
class AppRoutes {
  AppRoutes._();

  static const String home = '/';
  static const String download = '/download';
  static const String versions = '/versions';
  static const String mods = '/mods';
  static const String accounts = '/accounts';
  static const String settings = '/settings';
  static const String logs = '/logs';
  static const String crashReport = '/crash-report';
}

/// 全局导航 key
final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

final appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: AppRoutes.home,
  routes: [
    // 带侧边栏的主框架
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const HomePage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.download,
            builder: (context, state) => const DownloadPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.versions,
            builder: (context, state) => const VersionsPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.mods,
            builder: (context, state) => const ModsPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.accounts,
            builder: (context, state) => const AccountsPage(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsPage(),
          ),
        ]),
      ],
    ),
    // 全屏错误报告页
    GoRoute(
      path: AppRoutes.crashReport,
      builder: (context, state) => const CrashReportPage(),
    ),
    // 全屏日志查看器
    GoRoute(
      path: AppRoutes.logs,
      builder: (context, state) => const LogsPage(),
    ),
  ],
  errorBuilder: (context, state) => const HomePage(),
);
