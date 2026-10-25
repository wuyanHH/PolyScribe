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
        if (event.status == TaskStatus.completed ||
            event.status == TaskStatus.error ||
            event.status == TaskStatus.paused) {
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
      // 优先从断点续转，若无断点则从头识别
      await TaskQueueService.instance.resumeTask(t.id);
    }
    _loadTasks();
    if (mounted && failed.isNotEmpty) {
      AppToast.info(context, '已重新将 ${failed.length} 个任务加入队列恢复转写');
    }
  }

  /// 智能恢复或重新转写确认对话框 (支持秒级断点续转)
  Future<void> _handleRetryOrResumeTask(MeetingTask task) async {
    final segs = await AppDatabase.instance.getSegmentsForTask(task.id);

    if (segs.isEmpty) {
      await _confirmRetryTask(task);
      return;
    }

    if (!mounted) return;
    final int maxMs = segs.map((s) => s.endMs).fold(0, (max, v) => v > max ? v : max);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.history_toggle_off_rounded, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('转写恢复选项', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('录音「${task.title}」已保留部分转录记录：', style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              child: Text(
                '已保存 ${segs.length} 个自然句发言段落 · 已转录至 ${_formatDuration(maxMs)}',
                style: const TextStyle(color: AppColors.primary, fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '您可以选择从断点位置秒级继续，无需从头重新消耗算力；也可以选择清空并全量重转。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.rose,
              side: BorderSide(color: AppColors.rose.withValues(alpha: 0.5)),
            ),
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('清空重新识别'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('从断点继续', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, 'resume'),
          ),
        ],
      ),
    );

    if (action == 'resume') {
      await TaskQueueService.instance.resumeTask(task.id);
      _loadTasks();
      if (mounted) {
        AppToast.success(context, '已启动断点续转，从 ${_formatDuration(maxMs)} 处继续');
      }
    } else if (action == 'retry') {
      await TaskQueueService.instance.retryTask(task.id);
      _loadTasks();
      if (mounted) {
        AppToast.info(context, '已清空旧段落，重新加入转写队列');
      }
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
    await TaskQueueService.instance.cancelOrDeleteTask(task.id);
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
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 640;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        titleSpacing: isCompact ? 12 : 20,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.cyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.queue_music_rounded, color: AppColors.cyan, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '外部音频转写中心',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!isCompact)
                    Text(
                      '全格式硬件解码 · 双声道物理分离 · 串行防 OOM 队列',
                      style: TextStyle(fontSize: 11, color: context.textGrey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (failedCount > 0)
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(
                isCompact ? '重试($failedCount)' : '全部重试 ($failedCount)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              onPressed: _retryAllFailed,
            ),
          IconButton(
            tooltip: '刷新队列',
            icon: const Icon(Icons.refresh_rounded, color: AppColors.textSecondary),
            onPressed: _loadTasks,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(
                  padding: EdgeInsets.all(isCompact ? 12 : 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildActionDropCards(isCompact: isCompact),
                      SizedBox(height: isCompact ? 14 : 20),
                      // 队列标题与统计胶囊自适应换行，彻底杜绝手机端横向溢出
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            isCompact ? '转写队列与记录' : '音频转写队列与历史记录',
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          _buildMiniCounterBadge('排队/处理 $activeCount', AppColors.primary),
                          _buildMiniCounterBadge('已完成 $completedCount', AppColors.emerald),
                          if (failedCount > 0)
                            _buildMiniCounterBadge('失败 $failedCount', AppColors.rose),
                          Text(
                            '共 ${_tasks.length} 项',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
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
                                  return _buildTaskCard(task, progress, summary, isCompact: isCompact);
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
              color: context.surfaceElevatedColor,
              shape: BoxShape.circle,
              border: Border.all(color: context.borderColor),
            ),
            child: const Icon(Icons.audio_file_outlined, size: 42, color: AppColors.cyan),
          ),
          const SizedBox(height: 14),
          Text(
            '转写队列空闲中',
            style: TextStyle(color: context.textMain, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            '点击上方卡片选取本地通话录音、采访音频或历史会议录音，自动执行离线声纹分离与转写',
            style: TextStyle(color: context.textGrey, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildActionDropCards({required bool isCompact}) {
    if (isCompact) {
      return Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _pickSingleAudioFile,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary.withValues(alpha: 0.2),
                      context.surfaceColor,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '单音频转写',
                            style: TextStyle(color: context.textMain, fontSize: 13.5, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'WAV/MP3/M4A等',
                            style: TextStyle(color: context.textSub, fontSize: 10.5),
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
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _pickMultipleAudioFiles,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: context.borderColor),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: AppColors.cyan.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.library_music_rounded, color: AppColors.cyan, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '批量队列导入',
                            style: TextStyle(color: context.textMain, fontSize: 13.5, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '串行排队防闪退',
                            style: TextStyle(color: context.textGrey, fontSize: 10.5),
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
                    context.surfaceColor,
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '单音频极速转写',
                          style: TextStyle(color: context.textMain, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '支持 WAV / MP3 / M4A / AAC / FLAC / OGG 等全格式',
                          style: TextStyle(color: context.textSub, fontSize: 11.5),
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
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.borderColor),
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '批量队列导入',
                          style: TextStyle(color: context.textMain, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '多文件串行调度防内存溢出',
                          style: TextStyle(color: context.textGrey, fontSize: 11.5),
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

  Widget _buildTaskCard(
    MeetingTask task,
    TaskProgressEvent? progress,
    TaskSummaryInfo? summary, {
    required bool isCompact,
  }) {
    final isDone = task.status == TaskStatus.completed;
    final isError = task.status == TaskStatus.error;
    final isPaused = task.status == TaskStatus.paused;
    final isProcessingOrQueued = task.status == TaskStatus.processing || task.status == TaskStatus.queued;
    final words = summary?.totalWordCount ?? 0;
    final segs = summary?.segmentCount ?? 0;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: isDone
          ? () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (_) => SyncPlayerScreen(task: task),
                    ),
                  )
                  .then((_) => _loadTasks());
            }
          : null,
      child: Container(
        padding: EdgeInsets.all(isCompact ? 12 : 16),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDone
                ? AppColors.emerald.withValues(alpha: 0.35)
                : (isError
                    ? AppColors.rose.withValues(alpha: 0.45)
                    : (isPaused ? Colors.orangeAccent.withValues(alpha: 0.45) : context.borderColor)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(isCompact ? 7 : 8),
                  decoration: BoxDecoration(
                    color: (isDone
                            ? AppColors.emerald
                            : (isError
                                ? AppColors.rose
                                : (isPaused ? Colors.orangeAccent : AppColors.primary)))
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isDone
                        ? Icons.check_circle_rounded
                        : (isError
                            ? Icons.error_outline_rounded
                            : (isPaused ? Icons.pause_circle_rounded : Icons.sync_rounded)),
                    color: isDone
                        ? AppColors.emerald
                        : (isError
                            ? AppColors.rose
                            : (isPaused ? Colors.orangeAccent : AppColors.primary)),
                    size: isCompact ? 18 : 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          color: context.textMain,
                          fontWeight: FontWeight.bold,
                          fontSize: isCompact ? 13.5 : 14.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isDone
                            ? '${_formatDuration(task.durationMs)} · $words字 ($segs段)'
                            : (isError
                                ? '转写异常，可点击右侧重试'
                                : (isPaused
                                    ? '已暂停转写 (已存 $segs 段)，点击继续可恢复'
                                    : (task.status == TaskStatus.queued
                                        ? '正在等待前置任务完成并自动调度...'
                                        : '正在解码与转写中...'))),
                        style: TextStyle(color: context.textGrey, fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isDone) ...[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '重新转写此纪要',
                    icon: Icon(Icons.refresh_rounded, size: 18, color: context.textSub),
                    onPressed: () => _confirmRetryTask(task),
                  ),
                  if (!isCompact) ...[
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
                  ],
                ] else if (isProcessingOrQueued) ...[
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orangeAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.pause_circle_outline_rounded, size: 15),
                    label: const Text('暂停', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      await TaskQueueService.instance.pauseTask(task.id);
                      _loadTasks();
                    },
                  ),
                ] else if (isPaused) ...[
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.emerald,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 15),
                    label: const Text('继续', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      await TaskQueueService.instance.resumeTask(task.id);
                      _loadTasks();
                    },
                  ),
                ] else if (isError)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(segs > 0 ? Icons.history_toggle_off_rounded : Icons.refresh_rounded, size: 15),
                    label: Text(segs > 0 ? '续转/重试' : '重试', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: () => _handleRetryOrResumeTask(task),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '移除任务',
                  icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.textGrey),
                  onPressed: () => _deleteTask(task),
                ),
              ],
            ),
            if (progress != null && !isDone) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.progress,
                  backgroundColor: context.bg,
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
                        color: isError ? AppColors.rose : context.textSub,
                        fontSize: 11.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(progress.progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: AppColors.primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
