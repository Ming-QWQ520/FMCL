/// 下载详情页 —— 100% 借鉴参照项目 DownloadDetailPage 布局：
///
/// - 顶部标题栏：返回 + 「下载详情」
/// - 左栏（宽 260）：总进度（进度条 + 百分比）、下载速度（大字）、
///   剩余文件列表（随完成逐个移除，首个带加载圈）
/// - 右栏：步骤列表（✓ 完成 / spinner 当前 / ○ 等待，参考同款配色逻辑）
/// - 完成 → 800ms 后自动返回并刷新本地版本；失败 → 保留页面 + 错误 + 重试
///
/// 数据全部来自 Rust 安装管线事件（installTaskProvider 聚合），
/// Flutter 仅渲染与通信。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class DownloadDetailPage extends ConsumerStatefulWidget {
  final VoidCallback? onRetry;

  const DownloadDetailPage({super.key, this.onRetry});

  @override
  ConsumerState<DownloadDetailPage> createState() =>
      _DownloadDetailPageState();
}

class _DownloadDetailPageState extends ConsumerState<DownloadDetailPage> {
  bool _autoClosed = false;

  @override
  void initState() {
    super.initState();
    _checkFinished(ref.read(installTaskProvider));
  }

  void _checkFinished(InstallTaskState task) {
    // 完成 → 短暂停留后自动返回（对齐参照项目行为）
    if (!_autoClosed &&
        !task.running &&
        task.error == null &&
        task.phase == 'done') {
      _autoClosed = true;
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  String _speedLabel(int speedBps) {
    if (speedBps <= 0) return '计算中...';
    final mb = speedBps / 1024 / 1024;
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
    return '${(speedBps / 1024).toStringAsFixed(0)} KB/s';
  }

  String _bytesLabel(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(installTaskProvider);
    _checkFinished(task);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subText = isDark ? Colors.white38 : Colors.black38;
    final done = !task.running && task.error == null && task.phase == 'done';

    return Scaffold(
      backgroundColor: isDark ? kDarkBg : kLightBg,
      body: Column(
        children: [
          // ---------- 标题栏（PCL2 二级页：返回 + 标题） ----------
          Container(
            height: 48,
            color: kAccent,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _BarButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: '返回',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.title.isEmpty ? '下载详情' : task.title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (done)
                  const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Icon(
                      Icons.check_circle_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ==================== 左栏：总进度 / 速度 / 剩余文件 ====================
                Container(
                  width: 264,
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('总进度', style: TextStyle(fontSize: 13, color: subText)),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: task.phase == 'done'
                                    ? 1.0
                                    : task.progress <= 0
                                    ? null
                                    : task.progress,
                                minHeight: 8,
                                backgroundColor: isDark
                                    ? Colors.white.withAlpha(20)
                                    : Colors.black.withAlpha(14),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  task.error != null ? kDanger : kAccent,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(
                                  task.error != null
                                      ? '失败'
                                      : '${(task.progress * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: task.error != null
                                        ? kDanger
                                        : kAccent,
                                  ),
                                ),
                                const Spacer(),
                                if (task.bytesTotal > 0)
                                  Text(
                                    '${_bytesLabel(task.bytesDone)} / ${_bytesLabel(task.bytesTotal)}',
                                    style: TextStyle(fontSize: 11, color: subText),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text('下载速度', style: TextStyle(fontSize: 13, color: subText)),
                            const SizedBox(height: 4),
                            Text(
                              done ? '完成' : _speedLabel(task.speedBps),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF1F2328),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? Colors.white.withAlpha(16)
                            : Colors.black.withAlpha(16),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: Text('剩余文件', style: TextStyle(fontSize: 12.5, color: subText)),
                      ),
                      Expanded(
                        child: task.remaining.isEmpty
                            ? Center(
                                child: Text(
                                  task.running ? '暂无等待文件' : '队列为空',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: subText,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                itemCount: task.remaining.length,
                                itemBuilder: (context, index) {
                                  final record = task.remaining[index];
                                  return ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    leading: index == 0 && task.running
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: kAccent,
                                            ),
                                          )
                                        : Icon(
                                            Icons.hourglass_empty_rounded,
                                            size: 16,
                                            color: subText,
                                          ),
                                    title: Text(
                                      record,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: index == 0 && task.running
                                            ? (isDark
                                                  ? Colors.white70
                                                  : Colors.black87)
                                            : subText,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                // ==================== 右栏：步骤列表 ====================
                Expanded(
                  child: task.error != null
                      ? _ErrorRetryView(
                          error: task.error!,
                          onRetry: widget.onRetry,
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: task.steps.length,
                          itemBuilder: (context, index) {
                            final isCurrent = index == task.steps.length - 1;
                            final isCompleted = index < task.steps.length - 1;
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 300),
                              opacity: isCompleted || isCurrent ? 1.0 : 0.5,
                              child: ListTile(
                                dense: true,
                                leading: isCurrent && task.running
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: kAccent,
                                        ),
                                      )
                                    : Icon(
                                        isCompleted
                                            ? Icons.check_circle_rounded
                                            : (isCurrent && done
                                                  ? Icons.check_circle_rounded
                                                  : Icons
                                                        .radio_button_unchecked_rounded),
                                        color: isCompleted || (isCurrent && done)
                                            ? kAccent
                                            : subText,
                                        size: 22,
                                      ),
                                title: Text(
                                  task.steps[index],
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    color: isCompleted
                                        ? kAccent
                                        : isCurrent
                                        ? (isDark
                                              ? Colors.white
                                              : Colors.black87)
                                        : subText,
                                    fontWeight: isCurrent
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 标题栏圆形按钮（PCL2 MyIconButton：CornerRadius 1000，hover 白 α50）
class _BarButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
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

/// 失败重试视图（对齐参照项目：错误 + 重试按钮）
class _ErrorRetryView extends StatelessWidget {
  final String error;
  final VoidCallback? onRetry;

  const _ErrorRetryView({required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: PclPanel(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: kDanger),
                  SizedBox(width: 10),
                  Text(
                    '任务失败',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                error,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white70
                      : Colors.black87,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PclButton(
                    text: '返回',
                    primary: false,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  if (onRetry != null)
                    PclButton(text: '重试', icon: Icons.refresh_rounded, onTap: onRetry!),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
