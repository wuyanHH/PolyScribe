import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../services/task_queue_service.dart';
import '../player/sync_player_screen.dart';

/// 纪要与历史记录主界面
class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToMeeting;
  final VoidCallback? onNavigateToBatch;

  const HomeScreen({
    super.key,
    this.onNavigateToMeeting,
    this.onNavigateToBatch,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<MeetingTask> _tasks = [];
  Map<String, TaskSummaryInfo> _summaryMap = {};
  bool _isLoading = true;
  String _searchQuery = '';
  String _selectedFilter = 'all'; // all, live, imported, audio_missing
  StreamSubscription<TaskProgressEvent>? _progressSub;
  TaskProgressEvent? _latestProgress;

  @override
  void initState() {
    super.initState();
    _loadAllTasks();

    _progressSub = TaskQueueService.instance.onProgress.listen((event) {
      if (mounted) {
        setState(() {
          _latestProgress = event;
        });
        if (event.status == TaskStatus.completed || event.status == TaskStatus.error) {
          _loadAllTasks();
        }
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAllTasks() async {
    final tasks = await AppDatabase.instance.getAllTasks();
    // 批量聚合查询，消除逐行遍历引起的 N+1 数据库慢查询
    final summaries = await AppDatabase.instance.getBatchTasksSummaryMap(tasks);

    if (mounted) {
      setState(() {
        _tasks = tasks;
        _summaryMap = summaries;
        _isLoading = false;
      });
    }
  }

  /// 单音频文件选取并直接开启转写
  Future<void> _pickSingleAudioAndTranscribe() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'opus', 'amr', 'flac', 'ogg'],
      );

      if (result.isNotEmpty) {
        final path = result.first.path;
        if (path != null) {
          final task = await TaskQueueService.instance.enqueueAudioFile(path);
          await _loadAllTasks();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已添加「${task.title}」并启动转写，转写完成后可直接点击查看')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $e')),
        );
      }
    }
  }

  /// 批量音频文件选取并加入队列
  Future<void> _pickMultipleAudioAndTranscribe() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'opus', 'amr', 'flac', 'ogg'],
      );

      if (result.isNotEmpty) {
        final paths = result.map((f) => f.path).where((p) => p != null).cast<String>().toList();
        if (paths.isNotEmpty) {
          await TaskQueueService.instance.enqueueMultipleFiles(paths);
          await _loadAllTasks();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已加入 ${paths.length} 个音频至后台转写队列')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('批量选取文件失败: $e')),
        );
      }
    }
  }

  /// 弹出导入音频选项底部抽屉
  void _showImportOptionsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '导入外部录音文件',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                '支持 WAV, MP3, M4A, AAC, FLAC 等格式，自动复制并离线转写',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.audio_file_rounded, color: AppColors.primary),
                ),
                title: const Text('单音频快速转写', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: const Text('选取单个音频文件，立即启动后台离线转写', style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickSingleAudioAndTranscribe();
                },
              ),
              const Divider(color: AppColors.cardBorder),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.speakerPalette[2].color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.queue_music_rounded, color: AppColors.speakerPalette[2].color),
                ),
                title: const Text('批量导入音频', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: const Text('一次性选取多个录音，自动排队串行转写防卡顿', style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickMultipleAudioAndTranscribe();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 过滤后的任务列表
  List<MeetingTask> get _filteredTasks {
    return _tasks.where((task) {
      final summary = _summaryMap[task.id];

      // 1. 分类筛选
      if (_selectedFilter == 'live' && task.sourceType != TaskSourceType.liveMeeting) {
        return false;
      }
      if (_selectedFilter == 'imported' && task.sourceType != TaskSourceType.importedAudio) {
        return false;
      }
      if (_selectedFilter == 'audio_missing' && (summary?.isAudioFileExists ?? true)) {
        return false;
      }

      // 2. 搜索过滤
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.trim().toLowerCase();
        final titleMatch = task.title.toLowerCase().contains(q);
        final snippetMatch = summary?.firstSnippet.toLowerCase().contains(q) ?? false;
        final speakerMatch = summary?.speakers.any((s) => s.toLowerCase().contains(q)) ?? false;
        if (!titleMatch && !snippetMatch && !speakerMatch) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredTasks;

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
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              '纪要与转写历史',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadAllTasks,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('导入外部音频转写', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _showImportOptionsModal,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_latestProgress != null &&
                    (_latestProgress!.status == TaskStatus.processing ||
                        _latestProgress!.status == TaskStatus.queued))
                  _buildQueueProgressBanner(_latestProgress!),
                _buildSearchBar(),
                _buildFilterChips(),
                Expanded(
                  child: list.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final task = list[index];
                            final summary = _summaryMap[task.id];
                            return _buildTaskCard(task, summary);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: '搜索会议标题、发言人或发言片段 (FTS5)...',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
          prefixIcon: const Icon(Icons.search, color: AppColors.primary, size: 20),
          filled: true,
          fillColor: AppColors.background,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (val) {
          setState(() {
            _searchQuery = val;
          });
        },
      ),
    );
  }

  Widget _buildFilterChips() {
    final chips = [
      {'key': 'all', 'label': '全部 (${_tasks.length})'},
      {'key': 'live', 'label': '实时会议'},
      {'key': 'imported', 'label': '导入音频'},
      {'key': 'audio_missing', 'label': '⚠️ 音频已删'},
    ];

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: chips.map((c) {
            final isSelected = _selectedFilter == c['key'];
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c['label']!),
                selected: isSelected,
                selectedColor: AppColors.primary,
                backgroundColor: AppColors.background,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                onSelected: (val) {
                  if (val) {
                    setState(() => _selectedFilter = c['key']!);
                  }
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notes_rounded, size: 56, color: Colors.grey.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text(
            '暂无符合条件的纪要记录',
            style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '点击右下角按钮直接选择单个音频，或切换到实时长会议开始录音',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            icon: const Icon(Icons.mic_rounded, size: 18),
            label: const Text('立即开启实时会议转录', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: widget.onNavigateToMeeting,
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(MeetingTask task, TaskSummaryInfo? summary) {
    final isLive = task.sourceType == TaskSourceType.liveMeeting;
    final hasAudio = summary?.isAudioFileExists ?? (task.audioPath.isNotEmpty && File(task.audioPath).existsSync());
    final speakers = summary?.speakers ?? [];
    final wordCount = summary?.totalWordCount ?? 0;
    final snippet = summary?.firstSnippet ?? '';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SyncPlayerScreen(task: task),
          ),
        );
        _loadAllTasks();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isLive ? Icons.mic_rounded : Icons.audio_file_rounded,
                  color: isLive ? AppColors.primary : AppColors.speakerPalette[2].color,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.grey, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            // 元数据行
            Row(
              children: [
                _buildTag(
                  task.status.label,
                  color: task.status == TaskStatus.completed
                      ? Colors.greenAccent
                      : (task.status == TaskStatus.error ? Colors.redAccent : Colors.orangeAccent),
                ),
                const SizedBox(width: 6),
                _buildTag('时长: ${task.durationMs ~/ 1000}秒'),
                const SizedBox(width: 6),
                _buildTag('共 $wordCount 字'),
                const SizedBox(width: 6),
                if (!hasAudio)
                  _buildWarningTag('音频已删 (仅纪要)')
                else
                  _buildTag('物理音频正常', color: Colors.greenAccent),
              ],
            ),
            if (speakers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('发言人: ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  Expanded(
                    child: Text(
                      speakers.join('、'),
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (snippet.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  snippet,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTag(String text, {Color color = Colors.grey}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 10)),
    );
  }

  Widget _buildWarningTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildQueueProgressBanner(TaskProgressEvent progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: AppColors.primary.withValues(alpha: 0.3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '后台转写队列: ${progress.stageDescription}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${(progress.progress * 100).toInt()}%',
                style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.progress,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              minHeight: 3,
            ),
          ),
        ],
      ),
    );
  }
}
