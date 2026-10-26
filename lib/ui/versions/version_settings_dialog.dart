import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';
import '../../services/version/version_settings.dart';

/// 版本设置对话框（PCL2「版本设置」式：全局继承 + 局部覆盖）。
///
/// 覆盖项：版本隔离 / Java 路径 / 内存 / JVM 参数。
class VersionSettingsDialog extends ConsumerStatefulWidget {
  final String versionId;

  const VersionSettingsDialog({super.key, required this.versionId});

  @override
  ConsumerState<VersionSettingsDialog> createState() =>
      _VersionSettingsDialogState();
}

class _VersionSettingsDialogState extends ConsumerState<VersionSettingsDialog> {
  late bool _isolationOverride;
  late bool? _isolationValue;
  late TextEditingController _javaCtrl;
  late TextEditingController _jvmCtrl;
  late TextEditingController _maxMemCtrl;
  late TextEditingController _minMemCtrl;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _javaCtrl = TextEditingController();
    _jvmCtrl = TextEditingController();
    _maxMemCtrl = TextEditingController();
    _minMemCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final s = await VersionSettingsService.I.load(gameDir, widget.versionId);
    if (!mounted) return;
    setState(() {
      _isolationOverride = s.isolation != null;
      _isolationValue = s.isolation ??
          ref.read(appSettingsProvider).versionIsolation;
      _javaCtrl.text = s.javaPath ?? '';
      _jvmCtrl.text = s.jvmArguments ?? '';
      _maxMemCtrl.text = (s.maxMemoryMb ?? 0) > 0 ? '${s.maxMemoryMb}' : '';
      _minMemCtrl.text = (s.minMemoryMb ?? 0) > 0 ? '${s.minMemoryMb}' : '';
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final gameDir = ref.read(appSettingsProvider).gameDirectory;
    final s = VersionSettings(
      isolation: _isolationOverride ? _isolationValue : null,
      javaPath: _javaCtrl.text.trim(),
      maxMemoryMb: int.tryParse(_maxMemCtrl.text.trim()) ?? 0,
      minMemoryMb: int.tryParse(_minMemCtrl.text.trim()) ?? 0,
      jvmArguments: _jvmCtrl.text.trim(),
    );
    await VersionSettingsService.I.save(gameDir, widget.versionId, s);
  }

  @override
  void dispose() {
    _javaCtrl.dispose();
    _jvmCtrl.dispose();
    _maxMemCtrl.dispose();
    _minMemCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final global = ref.watch(appSettingsProvider);
    return AlertDialog(
      title: Text('版本设置 · ${widget.versionId}'),
      content: SizedBox(
        width: 520,
        child: !_loaded
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle('版本隔离'),
                    Row(
                      children: [
                        Switch(
                          value: _isolationOverride,
                          onChanged: (v) =>
                              setState(() => _isolationOverride = v),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _isolationOverride
                                ? '使用本版本独立设置'
                                : '跟随全局（当前${global.versionIsolation ? "：开启" : "：关闭"}）',
                            style: const TextStyle(fontSize: 13.5),
                          ),
                        ),
                        if (_isolationOverride)
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('开启')),
                              ButtonSegment(value: false, label: Text('关闭')),
                            ],
                            selected: {_isolationValue ?? true},
                            onSelectionChanged: (v) =>
                                setState(() => _isolationValue = v.first),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 10),
                      child: Text(
                        '开启后该版本拥有独立的 saves / options.txt / mods 等目录，'
                        '与其他版本完全隔离；libraries 与 assets 仍共享。',
                        style: context.captionStyle,
                      ),
                    ),
                    _sectionTitle('Java 覆盖（留空跟随全局）'),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _javaCtrl,
                            decoration: const InputDecoration(
                              hintText: 'java 可执行文件绝对路径',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(
                              dialogTitle: '选择 java 可执行文件',
                            );
                            if (result != null) {
                              _javaCtrl.text =
                                  result.files.single.path ?? '';
                              setState(() {});
                            }
                          },
                          child: const Text('浏览'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _sectionTitle('内存覆盖（MB，留空跟随全局）'),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _minMemCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '最小内存',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _maxMemCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '最大内存',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _sectionTitle('额外 JVM 参数（叠加在全局之后）'),
                    TextField(
                      controller: _jvmCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: '如 -XX:+UseZGC',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await _save();
            if (context.mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('保存'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 打开版本设置的便捷函数
Future<void> showVersionSettings(BuildContext context, String versionId) {
  return showDialog(
    context: context,
    builder: (_) => VersionSettingsDialog(versionId: versionId),
  );
}
