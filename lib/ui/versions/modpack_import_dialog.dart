import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/logger/app_logger.dart';
import '../../services/modpack/modpack_service.dart';

/// 整合包导入流程（PCL2 式一键安装 Modrinth .mrpack）。
///
/// 选择文件 → 解析展示 → 确认安装 → 进度条 → 完成提示。
///
/// [initialFilePath] 拖拽导入时直接传入的 .mrpack/.zip 路径（跳过文件选择）。
Future<void> showModpackImport(
  BuildContext context, {
  String? initialFilePath,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ModpackImportDialog(initialFilePath: initialFilePath),
  );
}

class _ModpackImportDialog extends ConsumerStatefulWidget {
  const _ModpackImportDialog({this.initialFilePath});

  /// 拖拽 / 外部传入的整合包路径
  final String? initialFilePath;

  @override
  ConsumerState<_ModpackImportDialog> createState() =>
      _ModpackImportDialogState();
}

enum _Stage { pick, confirm, installing, done, failed }

class _ModpackImportDialogState extends ConsumerState<_ModpackImportDialog> {
  _Stage _stage = _Stage.pick;
  ModrinthIndex? _index;
  String? _mrpackPath;
  String _progressText = '';
  double? _progress;
  String? _resultId;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFilePath;
    if (initial != null && initial.isNotEmpty) {
      Future.microtask(() => _loadFile(initial));
    }
  }

  /// 解析并载入一个整合包文件（文件选择与拖拽共用）
  Future<void> _loadFile(String path) async {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.mrpack') && !lower.endsWith('.zip')) {
      setState(() {
        _error = '请拖入 .mrpack / .zip 格式的 Modrinth 整合包';
      });
      return;
    }
    try {
      final index = ModpackService.parseMrpack(path);
      setState(() {
        _mrpackPath = path;
        _index = index;
        _stage = _Stage.confirm;
        _error = null;
      });
    } on AppException catch (e) {
      setState(() {
        _error = e.userMessage;
      });
    } catch (e) {
      setState(() {
        _error = '解析失败: $e';
      });
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Modrinth 整合包（.mrpack）',
      type: FileType.custom,
      allowedExtensions: ['mrpack', 'zip'],
    );
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _loadFile(path);
  }

  Future<void> _startInstall() async {
    setState(() => _stage = _Stage.installing);
    try {
      final service = ref.read(modpackServiceProvider);
      final id = await service.install(
        mrpackPath: _mrpackPath!,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progressText = p.message;
            _progress = p.progress;
          });
        },
      );
      AppLogger.info('Modpack', '整合包安装完成: $id');
      if (!mounted) return;
      setState(() {
        _resultId = id;
        _stage = _Stage.done;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _stage = _Stage.failed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '安装失败: $e';
        _stage = _Stage.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.inventory_2_rounded, size: 22),
          SizedBox(width: 8),
          Text('导入整合包'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: switch (_stage) {
          _Stage.pick => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '支持 Modrinth 规范的 .mrpack 整合包。\n'
                  '将自动完成：基础游戏与加载器安装 → 整合包文件下载 → 配置释放。',
                  style: TextStyle(fontSize: 13.5, height: 1.6),
                ),
                const SizedBox(height: 16),
                Center(
                  child: FilledButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const Text('选择 .mrpack 文件'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],
              ],
            ),
          _Stage.confirm => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('整合包名称', _index?.name ?? '-'),
                _infoRow('版本', _index?.versionId ?? '-'),
                _infoRow('游戏版本', _index?.gameVersion ?? '-'),
                _infoRow('加载器', _index?.loaderLabel ?? '-'),
                _infoRow('包含文件', '${_index?.files.length ?? 0} 个'),
                if ((_index?.summary ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_index!.summary,
                      style: const TextStyle(
                          fontSize: 13, fontStyle: FontStyle.italic)),
                ],
                const SizedBox(height: 12),
                Text(
                  '文件较多时安装耗时较长，过程中请保持网络畅通。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          _Stage.installing => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_progressText,
                    style: const TextStyle(fontSize: 13.5)),
                const SizedBox(height: 14),
                if (_progress != null)
                  LinearProgressIndicator(
                      value: _progress!.clamp(0.0, 1.0))
                else
                  const LinearProgressIndicator(),
                const SizedBox(height: 10),
                Text('正在安装，请勿关闭窗口…',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          _Stage.done => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF16A34A), size: 48),
                const SizedBox(height: 10),
                const Text('整合包安装完成！',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('版本 id：$_resultId',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          _Stage.failed => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_rounded,
                    color: Color(0xFFE5534B), size: 44),
                const SizedBox(height: 10),
                Text(_error ?? '未知错误',
                    style: const TextStyle(fontSize: 13.5)),
              ],
            ),
        },
      ),
      actions: switch (_stage) {
        _Stage.pick => [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        _Stage.confirm => [
            TextButton(
              onPressed: () => setState(() => _stage = _Stage.pick),
              child: const Text('返回'),
            ),
            FilledButton.icon(
              onPressed: _startInstall,
              icon: const Icon(Icons.rocket_launch_rounded, size: 18),
              label: const Text('开始安装'),
            ),
          ],
        _Stage.installing => [],
        _Stage.done => [
            FilledButton(
              onPressed: () => Navigator.pop(context, _resultId),
              child: const Text('完成'),
            ),
          ],
        _Stage.failed => [
            TextButton(
              onPressed: () => setState(() {
                _stage = _Stage.pick;
                _error = null;
              }),
              child: const Text('重试'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
      },
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 92,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
