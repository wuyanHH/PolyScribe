import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../services/export_center_service.dart';
import '../../services/sync_play_controller.dart';

/// 音字同步播放详情页
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

  @override
  void initState() {
    super.initState();
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
      final targetOffset = state.activeSegmentIndex * 130.0;
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
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
                        task: widget.task,
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

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          widget.task.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: '生产力导出中心',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _showExportDialog,
          ),
          IconButton(
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
        ],
      ),
      body: Column(
        children: [
          if (_isSearching) _buildSearchBar(),
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

                        return _buildSegmentCard(seg, index, isActive, speakerColor);
                      },
                    ),
            ),
          ),
          _buildBottomPlayerBar(state),
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
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _searchResults.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final hit = _searchResults[idx];
                  return ActionChip(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.2),
                    label: Text(
                      '${hit.speakerName ?? hit.speakerId} (${_formatTime(hit.startMs)})',
                      style: const TextStyle(fontSize: 11, color: AppColors.primary),
                    ),
                    onPressed: () {
                      _controller.seek(hit.startMs);
                    },
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 段落卡片 (带 6 角色专属高对比度色彩)
  Widget _buildSegmentCard(
    TranscriptSegment seg,
    int index,
    bool isActive,
    SpeakerColor speakerColor,
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
        onTap: () => _controller.seekToSegment(index),
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
