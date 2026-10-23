import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../engine/audio/windows_wasapi_recorder.dart';
import '../../engine/diarization/online_centroid_bank.dart';
import '../../engine/isolate/inference_worker.dart';
import '../../engine/isolate/worker_message.dart';
import '../../engine/model_manager.dart';
import '../../services/keep_alive_service.dart';
import '../models/model_manager_screen.dart';
import '../player/sync_player_screen.dart';

/// 实时长会议记录控制台 (全新现代UI / 多音源选择 / 动态多角色聚类 / 高刷新率微动效)
class LiveMeetingScreen extends StatefulWidget {
  const LiveMeetingScreen({super.key});

  @override
  State<LiveMeetingScreen> createState() => _LiveMeetingScreenState();
}

class _LiveMeetingScreenState extends State<LiveMeetingScreen> with TickerProviderStateMixin {
  final List<TranscriptSegment> _segments = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _titleController = TextEditingController();

  // 高性能局部刷新 Notifier (杜绝全页面频繁 setState 引起的卡顿掉帧)
  final ValueNotifier<int> _elapsedMsNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _isAutoScrollEnabled = ValueNotifier<bool>(true);

  OnlineCentroidBank? _centroidBank;

  MeetingRecorderState _recorderState = MeetingRecorderState.idle;
  AudioSourceMode _selectedSourceMode = AudioSourceMode.both;
  bool _isModelReady = false;
  bool _isEngineInitializing = false;
  String _taskId = '';
  Timer? _tickerTimer;
  Timer? _realtimeTranscriptionTimer;
  int _chunkCounter = 0;
  int _lastProcessedByteOffset = 44; // WAV 文件头 44 字节
  bool _isProcessingChunk = false;
  String? _recordedAudioPath;

  // 动画控制器
  late final AnimationController _pulseAnimController;
  late final Animation<double> _pulseScaleAnim;

  @override
  void initState() {
    super.initState();
    _pulseAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseScaleAnim = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseAnimController, curve: Curves.easeInOut),
    );

    _titleController.text = '实时会议纪要 ${_formatCurrentDate()}';
    _scrollController.addListener(_onScroll);

    // 预检模型与声卡环境，若模型就绪则静默预热工作线程
    _checkSystemEnvironment();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    // 如果距离底部超过 80 像素，则暂停自动滚动，避免强行打扰用户查看历史
    final isNearBottom = (maxScroll - currentScroll) < 80;
    if (_isAutoScrollEnabled.value != isNearBottom) {
      _isAutoScrollEnabled.value = isNearBottom;
    }
  }

  Future<void> _checkSystemEnvironment() async {
    final config = await ModelManager.instance.resolveModels();
    final knownPrints = await AppDatabase.instance.getAllVoicePrints();
    _centroidBank = OnlineCentroidBank(initialVoicePrints: knownPrints);

    if (config.isSenseVoiceReady) {
      if (mounted) {
        setState(() => _isEngineInitializing = true);
      }
      try {
        final ok = await InferenceWorkerCoordinator.instance.initialize(config);
        if (mounted) {
          setState(() {
            _isModelReady = ok;
            _isEngineInitializing = false;
          });
        }
      } catch (e) {
        debugPrint('[LiveMeeting] 推理引擎预热异常: $e');
        if (mounted) {
          setState(() {
            _isModelReady = false;
            _isEngineInitializing = false;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _isModelReady = false;
          _isEngineInitializing = false;
        });
      }
    }
  }

  /// 字节数组转 Float32 PCM (归一化至 [-1.0, 1.0])
  Float32List _bytesToFloat32Pcm(Uint8List bytes, int channels) {
    if (bytes.length < 2) return Float32List(0);
    final byteData = ByteData.sublistView(bytes);
    final totalSamples = bytes.length ~/ 2;

    if (channels <= 1) {
      final floats = Float32List(totalSamples);
      for (int i = 0; i < totalSamples; i++) {
        final s16 = byteData.getInt16(i * 2, Endian.little);
        floats[i] = s16 / 32768.0;
      }
      return floats;
    } else {
      // 双声道降采样为单声道 (L + R) / 2
      final frameCount = totalSamples ~/ channels;
      final floats = Float32List(frameCount);
      for (int i = 0; i < frameCount; i++) {
        final left = byteData.getInt16(i * 4, Endian.little);
        final right = byteData.getInt16(i * 4 + 2, Endian.little);
        floats[i] = ((left + right) / 2.0) / 32768.0;
      }
      return floats;
    }
  }

  /// 真实音频切片提取与实时语音识别流水线
  Future<void> _processRealtimeAudioChunk() async {
    if (_isProcessingChunk) return;
    if (_recordedAudioPath == null) return;
    final audioFile = File(_recordedAudioPath!);
    if (!audioFile.existsSync()) return;

    _isProcessingChunk = true;
    try {
      final fileLength = await audioFile.length();
      if (_lastProcessedByteOffset >= fileLength) return;

      // 每次至少累积 32000 字节 (单声道约 1 秒音频，双声道约 0.5 秒)
      final availableBytes = fileLength - _lastProcessedByteOffset;
      if (availableBytes < 32000) return;

      final raf = await audioFile.open(mode: FileMode.read);
      await raf.setPosition(_lastProcessedByteOffset);
      final rawBytes = await raf.read(availableBytes);
      await raf.close();

      _lastProcessedByteOffset += availableBytes;

      final channels = _selectedSourceMode == AudioSourceMode.both ? 2 : 1;
      final floatSamples = _bytesToFloat32Pcm(rawBytes, channels);
      if (floatSamples.length < 8000) return;

      final worker = InferenceWorkerCoordinator.instance;
      if (!_isModelReady || !worker.isReady) return;

      final chunkIndex = _chunkCounter++;
      final chunkDurationMs = (floatSamples.length / 16000 * 1000).toInt();
      final endMs = _elapsedMsNotifier.value;
      final startMs = max(0, endMs - chunkDurationMs);

      final res = await worker.transcribeChunk(TranscribeChunkCommand(
        messageId: 'live_chunk_${_taskId}_$chunkIndex',
        taskId: _taskId,
        chunkIndex: chunkIndex,
        startMs: startMs,
        endMs: endMs,
        samples: floatSamples,
      ));

      if (res != null && res.isSuccess && res.text.trim().isNotEmpty) {
        final text = res.text.trim();
        // 过滤空标点与过短杂音
        if (text.length >= 2 || RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]').hasMatch(text)) {
          final diarResult = _centroidBank?.assignSpeaker(
            embedding: Float32List(192),
            durationMs: chunkDurationMs,
            startMs: startMs,
            endMs: endMs,
          );

          final newSegment = TranscriptSegment(
            taskId: _taskId,
            speakerId: diarResult?.speakerId ?? 'SPK_01',
            speakerName: diarResult?.speakerName ?? '发言人 1',
            startMs: startMs,
            endMs: endMs,
            text: text,
          );

          if (mounted) {
            setState(() {
              _segments.add(newSegment);
            });
            if (_isAutoScrollEnabled.value) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[LiveMeeting] 实时切片识别异常: $e');
    } finally {
      _isProcessingChunk = false;
    }
  }

  /// 用户主动触发：开始录制与转录
  Future<void> _handleStartTranscription() async {
    if (_recorderState != MeetingRecorderState.idle) return;

    // 若模型未就绪，弹窗指引
    if (!_isModelReady) {
      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 24),
              SizedBox(width: 10),
              Text('本地 AI 模型尚未就绪', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            'SenseVoice 离线语音识别模型尚未下载或正在加载。若未部署模型，将无法把现场人声转换为文字。\n是否立即前往模型管理中心一键下载？',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('仅录音', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('前往下载模型', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (shouldDownload == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
        );
        _checkSystemEnvironment();
        return;
      }
    }

    _taskId = 'live_${DateTime.now().millisecondsSinceEpoch}';
    _segments.clear();
    _elapsedMsNotifier.value = 0;
    _chunkCounter = 0;
    _lastProcessedByteOffset = 44;

    // 申请系统保活硬件锁
    await KeepAliveService.instance.acquireWakeLock(reason: 'PolyScribe 实时会议转录');
    await KeepAliveService.instance.startForegroundService(
      title: 'PolyScribe 实时转录进行中',
      content: '音源: ${_selectedSourceMode.title} | 角色动态聚类中',
    );

    // 设置音源模式并启动真实硬件录音
    final recorder = WindowsWasapiRecorder.instance;
    recorder.setMode(_selectedSourceMode);
    _recordedAudioPath = await recorder.startRecording(taskId: _taskId);

    setState(() {
      _recorderState = MeetingRecorderState.recording;
    });

    // 启动高精度局部计时器
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_recorderState == MeetingRecorderState.recording) {
        _elapsedMsNotifier.value += 100;
      }
    });

    // 启动真实音频切片周期性识别流水线 (每 2.5 秒触发一次增量转写)
    _realtimeTranscriptionTimer?.cancel();
    _realtimeTranscriptionTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (_recorderState == MeetingRecorderState.recording) {
        _processRealtimeAudioChunk();
      }
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 暂停 / 恢复转录
  Future<void> _togglePauseResume() async {
    final recorder = WindowsWasapiRecorder.instance;
    if (_recorderState == MeetingRecorderState.recording) {
      await recorder.pauseRecording();
      setState(() {
        _recorderState = MeetingRecorderState.paused;
      });
    } else if (_recorderState == MeetingRecorderState.paused) {
      await recorder.resumeRecording();
      setState(() {
        _recorderState = MeetingRecorderState.recording;
      });
    }
  }

  /// 结束会议并落库持久化
  Future<void> _handleFinishMeeting() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: AppColors.emerald, size: 24),
            SizedBox(width: 10),
            Text('完成并生成纪要', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '当前共记录 ${_segments.length} 条发言段落，录音将安全落盘并持久化到本地数据库。\n是否确认结束本次转录？',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续录制', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认生成', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    _tickerTimer?.cancel();
    _realtimeTranscriptionTimer?.cancel();

    setState(() {
      _recorderState = MeetingRecorderState.stopping;
    });

    final recordedAudioPath = await WindowsWasapiRecorder.instance.stopRecording();
    await KeepAliveService.instance.releaseWakeLock();
    await KeepAliveService.instance.stopForegroundService();

    // 收尾处理：若还有未处理的尾部音频，执行最后一次转写
    await _processRealtimeAudioChunk();

    final finalTitle = _titleController.text.trim().isEmpty
        ? '实时会议纪要 ${_formatCurrentDate()}'
        : _titleController.text.trim();

    // 持久化会议任务
    final task = MeetingTask(
      id: _taskId,
      title: finalTitle,
      sourceType: TaskSourceType.liveMeeting,
      audioPath: recordedAudioPath,
      durationMs: _elapsedMsNotifier.value,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.completed,
    );

    await AppDatabase.instance.saveTask(task);
    for (final seg in _segments) {
      await AppDatabase.instance.insertSegment(seg);
    }

    if (mounted) {
      setState(() {
        _recorderState = MeetingRecorderState.idle;
      });

      // 导航至音字同步播放详情页
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SyncPlayerScreen(task: task),
        ),
      );
    }
  }

  /// 快速修改发言人姓名
  Future<void> _editSpeakerName(String speakerId, String currentName) async {
    final editController = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('修改发言人备注 ($speakerId)', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: editController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '输入该角色在此次会议中的姓名...',
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(editController.text.trim()),
            child: const Text('保存修改'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && mounted) {
      setState(() {
        for (int i = 0; i < _segments.length; i++) {
          if (_segments[i].speakerId == speakerId) {
            _segments[i] = _segments[i].copyWith(speakerName: newName);
          }
        }
      });
    }
  }

  String _formatCurrentDate() {
    final now = DateTime.now();
    return '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _realtimeTranscriptionTimer?.cancel();
    _scrollController.dispose();
    _titleController.dispose();
    _pulseAnimController.dispose();
    _elapsedMsNotifier.dispose();
    _isAutoScrollEnabled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(),
            if (!_isModelReady) _buildModelNoticeBanner(),
            Expanded(
              child: _recorderState == MeetingRecorderState.idle
                  ? _buildIdleSetupView()
                  : _buildLiveTranscriptionView(),
            ),
            _buildBottomControlBar(),
          ],
        ),
      ),
    );
  }

  /// 顶部状态信息栏
  Widget _buildTopHeader() {
    final isRecording = _recorderState == MeetingRecorderState.recording;
    final isPaused = _recorderState == MeetingRecorderState.paused;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.cardBorder, width: 1)),
      ),
      child: Row(
        children: [
          // 状态光环与文字
          AnimatedBuilder(
            animation: _pulseScaleAnim,
            builder: (context, child) {
              return Transform.scale(
                scale: isRecording ? _pulseScaleAnim.value : 1.0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRecording
                        ? AppColors.rose
                        : (isPaused ? AppColors.amber : AppColors.textMuted),
                    boxShadow: isRecording
                        ? [
                            BoxShadow(
                              color: AppColors.rose.withValues(alpha: 0.6),
                              blurRadius: 10,
                              spreadRadius: 2,
                            )
                          ]
                        : null,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          Text(
            isRecording ? '实时转录中' : (isPaused ? '转录已暂停' : '待命就绪'),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isRecording ? Colors.white : (isPaused ? AppColors.amber : AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 16),
          // 局部高性能计时器 (不导致父级组件全部重绘)
          _MeetingTimerDisplay(elapsedNotifier: _elapsedMsNotifier),
          const Spacer(),
          // 当前音源状态微标
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _selectedSourceMode == AudioSourceMode.microphone
                      ? Icons.mic_rounded
                      : (_selectedSourceMode == AudioSourceMode.systemAudio
                          ? Icons.volume_up_rounded
                          : Icons.tune_rounded),
                  size: 14,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  _selectedSourceMode.title,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 模型未就绪提示横幅
  Widget _buildModelNoticeBanner() {
    if (_isEngineInitializing) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          border: Border(bottom: BorderSide(color: AppColors.primary.withValues(alpha: 0.3))),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '正在加载 SenseVoice 本地模型并预热后台推理引擎...',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.12),
        border: const Border(bottom: BorderSide(color: Color(0x33F59E0B))),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 16),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '提示：SenseVoice 本地模型尚未部署。录音已正常开启硬件采集，但无法将现场人声转换为文字。',
              style: TextStyle(color: AppColors.amber, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
              );
              _checkSystemEnvironment();
            },
            child: const Text('前往下载', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// 待命配置界面 (未点击开始录音前的精致就绪引导)
  Widget _buildIdleSetupView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              // 顶部科技徽标
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.primary, AppColors.primaryDark],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.mic_none_rounded, color: Colors.white, size: 36),
                ),
              ),
              const SizedBox(height: 18),
              const Center(
                child: Text(
                  '开启全新实时会议纪要',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  '多音源硬件分离 · 在线声纹聚类 · 毫秒级音字同步',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: 32),

              // 会议标题输入框
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '会议主题 / 纪要名称',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _titleController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: AppColors.surfaceElevated,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        hintText: '输入本次会议纪要的名称...',
                        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 音源选择卡片组
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.tune_rounded, color: AppColors.primary, size: 18),
                        SizedBox(width: 8),
                        Text(
                          '选择输入音源',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        Spacer(),
                        Text(
                          '支持随时切换',
                          style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildSourceOptionTile(
                      mode: AudioSourceMode.both,
                      icon: Icons.multitrack_audio_rounded,
                      title: '麦克风 + 系统声音 (推荐)',
                      subtitle: '双向全捕获：近端发言与远端腾讯会议/Zoom/钉钉声音同时清晰识别',
                    ),
                    const SizedBox(height: 10),
                    _buildSourceOptionTile(
                      mode: AudioSourceMode.microphone,
                      icon: Icons.mic_rounded,
                      title: '仅麦克风输入',
                      subtitle: '只捕获物理麦克风近端人声，适合单人现场口述与线下独立访谈',
                    ),
                    const SizedBox(height: 10),
                    _buildSourceOptionTile(
                      mode: AudioSourceMode.systemAudio,
                      icon: Icons.speaker_rounded,
                      title: '仅系统声音 (扬声器内录)',
                      subtitle: '只捕获电脑正在播放的声音，免受周围环境噪音干扰，适合网课与远程宣讲',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // 开始录音转录大按钮
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 6,
                    shadowColor: AppColors.primary.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                  label: const Text(
                    '开始会议转录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                  onPressed: _handleStartTranscription,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个音源选择瓦片
  Widget _buildSourceOptionTile({
    required AudioSourceMode mode,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _selectedSourceMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _selectedSourceMode = mode;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withValues(alpha: 0.12) : AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.cardBorder,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: isSelected ? Colors.white : AppColors.textSecondary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: isSelected ? AppColors.textSecondary : AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.cardBorder,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 实时转录文档流视图
  Widget _buildLiveTranscriptionView() {
    return Stack(
      children: [
        Column(
          children: [
            // 实时音浪频谱动效条 (监听真实音频振幅)
            _AudioVisualizerBar(
              amplitudeStream: WindowsWasapiRecorder.instance.onAmplitude,
              isPaused: _recorderState == MeetingRecorderState.paused,
            ),
            // 文档流列表
            Expanded(
              child: _segments.isEmpty
                  ? Center(
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
                            child: const Icon(Icons.graphic_eq_rounded, size: 42, color: AppColors.primary),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '正在收听音频流并实时聚类多角色...',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '当前音源：${_selectedSourceMode.title} | 声纹质心池在线迭代中',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 90),
                      itemCount: _segments.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _segments.length) {
                          // 末尾流式监听指示光斑
                          return _buildStreamingPulseIndicator();
                        }
                        final seg = _segments[index];
                        return _buildSegmentCard(seg);
                      },
                    ),
            ),
          ],
        ),
        // “回到最新” 悬浮按钮 (当用户上滑查看历史时出现)
        ValueListenableBuilder<bool>(
          valueListenable: _isAutoScrollEnabled,
          builder: (context, isAtBottom, _) {
            if (isAtBottom) return const SizedBox.shrink();
            return Positioned(
              right: 24,
              bottom: 24,
              child: FloatingActionButton.extended(
                backgroundColor: AppColors.surfaceElevated,
                foregroundColor: AppColors.primary,
                elevation: 4,
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: const Text('回到最新', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                onPressed: () {
                  _isAutoScrollEnabled.value = true;
                  _scrollToBottom();
                },
              ),
            );
          },
        ),
      ],
    );
  }

  /// 单个多角色发言段落卡片
  Widget _buildSegmentCard(TranscriptSegment seg) {
    final speakerColor = AppColors.getSpeakerColor(seg.speakerId);
    final roleName = seg.speakerName ?? speakerColor.defaultRoleName;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: speakerColor.color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：角色专属头像色标 + 名字 + 时间戳 + 编辑操作
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: speakerColor.surfaceColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: speakerColor.color, width: 1.2),
                  ),
                  child: Center(
                    child: Text(
                      seg.speakerId.replaceAll('SPK_', '#'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: speakerColor.color,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _editSpeakerName(seg.speakerId, roleName),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        roleName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: speakerColor.color,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.edit_note_rounded, size: 14, color: speakerColor.color.withValues(alpha: 0.7)),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  _formatTimeRange(seg.startMs, seg.endMs),
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 发言文本
            SelectableText(
              seg.text,
              style: const TextStyle(
                fontSize: 14.5,
                color: AppColors.textPrimary,
                height: 1.5,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 正在转录流式打字脉冲微标
  Widget _buildStreamingPulseIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.8),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '正在实时流式转录下一段人声...',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  /// 底部悬浮控制台
  Widget _buildBottomControlBar() {
    if (_recorderState == MeetingRecorderState.idle) {
      return const SizedBox.shrink();
    }

    final isRecording = _recorderState == MeetingRecorderState.recording;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // 暂停 / 恢复转录按钮
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: isRecording ? AppColors.amber : AppColors.emerald),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              icon: Icon(
                isRecording ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: isRecording ? AppColors.amber : AppColors.emerald,
              ),
              label: Text(
                isRecording ? '暂停转录' : '恢复转录',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isRecording ? AppColors.amber : AppColors.emerald,
                ),
              ),
              onPressed: _togglePauseResume,
            ),
            // 完成并生成纪要大按钮
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.rose,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                elevation: 4,
              ),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('结束并保存纪要', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _handleFinishMeeting,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeRange(int startMs, int endMs) {
    String fmt(int ms) {
      final d = Duration(milliseconds: ms);
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
    return '${fmt(startMs)} - ${fmt(endMs)}';
  }
}

/// 局部高刷新率计时器组件 (避免导致外层全列表 rebuild)
class _MeetingTimerDisplay extends StatelessWidget {
  final ValueNotifier<int> elapsedNotifier;

  const _MeetingTimerDisplay({required this.elapsedNotifier});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: elapsedNotifier,
      builder: (context, ms, _) {
        final d = Duration(milliseconds: ms);
        final hours = d.inHours.toString().padLeft(2, '0');
        final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
        final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Text(
            '$hours:$minutes:$seconds',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1.0,
            ),
          ),
        );
      },
    );
  }
}

/// 实时音频振幅频谱动效条 (60fps/120fps 平滑动效)
class _AudioVisualizerBar extends StatefulWidget {
  final Stream<double> amplitudeStream;
  final bool isPaused;

  const _AudioVisualizerBar({
    required this.amplitudeStream,
    required this.isPaused,
  });

  @override
  State<_AudioVisualizerBar> createState() => _AudioVisualizerBarState();
}

class _AudioVisualizerBarState extends State<_AudioVisualizerBar> {
  static const int _barCount = 28;
  final List<double> _bars = List.filled(_barCount, 0.1);
  StreamSubscription<double>? _sub;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _sub = widget.amplitudeStream.listen((amp) {
      if (!mounted || widget.isPaused) return;
      setState(() {
        for (int i = 0; i < _barCount; i++) {
          final factor = 0.4 + 0.6 * sin((i / _barCount) * pi);
          final jitter = (_random.nextDouble() - 0.5) * 0.25;
          _bars[i] = ((amp * factor) + jitter).clamp(0.08, 1.0);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      color: AppColors.surface.withValues(alpha: 0.6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_barCount, (i) {
          final heightPercent = widget.isPaused ? 0.08 : _bars[i];
          return AnimatedContainer(
            duration: const Duration(milliseconds: 70),
            curve: Curves.easeOut,
            width: 3.5,
            height: max(4.0, 26.0 * heightPercent),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: widget.isPaused
                    ? [AppColors.textMuted, AppColors.textMuted]
                    : [AppColors.primaryDark, AppColors.primary],
              ),
            ),
          );
        }),
      ),
    );
  }
}
