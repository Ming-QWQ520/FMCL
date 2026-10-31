/// 版本设置弹窗（PCL2：隔离 / Java / 内存 / JVM 参数，缺省跟随全局）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../state/app_providers.dart';
import '../theme/pcl_theme.dart';
import '../widgets/common.dart';

class VersionSettingsDialog extends ConsumerStatefulWidget {
  final String versionId;

  const VersionSettingsDialog({super.key, required this.versionId});

  @override
  ConsumerState<VersionSettingsDialog> createState() =>
      _VersionSettingsDialogState();
}

class _VersionSettingsDialogState extends ConsumerState<VersionSettingsDialog> {
  rust.VersionSettingsData? _data;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await ref.read(versionOpsProvider).settings(widget.versionId);
    if (mounted) setState(() => _data = data);
  }

  Future<void> _save() async {
    if (_data == null) return;
    setState(() => _saving = true);
    await ref.read(versionOpsProvider).saveSettings(widget.versionId, _data!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final d = _data;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: d == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('版本设置 · ${widget.versionId}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      '未修改的项将跟随全局设置（当前全局内存 ${settings.minMemoryMb}-${settings.maxMemoryMb} MiB）',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white38
                              : Colors.black38),
                    ),
                    const Divider(height: 20),
                    Expanded(
                      child: ListView(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('版本隔离',
                                style: TextStyle(fontSize: 14)),
                            subtitle: Text(
                              '开启后 saves/config/mods 等存放在该版本目录内（跟随全局: ${settings.versionIsolation ? "开" : "关"}）',
                              style: const TextStyle(fontSize: 12),
                            ),
                            value: d.isolation ?? settings.versionIsolation,
                            onChanged: (v) => setState(() =>
                                _data = rust.VersionSettingsData(
                                  isolation: v,
                                  javaPath: d.javaPath,
                                  maxMemoryMb: d.maxMemoryMb,
                                  minMemoryMb: d.minMemoryMb,
                                  jvmArguments: d.jvmArguments,
                                )),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: TextEditingController(
                                text: d.javaPath ?? ''),
                            decoration: const InputDecoration(
                              labelText: 'Java 路径（空 = 自动）',
                              hintText: '例如 C:\\Program Files\\Java\\jdk-17\\bin\\javaw.exe',
                            ),
                            onChanged: (v) => _data = rust.VersionSettingsData(
                              isolation: d.isolation,
                              javaPath: v.trim(),
                              maxMemoryMb: d.maxMemoryMb,
                              minMemoryMb: d.minMemoryMb,
                              jvmArguments: d.jvmArguments,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Text('最小内存 (MiB)'),
                              const Spacer(),
                              SizedBox(
                                width: 110,
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  controller: TextEditingController(
                                      text: (d.minMemoryMb ?? 0) > 0
                                          ? '${d.minMemoryMb}'
                                          : ''),
                                  decoration: InputDecoration(
                                    hintText: '${settings.minMemoryMb}',
                                  ),
                                  onChanged: (v) => _data =
                                      rust.VersionSettingsData(
                                    isolation: d.isolation,
                                    javaPath: d.javaPath,
                                    maxMemoryMb: d.maxMemoryMb,
                                    minMemoryMb: int.tryParse(v) ?? 0,
                                    jvmArguments: d.jvmArguments,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('最大内存 (MiB)'),
                              const Spacer(),
                              SizedBox(
                                width: 110,
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  controller: TextEditingController(
                                      text: (d.maxMemoryMb ?? 0) > 0
                                          ? '${d.maxMemoryMb}'
                                          : ''),
                                  decoration: InputDecoration(
                                    hintText: '${settings.maxMemoryMb}',
                                  ),
                                  onChanged: (v) => _data =
                                      rust.VersionSettingsData(
                                    isolation: d.isolation,
                                    javaPath: d.javaPath,
                                    maxMemoryMb: int.tryParse(v) ?? 0,
                                    minMemoryMb: d.minMemoryMb,
                                    jvmArguments: d.jvmArguments,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: TextEditingController(
                                text: d.jvmArguments ?? ''),
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: '额外 JVM 参数（叠加在全局之后）',
                              hintText: '-XX:+UseG1GC -Dfml.ignoreInvalidMinecraftCertificates=true',
                            ),
                            onChanged: (v) => _data = rust.VersionSettingsData(
                              isolation: d.isolation,
                              javaPath: d.javaPath,
                              maxMemoryMb: d.maxMemoryMb,
                              minMemoryMb: d.minMemoryMb,
                              jvmArguments: v,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        PclButton(
                          text: '取消',
                          primary: false,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 10),
                        PclButton(
                          text: _saving ? '保存中...' : '保存',
                          onTap: _saving ? null : _save,
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
