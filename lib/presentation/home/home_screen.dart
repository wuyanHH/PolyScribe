import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../engine/model_manager.dart';
import '../../services/server/http_server.dart';
import '../batch/batch_import_screen.dart';
import '../meeting/live_meeting_screen.dart';
import '../player/sync_player_screen.dart';
import '../server/server_console_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<MeetingTask> _tasks = [];
  bool _isLoading = true;
  bool _isServerRunning = false;
  LocalHttpServer? _localHttpServer;
  ModelConfig? _modelConfig;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 1. 初始化数据库与检测本地模型
    final config = await ModelManager.instance.resolveModels();
    final tasks = await AppDatabase.instance.getAllTasks();

    setState(() {
      _modelConfig = config;
      _tasks = tasks;
      _isLoading = false;
    });
  }

  Future<void> _toggleServer() async {
    if (_isServerRunning) {
      await _localHttpServer?.stop();
      setState(() {
        _isServerRunning = false;
      });
    } else {
      _localHttpServer = LocalHttpServer(
        port: AppConstants.defaultServerPort,
      );
      await _localHttpServer!.start();
      setState(() {
        _isServerRunning = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                AppConstants.appShortName,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              AppConstants.appFullName,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '本地 STT 转发服务控制台',
            icon: Icon(
              Icons.wifi_tethering,
              color: _isServerRunning ? AppColors.speakerPalette[1].color : Colors.grey,
            ),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ServerConsoleScreen(
                    server: _localHttpServer,
                    onToggleServer: _toggleServer,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildEngineStatusCard(),
                  const SizedBox(height: 20),
                  _buildQuickActionCards(),
                  const SizedBox(height: 24),
                  _buildRecentTasksSection(),
                ],
              ),
            ),
    );
  }

  /// 状态看板卡片
  Widget _buildEngineStatusCard() {
    final isVadReady = _modelConfig?.isVadReady ?? false;
    final isAsrReady = _modelConfig?.isSenseVoiceReady ?? false;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '端侧引擎状态',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _isServerRunning
                      ? AppColors.speakerPalette[1].surfaceColor
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _isServerRunning
                      ? 'HTTP :${AppConstants.defaultServerPort} 运行中'
                      : '服务待机',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isServerRunning
                        ? AppColors.speakerPalette[1].color
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStatusPill('Silero-VAD v5', isVadReady),
              const SizedBox(width: 8),
              _buildStatusPill('SenseVoice-Small', isAsrReady),
              const SizedBox(width: 8),
              _buildStatusPill('CAM++ 声纹聚类', isVadReady),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(String name, bool ready) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ready ? const Color(0x2610B981) : const Color(0x26EF4444),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ready ? Icons.check_circle : Icons.circle_outlined,
            size: 12,
            color: ready ? const Color(0xFF10B981) : const Color(0xFFEF4444),
          ),
          const SizedBox(width: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              color: ready ? const Color(0xFF10B981) : const Color(0xFFEF4444),
            ),
          ),
        ],
      ),
    );
  }

  /// 快捷入口卡片
  Widget _buildQuickActionCards() {
    return Row(
      children: [
        Expanded(
          child: _buildActionTile(
            title: '实时长会议',
            subtitle: '多角色在线聚类 / 息屏保活',
            icon: Icons.mic_rounded,
            color: AppColors.primary,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LiveMeetingScreen()),
              ).then((_) => _bootstrap());
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionTile(
            title: '导入批处理',
            subtitle: '通话录音 / 双声道物理预检',
            icon: Icons.queue_music_rounded,
            color: AppColors.speakerPalette[2].color,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BatchImportScreen()),
              ).then((_) => _bootstrap());
            },
          ),
        ),
      ],
    );
  }

  Widget _buildActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// 历史纪要列表
  Widget _buildRecentTasksSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '会议纪要与转写记录',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        if (_tasks.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              children: [
                Icon(Icons.notes_rounded, size: 40, color: Colors.grey),
                SizedBox(height: 8),
                Text('暂无会议记录，点击上方开启新会议或导入录音', style: TextStyle(color: Colors.grey)),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final task = _tasks[index];
              return InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SyncPlayerScreen(task: task),
                    ),
                  ).then((_) => _bootstrap());
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        task.sourceType == TaskSourceType.liveMeeting
                            ? Icons.mic
                            : Icons.audio_file,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '时长: ${task.durationMs ~/ 1000}秒 • 状态: ${task.status.value}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
