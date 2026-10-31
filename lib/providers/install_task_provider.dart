import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/install/installer_base.dart';

/// 全局安装任务状态（PCL2 式：底部固定进度条 + 任务描述）。
///
/// 任何安装（原版 / 加载器 / 整合包 / 版本修复）都通过 [InstallTaskNotifier]
/// 汇报进度，主页与下载页均可实时展示。
class InstallTaskState {
  /// 是否有正在进行的任务
  final bool active;

  /// 任务标题（如「安装原版 1.20.1」）
  final String title;

  /// 当前阶段消息
  final String message;

  /// 进度 0~1（null = 不确定）
  final double? progress;

  /// 当前阶段（resolve/download/process/extract/...）
  final String phase;

  /// 任务是否以失败结束（用于 UI 短暂标红）
  final bool failed;

  const InstallTaskState({
    this.active = false,
    this.title = '',
    this.message = '',
    this.progress,
    this.phase = '',
    this.failed = false,
  });

  InstallTaskState copyWith({
    bool? active,
    String? title,
    String? message,
    double? progress,
    String? phase,
    bool? failed,
  }) {
    return InstallTaskState(
      active: active ?? this.active,
      title: title ?? this.title,
      message: message ?? this.message,
      progress: progress ?? this.progress,
      phase: phase ?? this.phase,
      failed: failed ?? this.failed,
    );
  }
}

final installTaskProvider =
    NotifierProvider<InstallTaskNotifier, InstallTaskState>(
  InstallTaskNotifier.new,
);

class InstallTaskNotifier extends Notifier<InstallTaskState> {
  @override
  InstallTaskState build() => const InstallTaskState();

  /// 开始一个任务（并发时后一个覆盖前一个的展示，引擎本身串行排队）
  void begin(String title) {
    state = InstallTaskState(
      active: true,
      title: title,
      message: '准备中...',
      phase: 'resolve',
    );
  }

  /// 汇报进度
  void update(InstallProgress p) {
    if (!state.active) return;
    state = state.copyWith(
      message: p.message,
      progress: p.progress,
      phase: p.phase,
      failed: p.phase == 'failed',
    );
  }

  /// 结束任务（成功或失败后短暂保留失败态，由 UI 处理清理）
  void end({bool failed = false}) {
    state = InstallTaskState(
      active: false,
      title: state.title,
      message: failed ? '任务失败' : '任务完成',
      progress: failed ? state.progress : 1.0,
      phase: failed ? 'failed' : 'done',
      failed: failed,
    );
  }

  /// 清空（UI 在 snack 提示后调用）
  void clear() {
    state = const InstallTaskState();
  }
}
