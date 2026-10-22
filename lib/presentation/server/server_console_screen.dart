import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../services/server/http_server.dart';
import '../../services/server/inference_lock_manager.dart';

/// 本地 STT API 转发服务控制台
class ServerConsoleScreen extends StatefulWidget {
  final LocalHttpServer? server;
  final VoidCallback onToggleServer;

  const ServerConsoleScreen({
    super.key,
    required this.server,
    required this.onToggleServer,
  });

  @override
  State<ServerConsoleScreen> createState() => _ServerConsoleScreenState();
}

class _ServerConsoleScreenState extends State<ServerConsoleScreen> {
  String _localIp = '127.0.0.1';
  List<ApiCallLog> _logs = [];
  /// 日志流事件订阅句柄
  StreamSubscription<ApiCallLog>? _logSubscription;

  @override
  void initState() {
    super.initState();
    _detectLocalIp();
    _logs = List.from(InferenceLockManager.instance.recentLogs);
    _logSubscription = InferenceLockManager.instance.onLogAdded.listen((log) {
      if (mounted) {
        setState(() {
          _logs.insert(0, log);
          if (_logs.length > 50) _logs.removeLast();
        });
      }
    });
  }

  @override
  void dispose() {
    // 销毁时释放事件流监听，杜绝内存泄漏
    _logSubscription?.cancel();
    super.dispose();
  }

  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            setState(() {
              _localIp = addr.address;
            });
            return;
          }
        }
      }
    } catch (_) {}
  }

  void _copyToClipboard(String text, String tip) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$tip已复制到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = widget.server?.isRunning ?? false;
    final baseUrl = 'http://$_localIp:${AppConstants.defaultServerPort}/v1';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('本地 STT 转发服务中枢', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildServiceStatusCard(isRunning, baseUrl),
            const SizedBox(height: 16),
            _buildQuickIntegrationCard(baseUrl),
            const SizedBox(height: 20),
            _buildLogsHeader(),
            const SizedBox(height: 10),
            _buildLogsList(),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceStatusCard(bool isRunning, String baseUrl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isRunning ? AppColors.speakerPalette[1].color : AppColors.surfaceLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: isRunning ? AppColors.speakerPalette[1].color : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isRunning ? '服务监听中 (运行中)' : '服务已暂停 (待机)',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
              Switch(
                value: isRunning,
                activeThumbColor: AppColors.speakerPalette[1].color,
                onChanged: (_) => widget.onToggleServer(),
              ),
            ],
          ),
          const Divider(height: 24, color: AppColors.surfaceLight),
          Row(
            children: [
              _buildStatItem('局域网地址', '$_localIp:${AppConstants.defaultServerPort}'),
              _buildStatItem('总请求次数', '${InferenceLockManager.instance.totalRequests} 次'),
              _buildStatItem('服务状态码', isRunning ? '200 OK' : 'STOPPED'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildQuickIntegrationCard(String baseUrl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '第三方生态接入参数 (OpenAI Whisper 兼容)',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            '兼容沉浸式翻译、ChatGPT-Next-Web、开源阅读/听书 App 及任意 OpenAI STT SDK',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
          const SizedBox(height: 12),
          _buildCopyRow('API Base URL', baseUrl),
          const SizedBox(height: 8),
          _buildCopyRow('API Key', 'polyscribe-local (任意非空字符串)'),
          const SizedBox(height: 8),
          _buildCopyRow('Model Name', 'whisper-1 / sensevoice-small'),
        ],
      ),
    );
  }

  Widget _buildCopyRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => _copyToClipboard(value, label),
            child: const Icon(Icons.copy_rounded, size: 16, color: AppColors.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsHeader() {
    return const Row(
      children: [
        Icon(Icons.terminal_rounded, size: 18, color: AppColors.primary),
        SizedBox(width: 6),
        Text(
          '实时调用监控与排队审计日志',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15),
        ),
      ],
    );
  }

  Widget _buildLogsList() {
    if (_logs.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 30),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('暂无外部调用记录，发起 POST /v1/audio/transcriptions 即可实时查看', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _logs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final log = _logs[index];
        final isSuccess = log.statusCode == 200;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSuccess ? const Color(0x2610B981) : const Color(0x26EF4444),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${log.statusCode}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isSuccess ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(log.endpoint, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                  const Spacer(),
                  Text('${log.latencyMs}ms', style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '来自: ${log.clientIp} • 音频数据: ${log.audioBytesLength ~/ 1024} KB',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                '识别结果: ${log.resultPreview}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
