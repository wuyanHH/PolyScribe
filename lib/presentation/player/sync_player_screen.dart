import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../data/models/voice_print.dart';
import '../../engine/text/transcript_context_optimizer.dart';
import '../../services/export_center_service.dart';
import '../../services/sync_play_controller.dart';
import '../../services/task_queue_service.dart';

/// 同一发言人连续发言聚合组 (用于提升播放页布局密度与对话流阅读体验)
class _SpeakerUtteranceGroup {
  final String speakerId;
  final String speakerName;
  final int startMs;
  final int endMs;
  final List<TranscriptSegment> segments;
  final List<int> originalIndices;

  _SpeakerUtteranceGroup({
    required this.speakerId,
    required this.speakerName,
    required this.startMs,
    required this.endMs,
    required this.segments,
    required this.originalIndices,
  });
}

/// 音字同步播放与纪要详情页 (桌面双栏洞察工作台 + 发言人实名入库 + 段落校对 + 多格式本地导出)
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
  final Map<int, GlobalKey> _itemKeys = {};
  List<TranscriptSegment> _searchResults = [];
  bool _isSearching = false;
  bool _isLoading = true;
  String _currentTitle = '';
  String? _selectedSpeakerFilter; // null 表示查看全部发言人
  bool _isGroupedView = true; // 是否开启会话流聚合模式 (按发言人将连续发言整合归并在同一个气泡组，大幅提升显示效率)

  /// 自动滚动与跟读吸附状态管理
  bool _autoScrollEnabled = true; // 是否开启随播放进度自动吸附
  bool _userScrolledAway = false; // 用户是否主动向上/向下翻阅历史对话
  int _lastAutoScrolledIndex = -1; // 上次自动滚动的段落序号，防止同一段重复微颤
  Timer? _searchDebounceTimer;
  int _lastUiRenderTimestamp = 0;

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
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    final state = _controller.state;
    // 自动居中滚动 (仅在跟读开启、用户未主动离开当前视线且未处于角色过滤状态时触发)
    if (_autoScrollEnabled &&
        !_userScrolledAway &&
        _selectedSpeakerFilter == null &&
        state.activeSegmentIndex >= 0 &&
        _scrollController.hasClients) {
      _scrollToIndex(state.activeSegmentIndex);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    // 性能优化：若处于同一段落内且非段落跨越，将高频播放位置引起的全页面重建平滑节流至 >= 80ms 一次
    if (state.activeSegmentIndex != _lastAutoScrolledIndex ||
        now - _lastUiRenderTimestamp >= 80) {
      _lastUiRenderTimestamp = now;
      setState(() {});
    }
  }

  /// 精准平滑自适应居中滚动，确保当前段落呈现在视口 35% 黄金线上，上方留白看前文，绝不超出屏幕
  void _scrollToIndex(int index, {bool force = false}) {
    if (!_scrollController.hasClients) return;
    if (!_autoScrollEnabled && !force) return;
    if (_userScrolledAway && !force) return;
    if (!force && _lastAutoScrolledIndex == index) return;
    _lastAutoScrolledIndex = index;

    final key = _itemKeys[index];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.35, // 黄金分割视线 (35% 视口高度)，上方留白展示前一句对话，绝不出界
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } else {
      // 降级使用动态视口高度估算，保证绝不顶出视口顶部或沉入底部遮盖区
      final total = _controller.segments.length;
      if (total > 0 && _scrollController.position.hasContentDimensions) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        final viewportHeight = _scrollController.position.viewportDimension;
        final avgHeight = (maxExtent + viewportHeight) / total;
        final targetOffset = (index * avgHeight) - (viewportHeight * 0.35);
        _scrollController.animateTo(
          targetOffset.clamp(0.0, maxExtent),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  /// 纪要内全文检索 (250ms 防抖收敛与防并发竞态)
  void _performSearch(String query) {
    _searchDebounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = [];
      });
      return;
    }

    _searchDebounceTimer = Timer(const Duration(milliseconds: 250), () async {
      final results = await AppDatabase.instance.searchSegments(trimmed);
      if (mounted && _searchController.text.trim() == trimmed) {
        setState(() {
          _searchResults = results.where((s) => s.taskId == widget.task.id).toList();
        });
      }
    });
  }

  /// 点击搜索结果或段落，让视线重新锁定并开始播放
  void _jumpToSegment(TranscriptSegment target) {
    if (_selectedSpeakerFilter != null && _selectedSpeakerFilter != target.speakerId) {
      setState(() => _selectedSpeakerFilter = null);
    }
    final index = _controller.segments.indexWhere((s) => s.id == target.id || s.startMs == target.startMs);
    if (index >= 0) {
      // 用户主动点击段落，视为重新对齐播放视线
      setState(() {
        _userScrolledAway = false;
        _autoScrollEnabled = true;
      });
      _scrollToIndex(index, force: true);
    }
    _controller.seek(target.startMs);
  }

  /// 修改发言人姓名（支持一键同步沉淀到实名声纹特征库）
  Future<void> _editSpeakerRoleName(String speakerId, String currentName) async {
    final nameCtrl = TextEditingController(text: currentName);
    bool saveToVoiceprintVault = true;
    bool? confirmed;
    String newName = '';

    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppColors.surfaceElevated,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.record_voice_over_rounded, color: AppColors.primary, size: 22),
                const SizedBox(width: 10),
                Text('标注发言人姓名 ($speakerId)', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '修改后，本篇纪要中该角色的所有发言段落将统一更新为此姓名。',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '输入真实姓名或职位，如：张总 / 产品经理',
                    hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: saveToVoiceprintVault,
                  activeColor: AppColors.primary,
                  title: const Text(
                    '同步沉淀至「实名声纹特征库」',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    '后续新会议自动比对声纹向量并直呼其名',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  onChanged: (v) => setDialogState(() => saveToVoiceprintVault = v ?? true),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存应用', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
      newName = nameCtrl.text.trim();
    } finally {
      nameCtrl.dispose();
    }
    if (confirmed == true && newName.isNotEmpty && newName != currentName) {
      // 1. 【性能关键：零延迟乐观更新】内存与状态毫秒级瞬时刷新，绝对不重载音频播放器
      _controller.updateSpeakerName(speakerId, newName);
      setState(() {});

      if (mounted) {
        AppToast.success(
          context,
          saveToVoiceprintVault
              ? '已将 $speakerId 更新为「$newName」并同步沉淀至实名声纹库'
              : '已将本篇纪要中的 $speakerId 更新为「$newName」',
        );
      }

      // 2. 异步在后台持久化落库与更新声纹特征库，绝不阻塞 UI
      unawaited(() async {
        try {
          await AppDatabase.instance.updateSpeakerNameForTask(widget.task.id, speakerId, newName);

          if (saveToVoiceprintVault) {
            final now = DateTime.now().millisecondsSinceEpoch;
            final existingPrints = await AppDatabase.instance.getAllVoicePrints();
            final matched = existingPrints.where((p) => p.personName == newName).toList();
            if (matched.isNotEmpty) {
              final current = matched.first;
              await AppDatabase.instance.saveVoicePrint(
                VoicePrint(
                  id: current.id,
                  personName: newName,
                  embedding: current.embedding,
                  sampleCount: current.sampleCount + 1,
                  createdAt: current.createdAt,
                  updatedAt: now,
                ),
              );
            } else {
              await AppDatabase.instance.saveVoicePrint(
                VoicePrint(
                  id: 'vp_$now',
                  personName: newName,
                  embedding: Float32List(192),
                  sampleCount: 1,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
            }
          }
        } catch (e) {
          debugPrint('[SyncPlayerScreen] 异步持久化发言人姓名异常: $e');
        }
      }());
    }
  }

  /// 智能整合上下文与同发言人碎片断句 (解决停顿导致的断句过碎、一句话拆成两半)
  Future<void> _optimizeContextAndMerge() async {
    final all = _controller.segments;
    if (all.length <= 1) {
      AppToast.info(context, '当前纪要段落较少，无需额外整合优化');
      return;
    }

    final preview = TranscriptContextOptimizer.optimize(all);
    if (preview.mergedCount == 0) {
      AppToast.info(context, '当前上下文已处于最佳状态，未检测到需合并的碎片断句');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.auto_fix_high_rounded, color: AppColors.primary, size: 22),
            SizedBox(width: 10),
            Text('智能整合上下文与断句', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '检测到当前纪要中存在 ${preview.mergedCount} 处由于呼吸停顿被切开的同一发言人碎片短句。',
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• 原始段落：${preview.originalCount} 段', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text('• 优化后段落：${preview.optimizedCount} 段 (合并 ${preview.mergedCount} 处)', style: const TextStyle(color: AppColors.emerald, fontSize: 12.5, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('• 智能连缀标点与语流，保留精准音频时间戳与跳播定位', style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '确认立即对本篇纪要执行上下文整合优化吗？',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
            icon: const Icon(Icons.auto_awesome, size: 16),
            onPressed: () => Navigator.pop(ctx, true),
            label: const Text('立即整合优化', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        final saved = await AppDatabase.instance.replaceSegmentsForTask(widget.task.id, preview.segments);
        _controller.updateSegments(saved);
        if (mounted) {
          AppToast.success(context, '已成功优化整合上下文，合并了 ${preview.mergedCount} 处碎片断句！');
        }
      } catch (e) {
        if (mounted) {
          AppToast.error(context, '整合优化失败: $e');
        }
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  /// 二次校对编辑单条段落文本
  Future<void> _editSegmentText(TranscriptSegment seg) async {
    if (seg.id == null) return;
    final textCtrl = TextEditingController(text: seg.text);
    String? newText;
    try {
      newText = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.edit_note_rounded, color: AppColors.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '校对段落文本 (${_formatTime(seg.startMs)})',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: TextField(
              controller: textCtrl,
              autofocus: true,
              maxLines: 5,
              minLines: 2,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, textCtrl.text.trim()),
              child: const Text('保存校对'),
            ),
          ],
        ),
      );
    } finally {
      textCtrl.dispose();
    }

    if (newText != null && newText.isNotEmpty && newText != seg.text) {
      final safeText = newText;
      // 内存立即响应
      _controller.updateSegmentText(seg.id!, safeText);
      setState(() {});

      if (mounted) {
        AppToast.success(context, '段落文本已校对更新');
      }

      unawaited(() async {
        try {
          await AppDatabase.instance.updateSegmentText(seg.id!, widget.task.id, safeText);
        } catch (e) {
          debugPrint('[SyncPlayerScreen] 异步保存段落文本异常: $e');
        }
      }());
    }
  }

  /// 确认删除纪要弹窗
  Future<void> _confirmDeleteTask() async {
    final hasAudio = _controller.isAudioAvailable;
    bool deleteLocalAudio = false;

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
              Text('删除纪要确认', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '您确定要彻底删除该纪要记录吗？此操作将清除所有发言段落与全文索引。',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              if (hasAudio) ...[
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteLocalAudio,
                  activeColor: AppColors.rose,
                  title: const Text(
                    '同时删除本地音频源文件',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: Text(
                    widget.task.audioPath,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
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
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.rose, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('彻底删除'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      // 停止播放并通知队列如果正在处理则立即取消中断并流转
      _controller.pause();
      await TaskQueueService.instance.cancelOrDeleteTask(widget.task.id, deleteAudioFile: deleteLocalAudio);
      if (mounted) {
        AppToast.info(context, '纪要记录已成功删除');
        Navigator.pop(context, true);
      }
    }
  }

  /// 确认重新转写纪要弹窗 (清空旧数据并重新提交至转写队列)
  Future<void> _confirmRetranscribeTask() async {
    if (!_controller.isAudioAvailable) {
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
            Text('重新生成纪要', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '重新转写将清空当前所有发言段落与人工校对内容，并使用当前最优的神经网络 VAD 切句与语音模型对音频源文件进行全面重新识别。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '此操作适合在模型升级、切句优化或初次转写不理想时使用。确定要重新生成吗？',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
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
            label: const Text('开始重新生成', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _controller.pause();
      await TaskQueueService.instance.retryTask(widget.task.id);
      if (mounted) {
        AppToast.success(context, '已重新加入转写队列，正在后台重新生成纪要...');
        Navigator.pop(context, true);
      }
    }
  }

  /// 重命名纪要标题
  Future<void> _renameTitle() async {
    final textController = TextEditingController(text: _currentTitle);
    String? newTitle;
    try {
      newTitle = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('重命名会议纪要', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: textController,
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
              onPressed: () => Navigator.pop(ctx, textController.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      textController.dispose();
    }

    if (newTitle != null && newTitle.isNotEmpty && newTitle != _currentTitle) {
      final safeTitle = newTitle;
      await AppDatabase.instance.updateTaskTitle(widget.task.id, safeTitle);
      setState(() {
        _currentTitle = safeTitle;
      });
    }
  }

  /// 导出文件到本地磁盘或复制剪贴板
  void _showExportDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.ios_share_rounded, color: AppColors.primary, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '多格式生产力导出中心',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '支持一键复制内容到剪贴板，或直接另存为本地标准文档与字幕文件',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                ...ExportFormat.values.map((format) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.description_outlined, color: AppColors.primary, size: 19),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            format.label,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.copy_rounded, size: 14, color: AppColors.textSecondary),
                          label: const Text('复制', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                          onPressed: () {
                            final content = ExportCenterService.formatContent(
                              task: widget.task.copyWith(title: _currentTitle),
                              segments: _controller.segments,
                              format: format,
                            );
                            Clipboard.setData(ClipboardData(text: content));
                            Navigator.pop(ctx);
                            AppToast.success(context, '${format.label} 已复制到剪贴板');
                          },
                        ),
                        const SizedBox(width: 6),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary.withValues(alpha: 0.18),
                            foregroundColor: AppColors.primary,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.save_alt_rounded, size: 14),
                          label: const Text('存文件', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _exportToFileOnDisk(format);
                          },
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportToFileOnDisk(ExportFormat format) async {
    try {
      String? targetDir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出保存目录');
      if (targetDir == null || targetDir.isEmpty) {
        final docDir = await getApplicationDocumentsDirectory();
        targetDir = docDir.path;
      }
      final savedFile = await ExportCenterService.exportToFile(
        outputDir: targetDir,
        task: widget.task.copyWith(title: _currentTitle),
        segments: _controller.segments,
        format: format,
      );
      if (mounted) {
        AppToast.success(
          context,
          '已成功导出至: ${savedFile.path}',
          duration: const Duration(seconds: 4),
          action: Platform.isWindows
              ? SnackBarAction(
                  label: '打开',
                  textColor: AppColors.primary,
                  onPressed: () {
                    Process.run('explorer.exe', ['/select,', savedFile.path]);
                  },
                )
              : null,
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '导出文件失败: $e');
      }
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _controller.removeListener(_onPlayerStateChanged);
    _controller.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final allSegments = _controller.segments;
    final visibleSegments = _selectedSpeakerFilter == null
        ? allSegments
        : allSegments.where((s) => s.speakerId == _selectedSpeakerFilter).toList();
    final isAudioAvailable = _controller.isAudioAvailable;
    final isWideDesktop = MediaQuery.of(context).size.width >= 960;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _renameTitle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _currentTitle,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.edit_outlined, size: 15, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
        actions: [
          // 跟读吸附快捷开关
          if (isAudioAvailable)
            IconButton(
              tooltip: _autoScrollEnabled ? '跟读吸附已开启 (点击暂停吸附，自由翻阅)' : '跟读吸附已暂停 (点击恢复自动跟随)',
              icon: Icon(
                _autoScrollEnabled ? Icons.sync_rounded : Icons.sync_disabled_rounded,
                color: _autoScrollEnabled ? AppColors.primary : AppColors.textMuted,
                size: 20,
              ),
              onPressed: () {
                setState(() {
                  _autoScrollEnabled = !_autoScrollEnabled;
                  if (_autoScrollEnabled) {
                    _userScrolledAway = false;
                  }
                });
                if (_autoScrollEnabled && state.activeSegmentIndex >= 0) {
                  _scrollToIndex(state.activeSegmentIndex, force: true);
                }
              },
            ),
          // 会话流聚合 / 逐句卡片 视图切换
          IconButton(
            tooltip: _isGroupedView ? '当前为：会话流聚合模式 (高密度，点击切换逐句卡片)' : '当前为：逐句卡片模式 (点击切换会话流聚合)',
            icon: Icon(
              _isGroupedView ? Icons.chat_bubble_outline_rounded : Icons.view_stream_rounded,
              size: 20,
              color: _isGroupedView ? AppColors.primary : AppColors.textMuted,
            ),
            onPressed: () {
              setState(() {
                _isGroupedView = !_isGroupedView;
              });
            },
          ),
          // 智能整合上下文与断句快捷按钮
          IconButton(
            tooltip: '智能整合上下文与断句 (合并同一发言人碎片短句)',
            icon: const Icon(Icons.auto_fix_high_rounded, color: AppColors.primary, size: 20),
            onPressed: _optimizeContextAndMerge,
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('导出', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            onPressed: _showExportDialog,
          ),
          IconButton(
            tooltip: _isSearching ? '收起搜索' : '纪要内搜索',
            icon: Icon(_isSearching ? Icons.close_rounded : Icons.search_rounded),
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
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.cardBorder),
            ),
            onSelected: (value) {
              if (value == 'rename') {
                _renameTitle();
              } else if (value == 'optimize_context') {
                _optimizeContextAndMerge();
              } else if (value == 'retranscribe') {
                _confirmRetranscribeTask();
              } else if (value == 'copy_all') {
                final text = allSegments.map((s) => '[${s.speakerName ?? s.speakerId}] ${s.text}').join('\n');
                Clipboard.setData(ClipboardData(text: text));
                AppToast.info(context, '全文纪要已复制到剪贴板');
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
                value: 'optimize_context',
                child: Row(
                  children: [
                    Icon(Icons.auto_fix_high_rounded, size: 18, color: AppColors.primary),
                    SizedBox(width: 8),
                    Text('智能整合上下文与断句', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              if (isAudioAvailable) ...[
                const PopupMenuItem(
                  value: 'retranscribe',
                  child: Row(
                    children: [
                      Icon(Icons.refresh_rounded, size: 18, color: AppColors.primary),
                      SizedBox(width: 8),
                      Text('重新转写此纪要', style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              const PopupMenuItem(
                value: 'copy_all',
                child: Row(
                  children: [
                    Icon(Icons.copy_all_rounded, size: 18, color: Colors.white70),
                    SizedBox(width: 8),
                    Text('复制全部文本', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: AppColors.rose),
                    SizedBox(width: 8),
                    Text('删除此纪要', style: TextStyle(color: AppColors.rose, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Divider(height: 1, color: AppColors.cardBorder),
                if (!isAudioAvailable) _buildAudioMissingBanner(),
                if (_isSearching) _buildSearchBar(),
                if (!isWideDesktop && allSegments.isNotEmpty) _buildCompactSpeakerFilterBar(allSegments),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左侧/主区：段落流 (支持自由翻阅历史与平滑吸附定位)
                      Expanded(
                        flex: 3,
                        child: Stack(
                          children: [
                            NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                if (notification is UserScrollNotification) {
                                  if (notification.direction != ScrollDirection.idle) {
                                    // 用户主动滑动鼠标或触控翻阅历史，脱钩自动吸附，绝不粗暴强拉回！
                                    if (!_userScrolledAway) {
                                      setState(() {
                                        _userScrolledAway = true;
                                      });
                                    }
                                  }
                                }
                                return false;
                              },
                              child: visibleSegments.isEmpty
                                  ? const Center(
                                      child: Text('暂无转写段落', style: TextStyle(color: AppColors.textMuted)),
                                    )
                                  : _isGroupedView
                                      ? Builder(builder: (context) {
                                          final groups = _groupSegments(visibleSegments, allSegments);
                                          return ListView.builder(
                                            controller: _scrollController,
                                            padding: EdgeInsets.fromLTRB(
                                              MediaQuery.of(context).size.width < 600 ? 12 : 20,
                                              12,
                                              MediaQuery.of(context).size.width < 600 ? 12 : 20,
                                              48,
                                            ),
                                            itemCount: groups.length,
                                            itemBuilder: (context, idx) {
                                              return _buildGroupedUtteranceCard(
                                                groups[idx],
                                                state,
                                                isAudioAvailable,
                                              );
                                            },
                                          );
                                        })
                                      : ListView.builder(
                                          controller: _scrollController,
                                          padding: EdgeInsets.fromLTRB(
                                            MediaQuery.of(context).size.width < 600 ? 12 : 20,
                                            12,
                                            MediaQuery.of(context).size.width < 600 ? 12 : 20,
                                            48,
                                          ),
                                          itemCount: visibleSegments.length,
                                          itemBuilder: (context, idx) {
                                            final seg = visibleSegments[idx];
                                            final realIndex = allSegments.indexOf(seg);
                                            final isActive = state.activeSegmentIndex == realIndex;
                                            final speakerColor = AppColors.getSpeakerColor(seg.speakerId);

                                            return _buildSegmentCard(
                                              seg,
                                              realIndex,
                                              isActive,
                                              speakerColor,
                                              isAudioAvailable,
                                            );
                                          },
                                        ),
                            ),
                            // 用户翻阅历史离开当前行时，右下角优雅悬浮「回到播放行」药丸提示
                            if (_userScrolledAway && isAudioAvailable && state.activeSegmentIndex >= 0)
                              Positioned(
                                right: 20,
                                bottom: 16,
                                child: Material(
                                  elevation: 8,
                                  shadowColor: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                  color: AppColors.surfaceElevated,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(20),
                                    onTap: () {
                                      setState(() {
                                        _userScrolledAway = false;
                                        _autoScrollEnabled = true;
                                      });
                                      _scrollToIndex(state.activeSegmentIndex, force: true);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.6)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.arrow_downward_rounded, size: 14, color: AppColors.primary),
                                          const SizedBox(width: 6),
                                          Text(
                                            '回到当前播放 (${_formatTime(state.positionMs)})',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // 桌面宽屏右侧：会议角色统计与声纹标注洞察面板
                      if (isWideDesktop) ...[
                        const VerticalDivider(width: 1, thickness: 1, color: AppColors.cardBorder),
                        SizedBox(
                          width: 320,
                          child: _buildDesktopInsightSidebar(allSegments),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isAudioAvailable)
                  _buildBottomPlayerBar(state, allSegments.length)
                else
                  _buildReadOnlyBottomBar(allSegments.length),
              ],
            ),
    );
  }

  /// 窄屏下顶部角色快速筛选与改名胶囊条
  Widget _buildCompactSpeakerFilterBar(List<TranscriptSegment> allSegments) {
    final speakerMap = <String, String>{};
    for (final s in allSegments) {
      speakerMap[s.speakerId] = s.speakerName ?? AppColors.getSpeakerColor(s.speakerId).defaultRoleName;
    }

    return Container(
      height: 44,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Center(
            child: ChoiceChip(
              label: Text('全部 (${allSegments.length})', style: const TextStyle(fontSize: 11)),
              selected: _selectedSpeakerFilter == null,
              selectedColor: AppColors.primary.withValues(alpha: 0.25),
              onSelected: (_) => setState(() => _selectedSpeakerFilter = null),
            ),
          ),
          const SizedBox(width: 8),
          ...speakerMap.entries.map((entry) {
            final spkId = entry.key;
            final spkName = entry.value;
            final color = AppColors.getSpeakerColor(spkId).color;
            final isSelected = _selectedSpeakerFilter == spkId;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: GestureDetector(
                  onLongPress: () => _editSpeakerRoleName(spkId, spkName),
                  child: ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Text(spkName, style: TextStyle(fontSize: 11, color: isSelected ? Colors.white : color)),
                      ],
                    ),
                    selected: isSelected,
                    selectedColor: color.withValues(alpha: 0.25),
                    onSelected: (v) {
                      setState(() => _selectedSpeakerFilter = v ? spkId : null);
                    },
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// 桌面端右侧会议洞察与发言人声纹标注面板
  Widget _buildDesktopInsightSidebar(List<TranscriptSegment> allSegments) {
    final totalWords = allSegments.fold<int>(0, (acc, s) => acc + s.text.length);
    final speakerStats = <String, _SpeakerStat>{};

    for (final s in allSegments) {
      final existing = speakerStats[s.speakerId];
      final roleName = s.speakerName ?? AppColors.getSpeakerColor(s.speakerId).defaultRoleName;
      if (existing == null) {
        speakerStats[s.speakerId] = _SpeakerStat(
          speakerId: s.speakerId,
          speakerName: roleName,
          segmentCount: 1,
          wordCount: s.text.length,
        );
      } else {
        speakerStats[s.speakerId] = _SpeakerStat(
          speakerId: s.speakerId,
          speakerName: roleName,
          segmentCount: existing.segmentCount + 1,
          wordCount: existing.wordCount + s.text.length,
        );
      }
    }

    return Container(
      color: AppColors.surface,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_outlined, color: AppColors.primary, size: 18),
              SizedBox(width: 8),
              Text(
                '会议数据洞察',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                _buildSidebarMetricRow('总发言段落', '${allSegments.length} 段'),
                const SizedBox(height: 8),
                _buildSidebarMetricRow('总计字数', '$totalWords 字'),
                const SizedBox(height: 8),
                _buildSidebarMetricRow('参会角色数', '${speakerStats.length} 人'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 桌面端专属：智能整合上下文快捷操作卡片
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_fix_high_rounded, color: AppColors.primary, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '智能整合上下文',
                        style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '一键优化断句并归并同角色短语',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _optimizeContextAndMerge,
                  child: const Text('优化断句', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.people_alt_outlined, color: AppColors.emerald, size: 18),
                  SizedBox(width: 8),
                  Text(
                    '参会角色与声纹标注',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (_selectedSpeakerFilter != null)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _selectedSpeakerFilter = null),
                  child: const Text('显示全部', style: TextStyle(fontSize: 11, color: AppColors.primary)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '点击角色过滤发言，点击编辑图标可实名改名并沉淀声纹',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 12),
          ...speakerStats.values.map((stat) {
            final spkColor = AppColors.getSpeakerColor(stat.speakerId);
            final ratio = totalWords > 0 ? (stat.wordCount / totalWords).clamp(0.0, 1.0) : 0.0;
            final isFiltered = _selectedSpeakerFilter == stat.speakerId;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: isFiltered ? spkColor.surfaceColor : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isFiltered ? spkColor.color : AppColors.cardBorder,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  setState(() {
                    _selectedSpeakerFilter = isFiltered ? null : stat.speakerId;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: spkColor.color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              stat.speakerName,
                              style: TextStyle(
                                color: spkColor.color,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: '修改角色姓名并沉淀声纹',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.edit_note_rounded, size: 18, color: AppColors.textSecondary),
                            onPressed: () => _editSpeakerRoleName(stat.speakerId, stat.speakerName),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${stat.segmentCount} 段发言 · ${stat.wordCount} 字',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                          ),
                          Text(
                            '${(ratio * 100).toStringAsFixed(0)}%',
                            style: TextStyle(color: spkColor.color, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 4,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation<Color>(spkColor.color),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildSidebarMetricRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold)),
      ],
    );
  }

  /// 音频源文件已丢失时的警示横幅
  Widget _buildAudioMissingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: '在当前纪要内全文检索关键词 (FTS5)...',
              hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
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
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.cardBorder),
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

  /// 将段落列表按同发言人连续发言聚合为会话组
  List<_SpeakerUtteranceGroup> _groupSegments(
    List<TranscriptSegment> visibleSegments,
    List<TranscriptSegment> allSegments,
  ) {
    if (visibleSegments.isEmpty) return [];

    final List<_SpeakerUtteranceGroup> groups = [];
    _SpeakerUtteranceGroup? currentGroup;

    for (final seg in visibleSegments) {
      final realIndex = allSegments.indexOf(seg);
      final roleName = seg.speakerName ?? AppColors.getSpeakerColor(seg.speakerId).defaultRoleName;

      // 判定同发言人且发音间隔 <= 15 秒，聚合在同一个卡片内
      if (currentGroup != null &&
          currentGroup.speakerId == seg.speakerId &&
          (seg.startMs - currentGroup.endMs) <= 15000) {
        currentGroup.segments.add(seg);
        currentGroup.originalIndices.add(realIndex);
        if (seg.endMs > currentGroup.endMs) {
          final updatedGroup = _SpeakerUtteranceGroup(
            speakerId: currentGroup.speakerId,
            speakerName: roleName,
            startMs: currentGroup.startMs,
            endMs: seg.endMs,
            segments: currentGroup.segments,
            originalIndices: currentGroup.originalIndices,
          );
          groups[groups.length - 1] = updatedGroup;
          currentGroup = updatedGroup;
        }
      } else {
        currentGroup = _SpeakerUtteranceGroup(
          speakerId: seg.speakerId,
          speakerName: roleName,
          startMs: seg.startMs,
          endMs: seg.endMs,
          segments: [seg],
          originalIndices: [realIndex],
        );
        groups.add(currentGroup);
      }
    }

    return groups;
  }

  /// 会话流聚合发言人卡片 (同一发言人的多次发言聚合在一个卡片中，极大提升排版紧凑度与会话感)
  Widget _buildGroupedUtteranceCard(
    _SpeakerUtteranceGroup group,
    SyncPlayerState state,
    bool isAudioAvailable,
  ) {
    final speakerColor = AppColors.getSpeakerColor(group.speakerId);
    final hasActiveSentence = group.originalIndices.contains(state.activeSegmentIndex);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasActiveSentence ? speakerColor.color.withValues(alpha: 0.6) : AppColors.cardBorder,
          width: hasActiveSentence ? 1.2 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 发言人卡片头部：头像 + 姓名 (点击极速改名) + 起止时间 + 句数
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            decoration: BoxDecoration(
              color: speakerColor.color.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
              border: const Border(bottom: BorderSide(color: AppColors.cardBorder, width: 0.6)),
            ),
            child: Row(
              children: [
                // 发言人头像与姓名 (独立点击改名，杜绝手势竞争冲突)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _editSpeakerRoleName(group.speakerId, group.speakerName),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: speakerColor.color.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                            border: Border.all(color: speakerColor.color, width: 1.2),
                          ),
                          child: Center(
                            child: Text(
                              group.speakerName.isNotEmpty ? group.speakerName.characters.first : '?',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: speakerColor.color,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          group.speakerName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: speakerColor.color,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit_outlined,
                          size: 13,
                          color: speakerColor.color.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                // 起止总时间
                Text(
                  '${_formatTime(group.startMs)} - ${_formatTime(group.endMs)}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: AppColors.textMuted),
                ),
                if (group.segments.length > 1) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Text(
                      '${group.segments.length} 句',
                      style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 2. 连续发言句子流 (紧凑、优雅、高可读性)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(group.segments.length, (i) {
                final seg = group.segments[i];
                final realIndex = group.originalIndices[i];
                final isSentenceActive = state.activeSegmentIndex == realIndex;
                final itemKey = _itemKeys.putIfAbsent(realIndex, () => GlobalKey());

                return AnimatedContainer(
                  key: itemKey,
                  duration: const Duration(milliseconds: 180),
                  margin: EdgeInsets.only(bottom: i == group.segments.length - 1 ? 0 : 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSentenceActive
                        ? speakerColor.color.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSentenceActive
                          ? speakerColor.color.withValues(alpha: 0.4)
                          : Colors.transparent,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() {
                        _userScrolledAway = false;
                        _autoScrollEnabled = true;
                      });
                      _controller.seekToSegment(realIndex);
                      _scrollToIndex(realIndex, force: true);
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 当前播放标识 (跳动声波或淡时间)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 8),
                          child: isSentenceActive
                              ? Icon(Icons.graphic_eq_rounded, size: 15, color: speakerColor.color)
                              : Text(
                                  _formatTime(seg.startMs),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                        ),
                        // 文本内容
                        Expanded(
                          child: Text(
                            seg.text,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              color: isSentenceActive
                                  ? Colors.white
                                  : AppColors.textPrimary.withValues(alpha: 0.9),
                              fontWeight: isSentenceActive ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                        // 快捷校对小图标
                        Tooltip(
                          message: '校对修改此句',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => _editSegmentText(seg),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(Icons.edit_note_rounded, size: 16, color: AppColors.textMuted),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// 段落卡片 (轻触卡片执行音频精准 Seek 跳转，点击发言人可改名，点击编辑图标可校对文本)
  Widget _buildSegmentCard(
    TranscriptSegment seg,
    int index,
    bool isActive,
    SpeakerColor speakerColor,
    bool isAudioAvailable,
  ) {
    final roleName = seg.speakerName ?? speakerColor.defaultRoleName;
    final itemKey = _itemKeys.putIfAbsent(index, () => GlobalKey());

    return AnimatedContainer(
      key: itemKey,
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isActive ? speakerColor.surfaceColor : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive ? speakerColor.color : AppColors.cardBorder,
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() {
            _userScrolledAway = false;
            _autoScrollEnabled = true;
          });
          _controller.seekToSegment(index);
          _scrollToIndex(index, force: true);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 角色色标徽章 (点击可修改角色姓名并沉淀声纹)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _editSpeakerRoleName(seg.speakerId, roleName),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: speakerColor.color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: speakerColor.color.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: speakerColor.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            roleName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: speakerColor.color,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit_outlined,
                            size: 12,
                            color: speakerColor.color.withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_formatTime(seg.startMs)} - ${_formatTime(seg.endMs)}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: AppColors.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '校对修改此段文字',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _editSegmentText(seg),
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(Icons.edit_note_rounded, size: 17, color: AppColors.textMuted),
                      ),
                    ),
                  ),
                  if (isAudioAvailable) ...[
                    const SizedBox(width: 4),
                    Icon(
                      isActive ? Icons.graphic_eq_rounded : Icons.play_circle_outline_rounded,
                      size: 16,
                      color: isActive ? speakerColor.color : AppColors.textMuted,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(
                seg.text,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.55,
                  color: isActive ? Colors.white : AppColors.textPrimary.withValues(alpha: 0.9),
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 纯纪要只读底栏 (当音频文件不存在时，自适应窄屏不溢出)
  Widget _buildReadOnlyBottomBar(int segmentCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.cardBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Icon(Icons.menu_book_rounded, size: 17, color: AppColors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '共 $segmentCount 段 • 点击角色标签可标注声纹',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.copy_rounded, size: 15, color: AppColors.primary),
              label: const Text('复制全文', style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: () {
                final text = _controller.segments.map((s) => '${s.speakerName ?? s.speakerId}: ${s.text}').join('\n');
                Clipboard.setData(ClipboardData(text: text));
                AppToast.info(context, '全文纪要已复制到剪贴板');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 底部播放器控制舱 (窄屏自适应，彻底移除硬编码宽度溢出)
  Widget _buildBottomPlayerBar(SyncPlayerState state, int totalSegments) {
    final progress = state.durationMs > 0
        ? (state.positionMs / state.durationMs).clamp(0.0, 1.0)
        : 0.0;
    final isCompact = MediaQuery.of(context).size.width < 600;

    return Container(
      padding: EdgeInsets.fromLTRB(isCompact ? 12 : 20, 6, isCompact ? 12 : 20, isCompact ? 10 : 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度滑块与时间显示同行
            Row(
              children: [
                Text(
                  _formatTime(state.positionMs),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: AppColors.textSecondary),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      activeTrackColor: AppColors.primary,
                      inactiveTrackColor: AppColors.surfaceElevated,
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
                ),
                Text(
                  _formatTime(state.durationMs),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: AppColors.textMuted),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左侧：倍速切换胶囊
                SizedBox(
                  width: 56,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: AppColors.cardBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () {
                      final rates = [0.75, 1.0, 1.25, 1.5, 2.0];
                      final curIdx = rates.indexOf(state.playbackRate);
                      final nextRate = rates[(curIdx + 1) % rates.length];
                      _controller.setPlaybackRate(nextRate);
                    },
                    child: Text(
                      '${state.playbackRate}x',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                // 中央：播放控制按钮组
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '上一段发言',
                      icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70),
                      onPressed: state.activeSegmentIndex > 0
                          ? () => _controller.seekToSegment(state.activeSegmentIndex - 1)
                          : null,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '快退 5 秒',
                      icon: const Icon(Icons.replay_5_rounded, color: Colors.white),
                      onPressed: () => _controller.seek(state.positionMs - 5000),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: _controller.togglePlay,
                      borderRadius: BorderRadius.circular(26),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.primary, AppColors.primaryDark],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Icon(
                          state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '快进 5 秒',
                      icon: const Icon(Icons.forward_5_rounded, color: Colors.white),
                      onPressed: () => _controller.seek(state.positionMs + 5000),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '下一段发言',
                      icon: const Icon(Icons.skip_next_rounded, color: Colors.white70),
                      onPressed: (state.activeSegmentIndex >= 0 && state.activeSegmentIndex < totalSegments - 1)
                          ? () => _controller.seekToSegment(state.activeSegmentIndex + 1)
                          : null,
                    ),
                  ],
                ),
                // 右侧对称段落进度指示 (保持播放按钮严格居中且不溢出)
                SizedBox(
                  width: 56,
                  child: Text(
                    state.activeSegmentIndex >= 0
                        ? '${state.activeSegmentIndex + 1}/$totalSegments'
                        : '$totalSegments段',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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

class _SpeakerStat {
  final String speakerId;
  final String speakerName;
  final int segmentCount;
  final int wordCount;

  const _SpeakerStat({
    required this.speakerId,
    required this.speakerName,
    required this.segmentCount,
    required this.wordCount,
  });
}
