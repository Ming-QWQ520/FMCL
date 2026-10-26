import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../rust_bridge/rust_bridge.dart' as rust;
import '../../services/server/server_ping_service.dart';
import '../../widgets/common.dart';

/// 服务器状态查询对话框（对齐 PCL.Core 服务器查询体验）。
Future<void> showServerPing(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const ServerPingDialog(),
  );
}

class ServerPingDialog extends ConsumerStatefulWidget {
  const ServerPingDialog({super.key});

  @override
  ConsumerState<ServerPingDialog> createState() => _ServerPingDialogState();
}

class _ServerPingDialogState extends ConsumerState<ServerPingDialog> {
  final _addrCtrl = TextEditingController();
  bool _querying = false;
  rust.ServerStatus? _status;
  String? _error;

  Future<void> _query() async {
    final addr = _addrCtrl.text.trim();
    if (addr.isEmpty) return;
    setState(() {
      _querying = true;
      _error = null;
      _status = null;
    });
    try {
      final st = await ServerPingService.I.ping(addr);
      if (!mounted) return;
      setState(() {
        _status = st;
        _querying = false;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _querying = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '查询失败: $e';
        _querying = false;
      });
    }
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.dns_rounded, size: 22),
          SizedBox(width: 8),
          Text('查询服务器'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addrCtrl,
                    decoration: const InputDecoration(
                      hintText: '服务器地址，如 mc.hypixel.net 或 host:port',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _query(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _querying ? null : _query,
                  icon: _querying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.travel_explore_rounded, size: 18),
                  label: const Text('查询'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_status != null)
              _StatusCard(status: _status!)
            else if (_querying)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: Text('正在连接…')),
              )
            else if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5534B).withAlpha(22),
                  borderRadius: BorderRadius.circular(AppTheme.radiusM),
                ),
                child: Text(_error!,
                    style: const TextStyle(fontSize: 13, height: 1.5)),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '输入地址后查询服务器的 MOTD、版本、在线人数与延迟。'
                  '（仅支持 1.7+ 现代协议；暂不支持 SRV 记录解析）',
                  style: context.captionStyle,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final rust.ServerStatus status;

  const _StatusCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final latencyColor = status.latencyMs < 100
        ? const Color(0xFF16A34A)
        : status.latencyMs < 300
            ? const Color(0xFFE8A33D)
            : const Color(0xFFE5534B);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (status.favicon != null &&
                  status.favicon!.startsWith('data:image/png;base64,'))
                Builder(builder: (context) {
                  try {
                    final b64 = status.favicon!.split('base64,').last;
                    final bytes = base64.decode(b64);
                    return Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusS),
                        image: DecorationImage(
                            image: MemoryImage(bytes)),
                      ),
                    );
                  } catch (_) {
                    return _placeholderIcon(context);
                  }
                })
              else
                _placeholderIcon(context),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.motd.isEmpty ? status.address : status.motd,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(status.address, style: context.captionStyle),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: latencyColor.withAlpha(24),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${status.latencyMs} ms',
                  style: TextStyle(
                      color: latencyColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.people_rounded,
                  size: 16,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(120)),
              const SizedBox(width: 4),
              Text(
                '${status.playersOnline}/${status.playersMax}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 16),
              Icon(Icons.tag_rounded,
                  size: 16,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(120)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${status.versionName}（协议 ${status.protocol}）',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (status.samplePlayers.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '在线：${status.samplePlayers.join('、')}',
              style: context.captionStyle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _placeholderIcon(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withAlpha(24),
        borderRadius: BorderRadius.circular(AppTheme.radiusS),
      ),
      child: const Icon(Icons.videogame_asset_rounded),
    );
  }
}
