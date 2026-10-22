import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../services/export_center_service.dart';
import '../../services/sync_play_controller.dart';

/// 音字同步播放与纪要详情页
class SyncPlayerScreen extends StatefulWidget {
  final MeetingTask task;

  const SyncPlayerScreen({super.key, required this.task});

  @override
  State<SyncPlayerScreen> createState() => _SyncPlayerScreenState();
}

class _SyncPlayerScreenState extends State<SyncPlayerScreen> {
  late final SyncPlayController _controller;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  List<TranscriptSegment> _searchResults = [];
  bool _isSearching = false;
  String _currentTitle = '';

  @override
  void initState() {
    super.initState();
    _currentTitle = widget.task.title;
    _controller = SyncPlayController();
    _loadSegments();
    _controller.addListener(_onPlayerStateChanged);
  }

  Future<void> _loadSegments() async {
    final segments = await AppDatabase.instance.getSegmentsForTask(widget.task.id);
    _controller.loadTask(
      audioPath: widget.task.audioPath,
      segments: segments,
    );
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    final state = _controller.state;
    // 自动居中滚动 (仅在用户未主动触摸/滑动屏幕时触发)
    if (!state.isUserTouching && state.activeSegmentIndex >= 0 && _scrollController.hasClients) {
      _scrollToIndex(state.activeSegmentIndex);
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    final targetOffset = index * 120.0;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
      });
      return;
    }
    final results = await AppDatabase.instance.searchSegments(query.trim());
    setState(() {
      _searchResults = results.where((s) => s.taskId == widget.task.id).toList();
    });
  }

  /// 点击搜索结果或段落，执行平滑滚动并让音频跳转播放
  void _jumpToSegment(TranscriptSegment target) {
    final index = _controller.segments.indexWhere((s) => s.id == target.id || s.startMs == target.startMs);
    if (index >= 0) {
      _scrollToIndex(index);
    }
    _controller.seek(target.startMs);
  }

  /// 确认删除纪要弹窗
  Future<void> _confirmDeleteTask() async {
    final hasAudio = _controller.isAudioAvailable;
    bool deleteLocalAudio = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('删除纪要确认', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '您确定要彻底删除该纪要记录吗？此操作将清除所有发言段落与全文索引。',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              if (hasAudio) ...[
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteLocalAudio,
                  activeColor: Colors.redAccent,
                  title: const Text(
                    '同时删除本地音频源文件',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: Text(
                    widget.task.audioPath,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: (val) {
                    setDialogState(() {
                      deleteLocalAudio = val ?? false;
                    });
                  },
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('彻底删除', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      await AppDatabase.instance.deleteTask(widget.task.id, deleteAudioFile: deleteLocalAudio);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('纪要记录已成功删除')),
        );
        Navigator.pop(context, true);
      }
    }
  }

  /// 重命名纪要标题
  Future<void> _renameTitle() async {
    final textController = TextEditingController(text: _currentTitle);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('重命名会议纪要', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty && newTitle != _currentTitle) {
      await AppDatabase.instance.updateTaskTitle(widget.task.id, newTitle);
      setState(() {
        _currentTitle = newTitle;
      });
    }
  }

  void _showExportDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '多格式生产力导出中心',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                ),
                const SizedBox(height: 12),
                ...ExportFormat.values.map((format) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined, color: AppColors.primary),
                    title: Text(format.label, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    trailing: const Icon(Icons.copy_rounded, size: 18, color: Colors.grey),
                    onTap: () {
                      final content = ExportCenterService.formatContent(
                        task: widget.task.copyWith(title: _currentTitle),
                        segments: _controller.segments,
                        format: format,
                      );
                      Clipboard.setData(ClipboardData(text: content));
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${format.label} 内容已复制到剪贴板')),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlayerStateChanged);
    _controller.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final segments = _controller.segments;
    final isAudioAvailable = _controller.isAudioAvailable;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          _currentTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '生产力导出',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _showExportDialog,
          ),
          IconButton(
            tooltip: _isSearching ? '收起搜索' : '纪要内搜索',
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchResults.clear();
                  _searchController.clear();
                }
              });
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: AppColors.surface,
            onSelected: (value) {
              if (value == 'rename') {
                _renameTitle();
              } else if (value == 'delete') {
                _confirmDeleteTask();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'rename',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18, color: Colors.white70),
                    SizedBox(width: 8),
                    Text('重命名纪要', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('删除此纪要', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. 若音频缺失，置顶提示黄色警告横幅
          if (!isAudioAvailable) _buildAudioMissingBanner(),

          // 2. 纪要内搜索栏
          if (_isSearching) _buildSearchBar(),

          // 3. 段落气泡列表
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  _controller.setUserTouching(true);
                } else if (notification is ScrollEndNotification) {
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted) _controller.setUserTouching(false);
                  });
                }
                return false;
              },
              child: segments.isEmpty
                  ? const Center(child: Text('暂无转写段落', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: segments.length,
                      itemBuilder: (context, index) {
                        final seg = segments[index];
                        final isActive = state.activeSegmentIndex == index;
                        final speakerColor = AppColors.getSpeakerColor(seg.speakerId);

                        return _buildSegmentCard(seg, index, isActive, speakerColor, isAudioAvailable);
                      },
                    ),
            ),
          ),

          // 4. 底部播放控制条或纯文本模式底栏
          if (isAudioAvailable)
            _buildBottomPlayerBar(state)
          else
            _buildReadOnlyBottomBar(segments.length),
        ],
      ),
    );
  }

  /// 音频源文件已丢失时的警示横幅
  Widget _buildAudioMissingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.withValues(alpha: 0.15),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orangeAccent, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '音频源文件已被移动或从本地移除，当前处于纪要文本离线阅读模式',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框与结果快速跳转条
  Widget _buildSearchBar() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '全文拼音与关键词检索 (FTS5)...',
              hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: AppColors.primary, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        _performSearch('');
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.background,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: _performSearch,
          ),
          if (_searchResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _searchResults.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final hit = _searchResults[idx];
                  return ActionChip(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.2),
                    side: const BorderSide(color: AppColors.primary, width: 0.8),
                    label: Text(
                      '${hit.speakerName ?? hit.speakerId} (${_formatTime(hit.startMs)})',
                      style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _jumpToSegment(hit),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 段落卡片 (轻触卡片执行音频精准 Seek 跳转)
  Widget _buildSegmentCard(
    TranscriptSegment seg,
    int index,
    bool isActive,
    SpeakerColor speakerColor,
    bool isAudioAvailable,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isActive ? speakerColor.surfaceColor : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? speakerColor.color : AppColors.surfaceLight,
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _scrollToIndex(index);
          _controller.seekToSegment(index);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
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
                    '${_formatTime(seg.startMs)} - ${_formatTime(seg.endMs)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  if (isAudioAvailable) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.volume_up_outlined, size: 14, color: Colors.grey),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                seg.text,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: isActive ? Colors.white : Colors.white70,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 纯纪要只读底栏 (当音频文件不存在时)
  Widget _buildReadOnlyBottomBar(int segmentCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppColors.surface,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Icon(Icons.menu_book_rounded, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            Text(
              '共 $segmentCount 个段落 • 轻触卡片定位阅读',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 16, color: AppColors.primary),
              label: const Text('复制全文', style: TextStyle(color: AppColors.primary, fontSize: 12)),
              onPressed: () {
                final text = _controller.segments.map((s) => '${s.speakerName ?? s.speakerId}: ${s.text}').join('\n');
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('全文纪要已复制到剪贴板')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 底部播放器控制器
  Widget _buildBottomPlayerBar(SyncPlayerState state) {
    final progress = state.durationMs > 0
        ? (state.positionMs / state.durationMs).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度滑块
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: Colors.white24,
                thumbColor: AppColors.primary,
              ),
              child: Slider(
                value: progress,
                onChanged: (val) {
                  final targetMs = (val * state.durationMs).toInt();
                  _controller.seek(targetMs);
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(state.positionMs),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Text(
                  _formatTime(state.durationMs),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 倍速切换
                TextButton(
                  onPressed: () {
                    final rates = [1.0, 1.25, 1.5, 2.0];
                    final curIdx = rates.indexOf(state.playbackRate);
                    final nextRate = rates[(curIdx + 1) % rates.length];
                    _controller.setPlaybackRate(nextRate);
                  },
                  child: Text(
                    '${state.playbackRate}x',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 16),
                // 快退 5 秒
                IconButton(
                  icon: const Icon(Icons.replay_5_rounded, color: Colors.white),
                  onPressed: () => _controller.seek(state.positionMs - 5000),
                ),
                const SizedBox(width: 8),
                // 播放/暂停大按钮
                InkWell(
                  onTap: _controller.togglePlay,
                  borderRadius: BorderRadius.circular(28),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 快进 5 秒
                IconButton(
                  icon: const Icon(Icons.forward_5_rounded, color: Colors.white),
                  onPressed: () => _controller.seek(state.positionMs + 5000),
                ),
                const SizedBox(width: 40),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
