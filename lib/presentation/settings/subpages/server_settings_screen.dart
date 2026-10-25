import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../services/server/http_server.dart';
import '../../server/server_console_screen.dart';

/// 本地 STT API 服务中枢二级设置页面
class ServerSettingsScreen extends StatefulWidget {
  final LocalHttpServer? localHttpServer;
  final VoidCallback? onToggleServer;

  const ServerSettingsScreen({
    super.key,
    this.localHttpServer,
    this.onToggleServer,
  });

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final isServerRunning = widget.localHttpServer?.isRunning ?? false;
    final isCompact = MediaQuery.of(context).size.width < 640;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: context.textMain),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '本地 STT API 服务中枢',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 20, vertical: 16),
            physics: const BouncingScrollPhysics(),
            children: [
              // 服务开关卡片
              Container(
                padding: EdgeInsets.all(isCompact ? 14 : 18),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isServerRunning ? AppColors.emerald.withValues(alpha: 0.4) : context.borderColor,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isServerRunning ? AppColors.emerald : context.textGrey,
                            boxShadow: isServerRunning
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
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'HTTP / WebSocket 转发服务',
                                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textMain),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                isServerRunning
                                    ? '正在监听 127.0.0.1:${AppConstants.defaultServerPort}，局域网与第三方软件可直接调用'
                                    : '服务待机中，开启后可用作系统级本地 Whisper 转录替代',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isServerRunning ? AppColors.emerald : context.textGrey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: isServerRunning,
                          activeThumbColor: AppColors.primary,
                          onChanged: (val) {
                            widget.onToggleServer?.call();
                            Future.delayed(const Duration(milliseconds: 200), () => setState(() {}));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: context.borderColor),
                    const SizedBox(height: 14),
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ServerConsoleScreen(
                              server: widget.localHttpServer,
                              onToggleServer: widget.onToggleServer ?? () {},
                            ),
                          ),
                        ).then((_) => setState(() {}));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: context.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.terminal_rounded, size: 18, color: AppColors.cyan),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '进入实时服务控制台、查看调用日志与接口测试',
                                style: TextStyle(fontSize: 13, color: context.textMain, fontWeight: FontWeight.w500),
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, size: 18, color: context.textGrey),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 协议兼容说明卡片
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.api_rounded, color: AppColors.primary, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'OpenAI Whisper 协议兼容',
                          style: TextStyle(color: context.textMain, fontSize: 13.5, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '接口地址：http://127.0.0.1:8765/v1/audio/transcriptions\n'
                      '支持标准 Multipart/form-data 报文，无缝兼容各大翻译插件、听书 App 与官方 Python openai SDK。',
                      style: TextStyle(color: context.textSub, fontSize: 12, height: 1.5, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
