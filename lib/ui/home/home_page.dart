
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/app_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/game_account.dart';
import '../../providers/account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/launch/launch_service.dart';
import '../../services/version/local_version_manager.dart';
import '../../widgets/common.dart';
import '../shell/custom_title_bar.dart';

/// 启动页（主页）：版本选择 + 大启动按钮 + 运行状态与日志。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  List<LocalVersion> _versions = [];
  String? _selectedVersion;
  bool _loadingVersions = true;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final versions = await LocalVersionManager.I.listVersions(gameDir);
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _loadingVersions = false;
      // 默认选中上次使用的版本
      final last = ref.read(appSettingsProvider).lastVersionId;
      if (_versions.any((v) => v.id == last)) {
        _selectedVersion = last;
      } else {
        _selectedVersion = _versions.firstOrNull?.id;
      }
    });
  }

  Future<void> _launch() async {
    final versionId = _selectedVersion;
    if (versionId == null) {
      _snack('请先在「下载」页安装一个版本', error: true);
      return;
    }
    // 记住选择
    ref.read(appSettingsProvider.notifier).patch(
          (s) => s.copyWith(lastVersionId: versionId),
        );
    try {
      await ref.read(launchServiceProvider).launch(versionId);
    } on AppException catch (e) {
      if (e is CancelledException) return;
      _snack(e.userMessage, error: true);
    } catch (e) {
      _snack('启动失败: $e', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final launchState = ref.watch(launchStateProvider);
    final sessions = ref.watch(launchSessionsProvider);
    final account = ref.watch(currentAccountProvider);

    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Expanded(
            child: _loadingVersions
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ---------- 顶部问候 ----------
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _greeting(),
                                style: context.titleStyle,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _loadVersions,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('刷新'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // ---------- 版本选择卡 ----------
                        AppCard(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withAlpha(30),
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.radiusM),
                                ),
                                child: Icon(
                                  Icons.sports_esports_rounded,
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '选择游戏版本',
                                      style: context.captionStyle,
                                    ),
                                    const SizedBox(height: 4),
                                    DropdownButton<String>(
                                      value: _selectedVersion,
                                      isExpanded: true,
                                      underline: const SizedBox.shrink(),
                                      hint: Text(
                                        _versions.isEmpty
                                            ? '尚未安装任何版本'
                                            : '请选择',
                                        style: TextStyle(
                                            fontSize: 16,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withAlpha(120)),
                                      ),
                                      items: _versions
                                          .map((v) => DropdownMenuItem(
                                                value: v.id,
                                                child: _VersionDropdownItem(
                                                  version: v,
                                                ),
                                              ))
                                          .toList(),
                                      onChanged: (v) =>
                                          setState(() => _selectedVersion = v),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              TextButton(
                                onPressed: () => context.go(AppRoutes.versions),
                                child: const Text('管理'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // ---------- 启动按钮（支持多实例并发） ----------
                        _LaunchButton(
                          versionId: _selectedVersion,
                          account: account,
                          state: launchState,
                          onPressed:
                              _selectedVersion == null ? null : _launch,
                        ),
                        const SizedBox(height: 20),

                        // ---------- 多实例运行栏 ----------
                        if (sessions.any((s) => s.isActive))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _RunningGamesBar(sessions: sessions),
                          ),

                        // ---------- 状态区 ----------
                        Expanded(
                          child: _StatusPanel(state: launchState),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了，来一局？';
    if (hour < 12) return '早上好，冒险者';
    if (hour < 14) return '中午好，冒险者';
    if (hour < 18) return '下午好，冒险者';
    return '晚上好，冒险者';
  }
}

/// 版本下拉项
class _VersionDropdownItem extends StatelessWidget {
  final LocalVersion version;

  const _VersionDropdownItem({required this.version});

  @override
  Widget build(BuildContext context) {
    final (loader, gameVer) = version.loaderInfo;
    final loaderLabel = switch (loader) {
      'vanilla' => '原版',
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'neoforge' => 'NeoForge',
      'quilt' => 'Quilt',
      _ => loader,
    };
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withAlpha(26),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            loaderLabel,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          version.id,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        if (gameVer != null && gameVer != version.id) ...[
          const SizedBox(width: 8),
          Text(
            gameVer,
            style: context.captionStyle,
          ),
        ],
      ],
    );
  }
}

/// 大启动按钮（PCL2 式 + 渐变 + 运行中动效）
class _LaunchButton extends StatelessWidget {
  final String? versionId;
  final GameAccount? account;
  final LaunchState state;
  final VoidCallback? onPressed;

  const _LaunchButton({
    required this.versionId,
    required this.account,
    required this.state,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final busy = state.isRunning;
    final disabled = versionId == null || onPressed == null;

    return SizedBox(
      height: 88,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusXL),
          gradient: disabled
              ? LinearGradient(colors: [
                  Colors.grey.shade500,
                  Colors.grey.shade600,
                ])
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.brandPrimaryLight,
                    AppTheme.brandPrimary,
                    AppTheme.brandPrimaryDark,
                  ],
                ),
          boxShadow: disabled
              ? []
              : [
                  BoxShadow(
                    color: AppTheme.brandPrimary.withAlpha(80),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppTheme.radiusXL),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusXL),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: busy
                        ? const SizedBox(
                            key: ValueKey('spin'),
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          )
                        : const Icon(
                            Icons.rocket_launch_rounded,
                            key: ValueKey('rocket'),
                            color: Colors.white,
                            size: 40,
                          ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          busy ? '正在启动…' : '启 动',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          state.isRunning
                              ? state.message
                              : (versionId ?? '未选择版本'),
                          style: TextStyle(
                            color: Colors.white.withAlpha(210),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (!busy && account == null)
                    Text(
                      '未登录账户',
                      style: TextStyle(
                        color: Colors.orange.shade100,
                        fontSize: 12.5,
                      ),
                    ),
                  if (busy)
                    TextButton(
                      onPressed: () {
                        // TODO: 取消启动
                      },
                      child: const Text('取消',
                          style: TextStyle(color: Colors.white70)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 多实例运行栏：展示所有活跃会话，可单独终止
class _RunningGamesBar extends ConsumerWidget {
  final List<LaunchSession> sessions;

  const _RunningGamesBar({required this.sessions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = sessions.where((s) => s.isActive).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dynamic_feed_rounded,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(140)),
              const SizedBox(width: 8),
              Text('运行中的实例 (${active.length})',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          ...active.map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: s.state.phase == LaunchPhase.running
                            ? null
                            : (s.state.progress ?? 0),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '#${s.id}  ${s.state.versionId ?? '?'} · ${s.state.message}',
                        style: const TextStyle(fontSize: 12.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '终止该实例',
                      icon: const Icon(Icons.stop_circle_outlined, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => ref
                          .read(launchServiceProvider)
                          .terminateSession(s.id),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

/// 状态面板：启动进度 / 日志 / 崩溃报告入口
class _StatusPanel extends ConsumerWidget {
  final LaunchState state;

  const _StatusPanel({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.phase == LaunchPhase.idle) {
      return AppCard(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.terminal_rounded,
                  size: 42,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(60)),
              const SizedBox(height: 12),
              Text(
                '点击上方按钮启动游戏',
                style: context.captionStyle,
              ),
              const SizedBox(height: 4),
              Text(
                '启动日志将在此处实时展示',
                style: context.captionStyle,
              ),
            ],
          ),
        ),
      );
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题行
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                if (state.phase == LaunchPhase.downloading &&
                    state.progress != null)
                  SizedBox(
                    width: 90,
                    child: LinearProgressIndicator(value: state.progress),
                  )
                else
                  Icon(
                    state.isRunning
                        ? Icons.check_circle_outline_rounded
                        : state.phase == LaunchPhase.failed
                            ? Icons.error_outline_rounded
                            : Icons.info_outline_rounded,
                    size: 18,
                    color: state.phase == LaunchPhase.failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.message,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (state.crashReport != null)
                  FilledButton.tonal(
                    onPressed: () => context.go(AppRoutes.crashReport),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('查看错误报告', style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
          ),
          Divider(
              height: 1,
              color: Theme.of(context).dividerTheme.color),
          // 日志区
          Expanded(
            child: Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF141619)
                  : const Color(0xFF1E2228),
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: state.recentLogs.length,
                itemBuilder: (context, i) {
                  final line = state.recentLogs[i];
                  final color = line.contains('ERROR') ||
                          line.contains('Exception') ||
                          line.contains('FATAL')
                      ? const Color(0xFFFF7B8B)
                      : line.contains('WARN')
                          ? const Color(0xFFFFC46B)
                          : Colors.white70;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 0.5),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: color,
                        height: 1.35,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
