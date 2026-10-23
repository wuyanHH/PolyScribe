import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../services/task_queue_service.dart';
import '../player/sync_player_screen.dart';

/// 录音文件转写中心 (单文件快速转写 + 批量多选队列)
class BatchImportScreen extends StatefulWidget {
  const BatchImportScreen({super.key});

  @override
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen> {
  final Map<String, TaskProgressEvent> _progressMap = {};
  List<MeetingTask> _tasks = [];
  bool _isLoading = true;
  StreamSubscription<TaskProgressEvent>? _progressSubscription;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    _progressSubscription = TaskQueueService.instance.onProgress.listen((event) {
      if (mounted) {
        setState(() {
          _progressMap[event.taskId] = event;
        });
        if (event.status == TaskStatus.completed || event.status == TaskStatus.error) {
          _loadTasks();
        }
      }
    });
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
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

  /// 选择单个音频并立即启动转写
  Future<void> _pickSingleAudioFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'opus', 'amr', 'flac', 'ogg'],
      );

      if (files.isNotEmpty) {
        final path = files.first.path;
        if (path != null) {
          final task = await TaskQueueService.instance.enqueueAudioFile(path);
          _loadTasks();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已添加「${task.title}」并开始离线转写...')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择音频失败: $e')),
        );
      }
    }
  }

  /// 批量选择多个外部录音文件
  Future<void> _pickMultipleAudioFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'opus', 'amr', 'flac', 'ogg'],
      );

      if (files.isNotEmpty) {
        final paths = files
            .map((f) => f.path)
            .where((p) => p != null)
            .cast<String>()
            .toList();

        await TaskQueueService.instance.enqueueMultipleFiles(paths);
        _loadTasks();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已成功加入 ${paths.length} 个音频文件到转写队列')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败或未授权: $e')),
        );
      }
    }
  }

  Future<void> _deleteTask(String taskId) async {
    await AppDatabase.instance.deleteTask(taskId);
    _loadTasks();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('任务已清除')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('录音文件转写中心', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildActionBar(),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '音频转写队列与历史',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        '共 ${_tasks.length} 个任务',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _tasks.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.audio_file_outlined, size: 56, color: Colors.grey.withValues(alpha: 0.5)),
                                const SizedBox(height: 12),
                                const Text(
                                  '暂无转写任务',
                                  style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '点击上方按钮选取本地通话录音、采访音频或会议语音',
                                  style: TextStyle(color: Colors.grey, fontSize: 13),
                                ),
                              ],
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
          flex: 3,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.add_circle_outline_rounded),
            label: const Text('单音频快速转写', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _pickSingleAudioFile,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: AppColors.surfaceLight),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.queue_music_rounded, size: 18),
            label: const Text('批量导入'),
            onPressed: _pickMultipleAudioFiles,
          ),
        ),
      ],
    );
  }

  Widget _buildTaskCard(MeetingTask task, TaskProgressEvent? progress) {
    final isDone = task.status == TaskStatus.completed;
    final isError = task.status == TaskStatus.error;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone
              ? AppColors.speakerPalette[1].color.withValues(alpha: 0.5)
              : (isError ? Colors.redAccent.withValues(alpha: 0.5) : AppColors.surfaceLight),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isDone
                    ? Icons.check_circle_rounded
                    : (isError ? Icons.error_outline_rounded : Icons.pending_rounded),
                color: isDone
                    ? AppColors.speakerPalette[1].color
                    : (isError ? Colors.redAccent : AppColors.primary),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                    ).then((_) => _loadTasks());
                  },
                  child: const Text('查看纪要 >'),
                )
              else
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18, color: Colors.grey),
                  onPressed: () => _deleteTask(task.id),
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
                valueColor: AlwaysStoppedAnimation(
                  isError ? Colors.redAccent : AppColors.primary,
                ),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              progress.stageDescription,
              style: TextStyle(
                color: isError ? Colors.redAccent : Colors.grey,
                fontSize: 11,
              ),
            ),
          ] else ...[
            Row(
              children: [
                Text(
                  '时长: ${task.durationMs ~/ 1000}秒',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 12),
                Text(
                  '状态: ${task.status.label}',
                  style: TextStyle(
                    color: isDone
                        ? Colors.greenAccent
                        : (isError ? Colors.redAccent : Colors.orangeAccent),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.grey),
                  onPressed: () => _deleteTask(task.id),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
