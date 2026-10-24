import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/app_toast.dart';
import '../../services/server/http_server.dart';
import '../../services/server/inference_lock_manager.dart';

/// 本地 STT API 转发服务控制台 (桌面宽屏自适应 + OpenAI Whisper 协议兼容 + 实时审计日志)
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
            if (mounted) {
              setState(() {
                _localIp = addr.address;
              });
            }
            return;
          }
        }
      }
    } catch (_) {}
  }

  void _copyToClipboard(String text, String tip) {
    Clipboard.setData(ClipboardData(text: text));
    AppToast.success(context, '$tip 已复制到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = widget.server?.isRunning ?? false;
    final baseUrl = 'http://$_localIp:${AppConstants.defaultServerPort}/v1';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          '本地 STT 转发服务中枢',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildServiceStatusCard(isRunning, baseUrl),
                const SizedBox(height: 18),
                _buildQuickIntegrationCard(baseUrl),
                const SizedBox(height: 22),
                _buildLogsHeader(),
                const SizedBox(height: 10),
                _buildLogsList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildServiceStatusCard(bool isRunning, String baseUrl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRunning ? AppColors.emerald.withValues(alpha: 0.5) : AppColors.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isRunning ? AppColors.emerald : AppColors.textMuted,
                  shape: BoxShape.circle,
                  boxShadow: isRunning
                      ? [
                          BoxShadow(
                            color: AppColors.emerald.withValues(alpha: 0.6),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isRunning ? '服务监听中 (运行中)' : '服务已暂停 (待机)',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Switch(
                value: isRunning,
                activeThumbColor: AppColors.emerald,
                onChanged: (_) {
                  widget.onToggleServer();
                  Future.delayed(const Duration(milliseconds: 220), () {
                    if (mounted) setState(() {});
                  });
                },
              ),
            ],
          ),
          const Divider(height: 24, color: AppColors.cardBorder),
          Row(
            children: [
              _buildStatItem('局域网监听地址', '$_localIp:${AppConstants.defaultServerPort}'),
              const SizedBox(width: 8),
              _buildStatItem('累计请求次数', '${InferenceLockManager.instance.totalRequests} 次'),
              const SizedBox(width: 8),
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
          Text(
            label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickIntegrationCard(String baseUrl) {
    final curlExample =
        'curl -X POST $baseUrl/audio/transcriptions -F "file=@sample.wav" -F "model=whisper-1"';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.api_rounded, size: 18, color: AppColors.cyan),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '第三方生态接入参数 (OpenAI Whisper 兼容)',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '兼容沉浸式翻译、ChatGPT-Next-Web、LobeChat、开源阅读/听书 App 及任意 OpenAI STT SDK',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          _buildCopyRow('API Base URL', baseUrl),
          const SizedBox(height: 8),
          _buildCopyRow('API Key', 'polyscribe-local'),
          const SizedBox(height: 8),
          _buildCopyRow('Model Name', 'whisper-1 / sensevoice-small'),
          const SizedBox(height: 8),
          _buildCopyRow('cURL 示例', curlExample),
        ],
      ),
    );
  }

  Widget _buildCopyRow(String label, String value) {
    final isCompact = MediaQuery.of(context).size.width < 600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: isCompact ? 86 : 105,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _copyToClipboard(value, label),
            child: const Icon(Icons.copy_rounded, size: 16, color: AppColors.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsHeader() {
    return Row(
      children: [
        const Icon(Icons.terminal_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            '实时调用监控与排队审计日志',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_logs.isNotEmpty)
          TextButton(
            onPressed: () => setState(() => _logs.clear()),
            child: const Text('清空列表', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _buildLogsList() {
    if (_logs.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: const Text(
          '暂无外部调用记录，发起 POST /v1/audio/transcriptions 即可实时查看',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.cardBorder),
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
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isSuccess ? AppColors.emerald : AppColors.rose,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    log.endpoint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${log.latencyMs}ms',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '客户端: ${log.clientIp} • 载荷大小: ${log.audioBytesLength ~/ 1024} KB',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 4),
              Text(
                '识别结果: ${log.resultPreview}',
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
              ),
            ],
          ),
        );
      },
    );
  }
}
