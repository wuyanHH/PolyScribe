import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../services/task_queue_service.dart';
import '../player/sync_player_screen.dart';
import '../widgets/polyscribe_logo.dart';

/// 纪要与历史记录主界面 (Bento 生产力看板 + FTS5 全文深度检索 + 响应式双列网格/列表自适应)
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
  final TextEditingController _searchController = TextEditingController();
  List<MeetingTask> _tasks = [];
  Map<String, TaskSummaryInfo> _summaryMap = {};
  Set<String> _ftsMatchedTaskIds = {};
  bool _isLoading = true;
  String _searchQuery = '';
  String _selectedFilter = 'all'; // all, live, imported, audio_missing
  bool _useGridOnWide = true;
  StreamSubscription<TaskProgressEvent>? _progressSub;
  StreamSubscription<void>? _dbChangeSub;
  TaskProgressEvent? _latestProgress;
  Timer? _searchDebounceTimer;

  @override
  void initState() {
    super.initState();
    _loadAllTasks();
    TaskQueueService.instance.recoverPendingOrFailedImportedTasks();

    _progressSub = TaskQueueService.instance.onProgress.listen((event) {
      if (mounted) {
        setState(() {
          _latestProgress = event;
        });
        if (event.status == TaskStatus.completed ||
            event.status == TaskStatus.error ||
            event.status == TaskStatus.paused) {
          _loadAllTasks();
        }
      }
    });

    // 监听数据库全局变更流，实现跨页面实时无感刷新
    _dbChangeSub = AppDatabase.instance.onDatabaseChanged.listen((_) {
      if (mounted) {
        _loadAllTasks();
      }
    });
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _progressSub?.cancel();
    _dbChangeSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllTasks() async {
    final tasks = await AppDatabase.instance.getAllTasks();
    final summaries = await AppDatabase.instance.getBatchTasksSummaryMap(tasks);
    Set<String> ftsHits = {};
    if (_searchQuery.trim().isNotEmpty) {
      ftsHits = await AppDatabase.instance.searchTaskIdsByKeyword(_searchQuery.trim());
    }

    if (mounted) {
      setState(() {
        _tasks = tasks;
        _summaryMap = summaries;
        _ftsMatchedTaskIds = ftsHits;
        _isLoading = false;
      });
    }
  }

  /// 搜索框输入防抖处理 (250ms 防抖收敛高频击键，消除并发 SQL 竞态)
  void _onSearchChanged(String val) {
    _searchDebounceTimer?.cancel();
    setState(() {
      _searchQuery = val;
    });

    final trimmed = val.trim();
    if (trimmed.isEmpty) {
      if (mounted) {
        setState(() => _ftsMatchedTaskIds = {});
      }
      return;
    }

    _searchDebounceTimer = Timer(const Duration(milliseconds: 250), () async {
      final hits = await AppDatabase.instance.searchTaskIdsByKeyword(trimmed);
      if (mounted && _searchQuery.trim() == trimmed) {
        setState(() {
          _ftsMatchedTaskIds = hits;
        });
      }
    });
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
            AppToast.success(context, '已添加「${task.title}」并启动后台转写');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '选择文件失败: $e');
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
            AppToast.success(context, '已加入 ${paths.length} 个音频至后台转写队列');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '批量选取文件失败: $e');
      }
    }
  }

  /// 弹出导入音频选项底部抽屉
  void _showImportOptionsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '导入外部录音文件',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                '支持 WAV, MP3, M4A, AAC, FLAC, OGG 等格式，自动沙盒拷贝并离线转写',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 20),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: AppColors.surface,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.audio_file_rounded, color: AppColors.primary),
                ),
                title: Text('单音频快速转写', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                subtitle: const Text('选取单个音频文件，立即启动后台离线转写', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickSingleAudioAndTranscribe();
                },
              ),
              const SizedBox(height: 10),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: AppColors.surface,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.cyan.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.queue_music_rounded, color: AppColors.cyan),
                ),
                title: Text('批量导入音频', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                subtitle: const Text('一次性选取多个录音，自动排队串行转写防卡顿', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
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

  /// 快速重命名任务
  Future<void> _renameTask(MeetingTask task) async {
    final ctrl = TextEditingController(text: task.title);
    String? newTitle;
    try {
      newTitle = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('重命名会议纪要', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    if (newTitle != null && newTitle.isNotEmpty && newTitle != task.title) {
      await AppDatabase.instance.updateTaskTitle(task.id, newTitle);
    }
  }

  /// 快速删除任务确认
  Future<void> _deleteTaskWithConfirm(MeetingTask task) async {
    bool deleteAudio = false;
    final hasAudio = _summaryMap[task.id]?.isAudioFileExists ?? false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.rose),
              SizedBox(width: 8),
              Text('删除纪要确认', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '确定要删除「${task.title}」吗？此操作将清除所有转写段落与全文检索索引。',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13.5, height: 1.5),
              ),
              if (hasAudio) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteAudio,
                  activeColor: AppColors.rose,
                  title: const Text('同时删除本地音频源文件', style: TextStyle(color: Colors.white, fontSize: 13)),
                  onChanged: (v) => setDialogState(() => deleteAudio = v ?? false),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.rose, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await TaskQueueService.instance.cancelOrDeleteTask(task.id, deleteAudioFile: deleteAudio);
      if (mounted) {
        AppToast.info(context, '纪要记录已删除');
        await _loadAllTasks();
      }
    }
  }

  /// 重新转写纪要确认
  Future<void> _retryTaskWithConfirm(MeetingTask task) async {
    final hasAudio = _summaryMap[task.id]?.isAudioFileExists ?? false;
    if (!hasAudio) {
      AppToast.warning(context, '原始音频文件不存在或已移动，无法重新转写');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.refresh_rounded, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('重新识别纪要', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定要重新转写「${task.title}」吗？', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            const Text(
              '这将清空当前该纪要的历史识别文本，并加入转写队列重新进行语音活动检测与文本识别。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.45),
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
      await _loadAllTasks();
      if (mounted) {
        AppToast.success(context, '已重新加入后台转写队列');
      }
    }
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

      // 2. 搜索过滤 (标题 + 发言人 + 首句摘要 + FTS5 全文段落命中)
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.trim().toLowerCase();
        final titleMatch = task.title.toLowerCase().contains(q);
        final snippetMatch = summary?.firstSnippet.toLowerCase().contains(q) ?? false;
        final speakerMatch = summary?.speakers.any((s) => s.toLowerCase().contains(q)) ?? false;
        final ftsMatch = _ftsMatchedTaskIds.contains(task.id);
        if (!titleMatch && !snippetMatch && !speakerMatch && !ftsMatch) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredTasks;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 960;
    final isCompact = screenWidth < 600;
    final horizontalPad = isCompact ? 12.0 : 20.0;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        titleSpacing: isCompact ? 12 : 20,
        title: Row(
          children: [
            const PolyScribeLogo(size: 28),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.primaryDark],
                ),
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Text(
                AppConstants.appShortName,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '纪要与转写历史',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: context.textMain),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (isWide)
            IconButton(
              tooltip: _useGridOnWide ? '切换为单列列表视图' : '切换为双列网格视图',
              icon: Icon(
                _useGridOnWide ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
                size: 20,
                color: context.textSub,
              ),
              onPressed: () => setState(() => _useGridOnWide = !_useGridOnWide),
            ),
          IconButton(
            tooltip: '刷新数据',
            icon: Icon(Icons.refresh_rounded, color: context.textSub),
            onPressed: _loadAllTasks,
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        icon: const Icon(Icons.add_rounded, size: 20),
        label: Text(
          isCompact ? '导入音频' : '导入外部音频转写',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
        ),
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
                _buildSearchBarAndQuickFilters(isCompact: isCompact, horizontalPad: horizontalPad),
                Expanded(
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      // 顶部生产力 Bento 统计概览
                      SliverToBoxAdapter(
                        child: _buildBentoStatsHeader(isWide, isCompact: isCompact, horizontalPad: horizontalPad),
                      ),
                      if (list.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildEmptyState(),
                        )
                      else if (isWide && _useGridOnWide)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(horizontalPad, 4, horizontalPad, 96),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 560,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              mainAxisExtent: 204,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final task = list[index];
                                final summary = _summaryMap[task.id];
                                return _buildTaskCard(task, summary, isGridCard: true, isCompact: false);
                              },
                              childCount: list.length,
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(horizontalPad, 4, horizontalPad, 88),
                          sliver: SliverList.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, _) => SizedBox(height: isCompact ? 10 : 12),
                            itemBuilder: (context, index) {
                              final task = list[index];
                              final summary = _summaryMap[task.id];
                              return _buildTaskCard(task, summary, isGridCard: false, isCompact: isCompact);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 顶部 Bento 生产力概览看板 (手机端高密度三联指标条，桌面端完整四卡片)
  Widget _buildBentoStatsHeader(bool isWide, {required bool isCompact, required double horizontalPad}) {
    final totalTasks = _tasks.length;
    final liveCount = _tasks.where((t) => t.sourceType == TaskSourceType.liveMeeting).length;
    final totalDurationMs = _tasks.fold<int>(0, (acc, t) => acc + t.durationMs);
    final totalWords = _summaryMap.values.fold<int>(0, (acc, s) => acc + s.totalWordCount);

    if (isCompact) {
      return Padding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 10, horizontalPad, 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildCompactStatItem(
                  label: '累计纪要',
                  value: '$totalTasks 篇',
                  sub: '会议$liveCount·导入${totalTasks - liveCount}',
                  color: AppColors.primary,
                ),
              ),
              Container(width: 1, height: 32, color: AppColors.cardBorder),
              Expanded(
                child: _buildCompactStatItem(
                  label: '累计时长',
                  value: _formatOverviewDuration(totalDurationMs),
                  sub: '16kHz 离线识别',
                  color: AppColors.emerald,
                ),
              ),
              Container(width: 1, height: 32, color: AppColors.cardBorder),
              Expanded(
                child: _buildCompactStatItem(
                  label: '沉淀字数',
                  value: _formatNumber(totalWords),
                  sub: 'FTS5 全文索引',
                  color: AppColors.cyan,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPad, 14, horizontalPad, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildStatMetricCard(
                  icon: Icons.auto_stories_rounded,
                  fallbackIcon: Icons.library_books_rounded,
                  label: '累计纪要资产',
                  value: '$totalTasks 篇',
                  subtext: '实时会议 $liveCount 篇 · 导入 ${totalTasks - liveCount} 篇',
                  accentColor: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatMetricCard(
                  icon: Icons.timer_outlined,
                  fallbackIcon: Icons.timer_outlined,
                  label: '累计转写时长',
                  value: _formatOverviewDuration(totalDurationMs),
                  subtext: '16kHz 离线端侧高精度识别',
                  accentColor: AppColors.emerald,
                ),
              ),
              if (isWide) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatMetricCard(
                    icon: Icons.text_fields_rounded,
                    fallbackIcon: Icons.text_fields_rounded,
                    label: '累计沉淀字数',
                    value: _formatNumber(totalWords),
                    subtext: 'FTS5 毫秒级全文索引已就绪',
                    accentColor: AppColors.cyan,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildQuickStartActionCard(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 手机端高密度统计单项 (无冗余大图标占位，文字完整清晰)
  Widget _buildCompactStatItem({
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 14.5, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            sub,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 9.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildStatMetricCard({
    required IconData icon,
    required IconData fallbackIcon,
    required String label,
    required String value,
    required String subtext,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(fallbackIcon, color: accentColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: context.textGrey, fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: context.textMain,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtext,
                  style: TextStyle(color: context.textSub, fontSize: 10.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStartActionCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: widget.onNavigateToMeeting,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withValues(alpha: 0.22),
              context.surfaceColor,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.mic_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '实时会议工作台',
                    style: TextStyle(color: AppColors.primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '开启现场转录',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    '支持麦克风+系统内录',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 10.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.primary),
          ],
        ),
      ),
    );
  }

  /// 搜索框及分类筛选栏
  Widget _buildSearchBarAndQuickFilters({required bool isCompact, required double horizontalPad}) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(horizontalPad, 6, horizontalPad, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: context.textMain, fontSize: 13),
              decoration: InputDecoration(
                hintText: isCompact
                    ? '搜索标题、发言人或正文内容...'
                    : '搜索会议标题、发言人或任意段落全文内容 (FTS5)...',
                hintStyle: TextStyle(color: context.textGrey, fontSize: 12.5),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary, size: 19),
                prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 17, color: Colors.grey),
                        tooltip: '清空搜索词',
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                filled: true,
                fillColor: context.bg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.primary, width: 1.2),
                ),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          const SizedBox(width: 8),
          _buildFilterButton(),
        ],
      ),
    );
  }

  /// 搜索框右侧分类筛选弹出按钮
  Widget _buildFilterButton() {
    final isFiltered = _selectedFilter != 'all';
    final liveCount = _tasks.where((t) => t.sourceType == TaskSourceType.liveMeeting).length;
    final importedCount = _tasks.where((t) => t.sourceType == TaskSourceType.importedAudio).length;
    final missingCount = _tasks.where((t) => !(_summaryMap[t.id]?.isAudioFileExists ?? true)).length;

    return Theme(
      data: Theme.of(context).copyWith(
        popupMenuTheme: PopupMenuThemeData(
          color: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.surfaceLight),
          ),
        ),
      ),
      child: PopupMenuButton<String>(
        tooltip: '分类筛选',
        initialValue: _selectedFilter,
        offset: const Offset(0, 44),
        color: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceLight),
        ),
        onSelected: (val) {
          setState(() {
            _selectedFilter = val;
          });
        },
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isFiltered ? AppColors.primary.withValues(alpha: 0.15) : AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFiltered ? AppColors.primary.withValues(alpha: 0.5) : AppColors.cardBorder,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: isFiltered,
                smallSize: 8,
                backgroundColor: AppColors.primary,
                child: Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: isFiltered ? AppColors.primary : Colors.white70,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _getFilterLabel(_selectedFilter),
                style: TextStyle(
                  color: isFiltered ? AppColors.primary : Colors.white70,
                  fontSize: 13,
                  fontWeight: isFiltered ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                color: isFiltered ? AppColors.primary : Colors.white54,
                size: 20,
              ),
            ],
          ),
        ),
        itemBuilder: (context) => [
          _buildPopupFilterItem(
            key: 'all',
            label: '全部纪要',
            count: _tasks.length,
            icon: Icons.all_inbox_rounded,
          ),
          _buildPopupFilterItem(
            key: 'live',
            label: '实时会议',
            count: liveCount,
            icon: Icons.mic_rounded,
            iconColor: AppColors.primary,
          ),
          _buildPopupFilterItem(
            key: 'imported',
            label: '导入音频',
            count: importedCount,
            icon: Icons.audio_file_rounded,
            iconColor: AppColors.speakerPalette[2].color,
          ),
          _buildPopupFilterItem(
            key: 'audio_missing',
            label: '音频已删',
            count: missingCount,
            icon: Icons.warning_amber_rounded,
            iconColor: Colors.orangeAccent,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildPopupFilterItem({
    required String key,
    required String label,
    required int count,
    required IconData icon,
    Color? iconColor,
  }) {
    final isSelected = _selectedFilter == key;
    return PopupMenuItem<String>(
      value: key,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: isSelected ? AppColors.primary : (iconColor ?? Colors.white70),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary.withValues(alpha: 0.2) : Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: isSelected ? AppColors.primary : Colors.grey,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (isSelected) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_rounded, size: 16, color: AppColors.primary),
          ],
        ],
      ),
    );
  }

  String _getFilterLabel(String key) {
    switch (key) {
      case 'live':
        return '实时会议';
      case 'imported':
        return '导入音频';
      case 'audio_missing':
        return '音频已删';
      case 'all':
      default:
        return '筛选';
    }
  }

  Widget _buildEmptyState() {
    final hasActiveFilterOrSearch = _selectedFilter != 'all' || _searchQuery.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Icon(
                hasActiveFilterOrSearch ? Icons.search_off_rounded : Icons.notes_rounded,
                size: 46,
                color: AppColors.primary.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hasActiveFilterOrSearch ? '没有找到符合条件的纪要记录' : '暂无符合条件的纪要记录',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              hasActiveFilterOrSearch
                  ? '可以尝试清除搜索关键词或重置筛选类别'
                  : '点击右下角按钮导入外部音频，或切换到实时会议开启现场录制',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            if (hasActiveFilterOrSearch)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                label: const Text('重置筛选与搜索'),
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                    _selectedFilter = 'all';
                    _ftsMatchedTaskIds = {};
                  });
                },
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
          ],
        ),
      ),
    );
  }

  String _formatOverviewDuration(int durationMs) {
    final totalSeconds = durationMs ~/ 1000;
    if (totalSeconds <= 0) return '0 分钟';
    if (totalSeconds < 60) return '$totalSeconds 秒';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '$minutes 分钟';
  }

  String _formatNumber(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万字';
    }
    return '$count 字';
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

  String _formatCreatedAt(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm';
  }

  /// 优雅美化发言人标签行
  Widget _buildSpeakersWidget(List<String> speakers) {
    if (speakers.isEmpty) return const SizedBox.shrink();

    const maxDisplay = 3;
    final displaySpeakers = speakers.take(maxDisplay).toList();
    final remainingCount = speakers.length - maxDisplay;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.people_outline_rounded, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 4),
          const Text('发言人: ', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...displaySpeakers.map((spk) {
                    final speakerColor = AppColors.getSpeakerColor(spk);
                    final color = speakerColor.color;
                    return Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: color.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        spk,
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
                  if (remainingCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '+$remainingCount人',
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(
    MeetingTask task,
    TaskSummaryInfo? summary, {
    required bool isGridCard,
    required bool isCompact,
  }) {
    final isLive = task.sourceType == TaskSourceType.liveMeeting;
    final hasAudio = summary?.isAudioFileExists ?? (task.audioPath.isNotEmpty && File(task.audioPath).existsSync());
    final speakers = summary?.speakers ?? [];
    final wordCount = summary?.totalWordCount ?? 0;
    final segCount = summary?.segmentCount ?? 0;
    final snippet = summary?.firstSnippet ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SyncPlayerScreen(task: task),
            ),
          );
          _loadAllTasks();
        },
        child: Container(
          padding: EdgeInsets.all(isCompact ? 12 : 14),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部标题与快捷操作
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(isCompact ? 6 : 7),
                    decoration: BoxDecoration(
                      color: (isLive ? AppColors.primary : AppColors.speakerPalette[2].color)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isLive ? Icons.mic_rounded : Icons.audio_file_rounded,
                      color: isLive ? AppColors.primary : AppColors.speakerPalette[2].color,
                      size: isCompact ? 16 : 18,
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
                            fontSize: isCompact ? 14 : 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${isLive ? "实时会议" : "外部音频"} · ${_formatCreatedAt(task.createdAt)}',
                          style: TextStyle(color: context.textGrey, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  _buildTaskQuickMenu(task, hasAudio),
                ],
              ),
              SizedBox(height: isCompact ? 8 : 10),
              // 元数据徽标行
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _buildTag(
                    task.status.label,
                    color: task.status == TaskStatus.completed
                        ? AppColors.emerald
                        : (task.status == TaskStatus.error
                            ? AppColors.rose
                            : (task.status == TaskStatus.paused
                                ? Colors.orangeAccent
                                : AppColors.amber)),
                  ),
                  _buildTag(_formatDuration(task.durationMs)),
                  _buildTag('$wordCount字 · $segCount段'),
                  if (!hasAudio)
                    _buildWarningTag('音频已删')
                  else if (!isCompact)
                    _buildTag('音频就绪', color: AppColors.emerald),
                  // 转写中或排队中：显示快速暂停按钮
                  if ((task.status == TaskStatus.processing || task.status == TaskStatus.queued) && hasAudio)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () async {
                        await TaskQueueService.instance.pauseTask(task.id);
                        await _loadAllTasks();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.8)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.pause_rounded, size: 12, color: Colors.orangeAccent),
                            SizedBox(width: 3),
                            Text(
                              '暂停',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // 已暂停状态：显示继续转写按钮
                  if (task.status == TaskStatus.paused && hasAudio)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () async {
                        await TaskQueueService.instance.resumeTask(task.id);
                        await _loadAllTasks();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.emerald.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.emerald),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded, size: 12, color: AppColors.emerald),
                            SizedBox(width: 3),
                            Text(
                              '继续转写',
                              style: TextStyle(
                                color: AppColors.emerald,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (task.status == TaskStatus.error && hasAudio)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () async {
                        await TaskQueueService.instance.retryTask(task.id);
                        await _loadAllTasks();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.primary),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh_rounded, size: 12, color: AppColors.primary),
                            SizedBox(width: 3),
                            Text(
                              '重新转写',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              _buildSpeakersWidget(speakers),
              if (snippet.isNotEmpty) ...[
                if (isGridCard) const Spacer() else const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: isCompact ? 6 : 7),
                  decoration: BoxDecoration(
                    color: context.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.borderColor.withValues(alpha: 0.7)),
                  ),
                  child: Text(
                    snippet,
                    style: TextStyle(color: context.textSub, fontSize: 12, height: 1.35),
                    maxLines: isGridCard ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片右上角快捷操作菜单
  Widget _buildTaskQuickMenu(MeetingTask task, bool hasAudio) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz_rounded, color: AppColors.textMuted, size: 20),
      color: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.cardBorder),
      ),
      onSelected: (action) async {
        if (action == 'rename') {
          await _renameTask(task);
        } else if (action == 'pause') {
          await TaskQueueService.instance.pauseTask(task.id);
          await _loadAllTasks();
        } else if (action == 'resume') {
          await TaskQueueService.instance.resumeTask(task.id);
          await _loadAllTasks();
        } else if (action == 'copy') {
          final segs = await AppDatabase.instance.getSegmentsForTask(task.id);
          final text = segs.map((s) => '[${s.speakerName ?? s.speakerId}] ${s.text}').join('\n');
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            AppToast.info(context, '全文纪要已复制到剪贴板');
          }
        } else if (action == 'retry' && hasAudio) {
          await _retryTaskWithConfirm(task);
        } else if (action == 'delete') {
          await _deleteTaskWithConfirm(task);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 17, color: Colors.white70),
              SizedBox(width: 8),
              Text('重命名标题', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        if (hasAudio && (task.status == TaskStatus.processing || task.status == TaskStatus.queued))
          const PopupMenuItem(
            value: 'pause',
            child: Row(
              children: [
                Icon(Icons.pause_circle_outline_rounded, size: 17, color: Colors.orangeAccent),
                SizedBox(width: 8),
                Text('暂停转写', style: TextStyle(color: Colors.orangeAccent, fontSize: 13)),
              ],
            ),
          ),
        if (hasAudio && task.status == TaskStatus.paused)
          const PopupMenuItem(
            value: 'resume',
            child: Row(
              children: [
                Icon(Icons.play_circle_outline_rounded, size: 17, color: AppColors.emerald),
                SizedBox(width: 8),
                Text('继续转写 (断点恢复)', style: TextStyle(color: AppColors.emerald, fontSize: 13)),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 17, color: Colors.white70),
              SizedBox(width: 8),
              Text('一键复制全文', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        if (hasAudio)
          const PopupMenuItem(
            value: 'retry',
            child: Row(
              children: [
                Icon(Icons.refresh_rounded, size: 17, color: AppColors.primary),
                SizedBox(width: 8),
                Text('重新识别音频', style: TextStyle(color: AppColors.primary, fontSize: 13)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 17, color: AppColors.rose),
              SizedBox(width: 8),
              Text('删除此纪要', style: TextStyle(color: AppColors.rose, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTag(String text, {Color color = AppColors.textSecondary}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildWarningTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.orangeAccent, fontSize: 10.5, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildQueueProgressBanner(TaskProgressEvent progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.14),
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
              if (widget.onNavigateToBatch != null)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: widget.onNavigateToBatch,
                  child: const Text('查看队列 >', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              const SizedBox(width: 8),
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
