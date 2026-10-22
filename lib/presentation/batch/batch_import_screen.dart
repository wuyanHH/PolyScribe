import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../services/task_queue_service.dart';
import '../player/sync_player_screen.dart';

/// 录音多选批处理导入中心
class BatchImportScreen extends StatefulWidget {
  const BatchImportScreen({super.key});

  @override
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen> {
  final Map<String, TaskProgressEvent> _progressMap = {};
  List<MeetingTask> _tasks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    TaskQueueService.instance.onProgress.listen((event) {
      if (mounted) {
        setState(() {
          _progressMap[event.taskId] = event;
        });
        if (event.status == TaskStatus.completed) {
          _loadTasks();
        }
      }
    });
  }

  Future<void> _loadTasks() async {
    final tasks = await AppDatabase.instance.getAllTasks();
    if (mounted) {
      setState(() {
        _tasks = tasks.where((t) => t.sourceType == TaskSourceType.importedAudio).toList();
        _isLoading = false;
      });
    }
  }

  /// 选择外部录音文件
  Future<void> _pickAudioFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'opus', 'amr', 'ogg'],
      );

      if (files.isNotEmpty) {
        final paths = files
            .map((f) => f.path)
            .where((p) => p != null)
            .cast<String>()
            .toList();

        await TaskQueueService.instance.enqueueMultipleFiles(paths);
        _loadTasks();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败或未授权: $e')),
        );
      }
    }
  }

  /// 快速生成模拟测试通话录音 (用于真机或无测试录音时直接验证)
  Future<void> _createMockCallRecording() async {
    final dir = await getTemporaryDirectory();
    final sampleFile = File('${dir.path}/mock_call_${DateTime.now().millisecondsSinceEpoch}.wav');

    // 写入模拟立体声 PCM 音频头与数据 (4000 个采样点)
    final pcmBytes = List<int>.generate(8000, (i) => i % 256);
    await sampleFile.writeAsBytes(pcmBytes);

    await TaskQueueService.instance.enqueueAudioFile(
      sampleFile.path,
      customTitle: '立体声双声道通话录音测试',
    );
    _loadTasks();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('录音文件批处理队列', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildActionBar(),
                  const SizedBox(height: 16),
                  const Text(
                    '任务处理队列与历史',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _tasks.isEmpty
                        ? const Center(
                            child: Text(
                              '暂无导入任务，点击上方按钮选择录音或生成模拟通话',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _tasks.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final task = _tasks[index];
                              final progress = _progressMap[task.id];
                              return _buildTaskCard(task, progress);
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildActionBar() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('多选导入录音'),
            onPressed: _pickAudioFiles,
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.speakerPalette[2].color,
            side: BorderSide(color: AppColors.speakerPalette[2].color.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.science_outlined),
          label: const Text('模拟通话测试'),
          onPressed: _createMockCallRecording,
        ),
      ],
    );
  }

  Widget _buildTaskCard(MeetingTask task, TaskProgressEvent? progress) {
    final isDone = task.status == TaskStatus.completed;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone ? AppColors.speakerPalette[1].color.withValues(alpha: 0.5) : AppColors.surfaceLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isDone ? Icons.check_circle_rounded : Icons.pending_rounded,
                color: isDone ? AppColors.speakerPalette[1].color : AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              if (isDone)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SyncPlayerScreen(task: task),
                      ),
                    );
                  },
                  child: const Text('打开音字详情 >'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (progress != null && !isDone) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.progress,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              progress.stageDescription,
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ] else ...[
            Text(
              '音频时长: ${task.durationMs ~/ 1000}秒 • 状态: ${task.status.value}',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
