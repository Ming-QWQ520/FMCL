/// 安装/补全任务进度弹窗（PCL2 风格进度卡）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class InstallTaskDialog extends ConsumerWidget {
  const InstallTaskDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(installTaskProvider);
    final finished = !task.running;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    task.error != null
                        ? Icons.error_outline_rounded
                        : finished && task.phase == 'done'
                        ? Icons.check_circle_outline_rounded
                        : Icons.downloading_rounded,
                    size: 22,
                    color: task.error != null
                        ? kDanger
                        : finished && task.phase == 'done'
                        ? Colors.green
                        : kAccent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      task.title.isEmpty ? '任务进行中' : task.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              PclProgress(
                value: task.phase == 'done'
                    ? 1.0
                    : (task.error != null ? 0 : task.progress),
              ),
              const SizedBox(height: 10),
              Text(
                task.error ?? task.message,
                style: TextStyle(
                  fontSize: 12.5,
                  color: task.error != null
                      ? kDanger
                      : Theme.of(context).brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black45,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (task.running)
                    PclButton(
                      text: '后台运行',
                      primary: false,
                      onTap: () => Navigator.of(context).pop(),
                    )
                  else
                    PclButton(
                      text: task.error != null ? '关闭' : '完成',
                      onTap: () {
                        ref.read(installTaskProvider.notifier).reset();
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
