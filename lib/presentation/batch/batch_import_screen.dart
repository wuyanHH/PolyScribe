import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../services/task_queue_service.dart';
import '../player/sync_player_screen.dart';

/// 录音文件转写中心 (单文件快速转写 + 批量多选防 OOM 串行队列工作台)
class BatchImportScreen extends StatefulWidget {
  const BatchImportScreen({super.key});

  @override
  State<BatchImportScreen> createState() => _BatchImportScreenState();
}

class _BatchImportScreenState extends State<BatchImportScreen> {
  final Map<String, TaskProgressEvent> _progressMap = {};
  List<MeetingTask> _tasks = [];
  Map<String, TaskSummaryInfo> _summaryMap = {};
  bool _isLoading = true;
  StreamSubscription<TaskProgressEvent>? _progressSubscription;
  StreamSubscription<void>? _dbChangeSub;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    TaskQueueService.instance.recoverPendingOrFailedImportedTasks();
    _progressSubscription = TaskQueueService.instance.onProgress.listen((event) {
      if (mounted) {
        setState(() {
          _progressMap[event.taskId] = event;
        });
        if (event.status == TaskStatus.completed || event.status == TaskStatus.error) {
          _scheduleReloadTasks();
        }
      }
    });
    _dbChangeSub = AppDatabase.instance.onDatabaseChanged.listen((_) {
      if (mounted) _scheduleReloadTasks();
    });
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _dbChangeSub?.cancel();
    super.dispose();
  }

  bool _isReloadScheduled = false;

  void _scheduleReloadTasks() {
    if (_isReloadScheduled || !mounted) return;
    _isReloadScheduled = true;
    Future.delayed(const Duration(milliseconds: 150), () {
      _isReloadScheduled = false;
      if (mounted) _loadTasks();
    });
  }

  Future<void> _loadTasks() async {
    final tasks = await AppDatabase.instance.getAllTasks();
    final imported = tasks.where((t) => t.sourceType == TaskSourceType.importedAudio).toList();
    final summaries = await AppDatabase.instance.getBatchTasksSummaryMap(imported);
    if (mounted) {
      setState(() {
        _tasks = imported;
        _summaryMap = summaries;
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
            AppToast.success(context, '已添加「${task.title}」并开始离线转写');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '选择音频失败: $e');
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
          AppToast.success(context, '已成功加入 ${paths.length} 个音频文件到转写队列');
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '选择文件失败或未授权: $e');
      }
    }
  }

  Future<void> _retryAllFailed() async {
    final failed = _tasks.where((t) => t.status == TaskStatus.error).toList();
    for (final t in failed) {
      await TaskQueueService.instance.retryTask(t.id);
    }
    _loadTasks();
    if (mounted && failed.isNotEmpty) {
      AppToast.info(context, '已重新将 ${failed.length} 个失败任务加入队列');
    }
  }

  Future<void> _confirmRetryTask(MeetingTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.refresh_rounded, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('重新转写确认', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定重新生成「${task.title}」的纪要吗？', style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text(
              '重新转写将清空已生成的发言段落，并使用当前最优模型重新切句与识别。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重新转写', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await TaskQueueService.instance.retryTask(task.id);
      _loadTasks();
      if (mounted) {
        AppToast.success(context, '已重新加入转写队列');
      }
    }
  }

  Future<void> _deleteTask(MeetingTask task) async {
    await AppDatabase.instance.deleteTask(task.id);
    _loadTasks();
    if (mounted) {
      AppToast.info(context, '已移除任务「${task.title}」');
    }
  }

  @override
  Widget build(BuildContext context) {
    final completedCount = _tasks.where((t) => t.status == TaskStatus.completed).length;
    final failedCount = _tasks.where((t) => t.status == TaskStatus.error).length;
    final activeCount = _tasks.length - completedCount - failedCount;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.cyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.queue_music_rounded, color: AppColors.cyan, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '外部音频转写中心',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  '全格式硬件解码 · 双声道物理分离 · 串行防 OOM 队列',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (failedCount > 0)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text('全部重试 ($failedCount)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: _retryAllFailed,
            ),
          IconButton(
            tooltip: '刷新队列',
            icon: const Icon(Icons.refresh_rounded, color: AppColors.textSecondary),
            onPressed: _loadTasks,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildActionDropCards(),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Text(
                            '音频转写队列与历史记录',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          _buildMiniCounterBadge('处理/排队 $activeCount', AppColors.primary),
                          const SizedBox(width: 6),
                          _buildMiniCounterBadge('已完成 $completedCount', AppColors.emerald),
                          if (failedCount > 0) ...[
                            const SizedBox(width: 6),
                            _buildMiniCounterBadge('失败 $failedCount', AppColors.rose),
                          ],
                          const Spacer(),
                          Text(
                            '共 ${_tasks.length} 个任务',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _tasks.isEmpty
                            ? _buildEmptyQueueView()
                            : ListView.separated(
                                physics: const BouncingScrollPhysics(),
                                itemCount: _tasks.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final task = _tasks[index];
                                  final progress = _progressMap[task.id];
                                  final summary = _summaryMap[task.id];
                                  return _buildTaskCard(task, progress, summary);
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildMiniCounterBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildEmptyQueueView() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: const Icon(Icons.audio_file_outlined, size: 42, color: AppColors.cyan),
          ),
          const SizedBox(height: 14),
          const Text(
            '转写队列空闲中',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '点击上方卡片选取本地通话录音、采访音频或历史会议录音，自动执行离线声纹分离与转写',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildActionDropCards() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _pickSingleAudioFile,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.2),
                    AppColors.surface,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '单音频极速转写',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '支持 WAV / MP3 / M4A / AAC / FLAC / OGG 等全格式',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios_rounded, size: 15, color: AppColors.primary),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 2,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _pickMultipleAudioFiles,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.cyan.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.library_music_rounded, color: AppColors.cyan, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '批量队列导入',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '多文件串行调度防内存溢出',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(int durationMs) {
    final totalSeconds = durationMs ~/ 1000;
    if (totalSeconds < 60) {
      return '$totalSeconds秒';
    }
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
  }

  Widget _buildTaskCard(MeetingTask task, TaskProgressEvent? progress, TaskSummaryInfo? summary) {
    final isDone = task.status == TaskStatus.completed;
    final isError = task.status == TaskStatus.error;
    final words = summary?.totalWordCount ?? 0;
    final segs = summary?.segmentCount ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDone
              ? AppColors.emerald.withValues(alpha: 0.35)
              : (isError ? AppColors.rose.withValues(alpha: 0.45) : AppColors.cardBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (isDone ? AppColors.emerald : (isError ? AppColors.rose : AppColors.primary))
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isDone
                      ? Icons.check_circle_rounded
                      : (isError ? Icons.error_outline_rounded : Icons.sync_rounded),
                  color: isDone ? AppColors.emerald : (isError ? AppColors.rose : AppColors.primary),
                  size: 20,
                ),
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
                        fontWeight: FontWeight.bold,
                        fontSize: 14.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isDone
                          ? '时长: ${_formatDuration(task.durationMs)} · 共 $words 字 ($segs 段)'
                          : '音频路径: ${task.audioPath}',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isDone) ...[
                IconButton(
                  tooltip: '重新转写此纪要',
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: AppColors.textSecondary),
                  onPressed: () => _confirmRetryTask(task),
                ),
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.16),
                    foregroundColor: AppColors.primary,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 16),
                  label: const Text('查看纪要', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) => SyncPlayerScreen(task: task),
                          ),
                        )
                        .then((_) => _loadTasks());
                  },
                ),
              ] else if (isError)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重新转写', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () => _confirmRetryTask(task),
                ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '移除任务',
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.textMuted),
                onPressed: () => _deleteTask(task),
              ),
            ],
          ),
          if (progress != null && !isDone) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.progress,
                backgroundColor: AppColors.background,
                valueColor: AlwaysStoppedAnimation(
                  isError ? AppColors.rose : AppColors.primary,
                ),
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    progress.stageDescription,
                    style: TextStyle(
                      color: isError ? AppColors.rose : AppColors.textSecondary,
                      fontSize: 11.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(progress.progress * 100).toInt()}%',
                  style: const TextStyle(color: AppColors.primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
