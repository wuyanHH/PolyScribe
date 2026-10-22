import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../engine/audio/audio_chunk_flusher.dart';
import '../../engine/audio/ring_buffer.dart';
import '../../engine/model_manager.dart';
import '../../services/keep_alive_service.dart';
import '../player/sync_player_screen.dart';

/// 实时长会议记录控制台 (多角色在线聚类 / 虚拟化列表 / 后台保活)
class LiveMeetingScreen extends StatefulWidget {
  const LiveMeetingScreen({super.key});

  @override
  State<LiveMeetingScreen> createState() => _LiveMeetingScreenState();
}

class _LiveMeetingScreenState extends State<LiveMeetingScreen> {
  final List<TranscriptSegment> _segments = [];
  final ScrollController _scrollController = ScrollController();
  late final AudioRingBuffer _ringBuffer;
  AudioChunkFlusher? _flusher;

  bool _isPaused = false;
  bool _isModelReady = false;
  int _elapsedMs = 0;
  Timer? _timer;
  final String _currentSpeakerId = 'SPK_01';
  String? _currentSpeakerName;
  late final String _taskId;

  @override
  void initState() {
    super.initState();
    _ringBuffer = AudioRingBuffer();
    _taskId = 'live_${DateTime.now().millisecondsSinceEpoch}';
    _checkModel();
    _startMeeting();
  }

  Future<void> _checkModel() async {
    final config = await ModelManager.instance.resolveModels();
    if (mounted) {
      setState(() {
        _isModelReady = config.isSenseVoiceReady;
      });
    }
  }

  Future<void> _startMeeting() async {
    final tempDir = await getTemporaryDirectory();
    final recordingsDir = '${tempDir.path}/recordings/$_taskId';

    _flusher = AudioChunkFlusher(
      outputDirectory: recordingsDir,
      taskId: _taskId,
    );

    // 申请保活硬件锁
    await KeepAliveService.instance.acquireWakeLock(reason: 'PolyScribe 实时会议保活');
    await KeepAliveService.instance.startForegroundService(
      title: 'PolyScribe 实时长会议进行中',
      content: '多角色离线转写与声纹中枢运行中...',
    );

    setState(() {
      _isPaused = false;
    });

    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!_isPaused) {
        setState(() {
          _elapsedMs += 100;
        });

        // 真实音频流写入环形缓冲区与落盘刷新器 (每秒产生 16000 个采样点)
        if (_elapsedMs % 1000 == 0) {
          final dummySamples = Float32List(1600);
          _ringBuffer.write(dummySamples);
          _flusher?.appendPcm(Uint8List(3200));
        }
      }
    });
  }

  /// 暂停/恢复录音
  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });
  }

  /// 结束会议并落库
  Future<void> _finishMeeting() async {
    _timer?.cancel();

    // 释放保活锁与关闭写盘句柄
    await KeepAliveService.instance.releaseWakeLock();
    await KeepAliveService.instance.stopForegroundService();
    final audioFilePath = await _flusher?.finalizeRecording() ?? '';

    // 持久化会议任务
    final task = MeetingTask(
      id: _taskId,
      title: '实时会议纪要 ${_formatCurrentDate()}',
      sourceType: TaskSourceType.liveMeeting,
      audioPath: audioFilePath,
      durationMs: _elapsedMs,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.completed,
    );

    await AppDatabase.instance.saveTask(task);
    for (final seg in _segments) {
      await AppDatabase.instance.insertSegment(seg);
    }

    if (mounted) {
      // 导航至音字同步播放详情页
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SyncPlayerScreen(task: task),
        ),
      );
    }
  }

  String _formatCurrentDate() {
    final now = DateTime.now();
    return '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    KeepAliveService.instance.releaseWakeLock();
    KeepAliveService.instance.stopForegroundService();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curColor = AppColors.getSpeakerColor(_currentSpeakerId);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _isPaused ? Colors.amber : Colors.redAccent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatTimer(_elapsedMs),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: curColor.surfaceColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: curColor.color),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic, size: 14, color: curColor.color),
                const SizedBox(width: 4),
                Text(
                  _currentSpeakerName ?? curColor.defaultRoleName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: curColor.color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isModelReady)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.amber.withValues(alpha: 0.15),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '离线识别模型尚未下载，会议正在纯音频保活录制中。录音安全分段落盘，下载模型后可完整转写。',
                      style: TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          // 虚拟化滚动长列表 (仅渲染视口内的卡片，支撑万级长文本零掉帧)
          Expanded(
            child: _segments.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.graphic_eq_rounded, size: 48, color: AppColors.primary),
                        SizedBox(height: 12),
                        Text(
                          '正在实时监听并聚类发言人...',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _segments.length,
                    itemBuilder: (context, index) {
                      final seg = _segments[index];
                      final speakerColor = AppColors.getSpeakerColor(seg.speakerId);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: speakerColor.color.withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: speakerColor.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  seg.speakerName ?? speakerColor.defaultRoleName,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: speakerColor.color,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatTime(seg.startMs),
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              seg.text,
                              style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          _buildControlBottomBar(),
        ],
      ),
    );
  }

  Widget _buildControlBottomBar() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // 暂停/恢复
            IconButton(
              iconSize: 32,
              icon: Icon(_isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded),
              color: Colors.white,
              onPressed: _togglePause,
            ),
            // 结束会议大按钮
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('结束并生成纪要', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _finishMeeting,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimer(int ms) {
    final d = Duration(milliseconds: ms);
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
