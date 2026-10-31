import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/error/app_exception.dart';
import '../../providers/install_task_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/version/local_version_manager.dart';

/// 导入版本（借鉴 HMCL「从磁盘安装版本」/ PCL 压缩包导入）：
/// 支持整个版本文件夹或版本 zip 压缩包。
///
/// 返回导入后的版本 id（取消返回 null）。
Future<String?> showImportVersionDialog(
    BuildContext context, WidgetRef ref) async {
  final choice = await showDialog<_ImportSource>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导入版本'),
      content: const Text(
          '从磁盘导入已有的 Minecraft 版本目录（PCL / HMCL / 官方启动器均可识别），'
          '导入后文件将复制到当前游戏目录的 versions 中。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(ctx, _ImportSource.folder),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('选择版本文件夹'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, _ImportSource.zip),
          icon: const Icon(Icons.folder_zip_rounded, size: 18),
          label: const Text('选择 zip 压缩包'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;

  String? path;
  if (choice == _ImportSource.folder) {
    path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择版本文件夹（内含 <版本>.json 与 <版本>.jar）',
    );
  } else {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择版本压缩包',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    path = result?.files.single.path;
  }
  if (path == null || !context.mounted) return null;

  // 名称确认
  final baseName =
      p.basename(path).replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
  final nameCtrl = TextEditingController(text: baseName);
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('版本名称'),
      content: TextField(
        controller: nameCtrl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '版本目录名',
          helperText: '将出现在版本列表与主页启动选择中',
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('导入')),
      ],
    ),
  );
  if (newName == null || !context.mounted) return null;

  final task = ref.read(installTaskProvider.notifier);
  task.begin('导入版本 $newName');
  try {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final String? versionId;
    if (choice == _ImportSource.folder) {
      versionId = await LocalVersionManager.I.importFromFolder(gameDir, path,
          newName: newName, onProgress: task.update);
    } else {
      versionId = await LocalVersionManager.I.importFromZip(gameDir, path,
          newName: newName, onProgress: task.update);
    }
    task.end();
    if (!context.mounted) return versionId;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('版本「$versionId」导入完成')));
    return versionId;
  } catch (e) {
    task.end(failed: true);
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('导入失败: ${e is AppException ? e.userMessage : e}'),
      backgroundColor: Theme.of(context).colorScheme.error,
    ));
    return null;
  } finally {
    Future.delayed(const Duration(seconds: 3), () {
      ref.read(installTaskProvider.notifier).clear();
    });
  }
}

enum _ImportSource { folder, zip }
