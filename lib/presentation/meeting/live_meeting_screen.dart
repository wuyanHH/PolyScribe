import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../data/models/meeting_task.dart';
import '../../data/models/transcript_segment.dart';
import '../../engine/audio/native_audio_bridge.dart';
import '../../engine/audio/windows_wasapi_recorder.dart';
import '../../engine/isolate/inference_worker.dart';
import '../../engine/isolate/worker_message.dart';
import '../../engine/model_manager.dart';
import '../../services/keep_alive_service.dart';
import '../models/model_manager_screen.dart';
import '../player/sync_player_screen.dart';

/// 实时长会议记录控制台 (全新现代UI / 多音源选择 / 动态多角色聚类 / 高刷新率微动效)
class LiveMeetingScreen extends StatefulWidget {
  final VoidCallback? onBackToHome;

  const LiveMeetingScreen({
    super.key,
    this.onBackToHome,
  });

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

  // 实时语音累积缓冲与当前句起始时间戳 (毫秒)
  final List<double> _accumulatedSamples = [];
  int _currentUtteranceStartMs = 0;

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

    if (!NativeAudioBridge.isWindowsNativeSupported) {
      _selectedSourceMode = AudioSourceMode.microphone;
    }

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

    if (config.isCurrentAsrReady || config.isAnyAsrReady) {
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

  /// 真实音频切片提取与智能停顿语音识别流水线
  Future<void> _processRealtimeAudioChunk({bool forceFlush = false}) async {
    if (_isProcessingChunk) return;

    _isProcessingChunk = true;
    try {
      // 1. 优先从原生 WASAPI / 流式内存队列中直接拉取最新的 16kHz 单声道样本 (零文件锁竞争、零字节错位)
      final pendingFromMemory = WindowsWasapiRecorder.instance.consumePendingSamples16k();
      if (pendingFromMemory.isNotEmpty) {
        if (_accumulatedSamples.isEmpty) {
          final chunkMs = (pendingFromMemory.length * 1000) ~/ 16000;
          _currentUtteranceStartMs = max(0, _elapsedMsNotifier.value - chunkMs);
        }
        _accumulatedSamples.addAll(pendingFromMemory);
      } else if (_recordedAudioPath != null) {
        // 备用回退：从 WAV 文件按偶数字节对齐读取
        final audioFile = File(_recordedAudioPath!);
        if (audioFile.existsSync()) {
          final fileLength = await audioFile.length();
          final rawAvailable = fileLength - _lastProcessedByteOffset;
          final alignedBytes = rawAvailable & ~3; // 4字节对齐，杜绝奇数字节错位
          if (alignedBytes > 0) {
            final raf = await audioFile.open(mode: FileMode.read);
            await raf.setPosition(_lastProcessedByteOffset);
            final rawBytes = await raf.read(alignedBytes);
            await raf.close();
            _lastProcessedByteOffset += rawBytes.length;

            final floatSamples = _bytesToFloat32Pcm(rawBytes, 1);
            if (floatSamples.isNotEmpty) {
              if (_accumulatedSamples.isEmpty) {
                final chunkMs = (floatSamples.length * 1000) ~/ 16000;
                _currentUtteranceStartMs = max(0, _elapsedMsNotifier.value - chunkMs);
              }
              _accumulatedSamples.addAll(floatSamples);
            }
          }
        }
      }

      if (_accumulatedSamples.isEmpty) return;

      const sampleRate = 16000;
      final totalSamples = _accumulatedSamples.length;

      // 计算当前累积音频的峰值与有效能量
      double peak = 0.0;
      double sumSq = 0.0;
      for (int i = 0; i < totalSamples; i++) {
        final v = _accumulatedSamples[i];
        final av = v.abs();
        if (av > peak) peak = av;
        sumSq += v * v;
      }
      final overallRms = sqrt(sumSq / totalSamples);

      // 若整段完全是死寂静音，超过 3 秒则自动滑动丢弃前段静音并对齐起始时间，防止静音无限堆积
      if (peak < 0.0025 && overallRms < 0.0005) {
        if (totalSamples > sampleRate * 3 || forceFlush) {
          final dropCount = forceFlush ? totalSamples : (totalSamples - sampleRate ~/ 2);
          _accumulatedSamples.removeRange(0, dropCount);
          _currentUtteranceStartMs += (dropCount * 1000) ~/ sampleRate;
        }
        return;
      }

      // 非强制刷出时，至少累积 1.5 秒以上再判断断句
      if (!forceFlush && totalSamples < (sampleRate * 1.5).toInt()) {
        return;
      }

      // 检查末尾 360ms 是否出现自然说话停顿 (静音谷底)
      const tailWindow = 5760; // 0.36s @ 16kHz
      bool hasTrailingPause = false;
      if (totalSamples >= sampleRate * 1.6 && totalSamples > tailWindow) {
        double tailSumSq = 0.0;
        for (int i = totalSamples - tailWindow; i < totalSamples; i++) {
          final v = _accumulatedSamples[i];
          tailSumSq += v * v;
        }
        final tailRms = sqrt(tailSumSq / tailWindow);
        if (tailRms < max(0.012, overallRms * 0.38)) {
          hasTrailingPause = true;
        }
      }

      final reachedMaxWindow = totalSamples >= (sampleRate * 6.0).toInt();
      if (!forceFlush && !hasTrailingPause && !reachedMaxWindow) {
        return;
      }

      // 确定最佳切分位置：若因达到 6 秒上限而切分，在末尾 1.8 秒内寻找能量最低的 100ms 谷底切开，绝不截断正在说的词
      int cutCount = totalSamples;
      if (!forceFlush && !hasTrailingPause && totalSamples > sampleRate * 4) {
        const searchWin = 1600; // 100ms
        final searchStart = max(sampleRate * 3, totalSamples - (sampleRate * 1.8).toInt());
        double minWinRms = double.infinity;
        int bestPos = totalSamples;
        for (int pos = searchStart; pos + searchWin <= totalSamples; pos += 400) {
          double wSq = 0.0;
          for (int k = 0; k < searchWin; k++) {
            final v = _accumulatedSamples[pos + k];
            wSq += v * v;
          }
          final wRms = sqrt(wSq / searchWin);
          if (wRms < minWinRms) {
            minWinRms = wRms;
            bestPos = pos + (searchWin ~/ 2);
          }
        }
        cutCount = bestPos;
      }

      final sliceFloats = Float32List(cutCount);
      for (int i = 0; i < cutCount; i++) {
        sliceFloats[i] = _accumulatedSamples[i];
      }
      _accumulatedSamples.removeRange(0, cutCount);

      final startMs = _currentUtteranceStartMs;
      final chunkDurationMs = (cutCount * 1000) ~/ sampleRate;
      final endMs = startMs + chunkDurationMs;
      _currentUtteranceStartMs = endMs;

      if (sliceFloats.length < 4800) return; // 忽略不足 0.3 秒的极短碎片

      final worker = InferenceWorkerCoordinator.instance;
      if (!_isModelReady || !worker.isReady) return;

      final chunkIndex = _chunkCounter++;
      final res = await worker.transcribeChunk(TranscribeChunkCommand(
        messageId: 'live_chunk_${_taskId}_$chunkIndex',
        taskId: _taskId,
        chunkIndex: chunkIndex,
        startMs: startMs,
        endMs: endMs,
        samples: sliceFloats,
      ));

      if (res != null && res.isSuccess && res.text.trim().isNotEmpty) {
        final text = res.text.trim();
        // 过滤空标点与过短无意义杂音
        if (text.length >= 2 || RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]').hasMatch(text)) {
          final String spkId = res.speakerId.isNotEmpty ? res.speakerId : 'SPK_01';
          final String spkName = (res.speakerName != null && res.speakerName!.isNotEmpty)
              ? res.speakerName!
              : '发言人 1';

          final newSegment = TranscriptSegment(
            taskId: _taskId,
            speakerId: spkId,
            speakerName: spkName,
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
    _accumulatedSamples.clear();
    _currentUtteranceStartMs = 0;
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
    if (_recordedAudioPath == null || _recordedAudioPath!.isEmpty) {
      await KeepAliveService.instance.releaseWakeLock();
      await KeepAliveService.instance.stopForegroundService();
      if (mounted) {
        AppToast.error(context, '未能获取麦克风录音权限，请在系统设置中授权麦克风后重试');
      }
      return;
    }

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

    // 启动真实音频切片周期性识别流水线 (每 700ms 触发一次智能停顿检测与增量转写)
    _realtimeTranscriptionTimer?.cancel();
    _realtimeTranscriptionTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
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

    // 收尾处理：若还有未处理的尾部音频，执行最后一次强制转写
    await _processRealtimeAudioChunk(forceFlush: true);

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
        _titleController.text = '实时会议纪要 ${_formatCurrentDate()}';
      });

      // 导航至音字同步播放详情页 (使用 push 保留主导航侧边栏栈，避免 pushReplacement 销毁根框架)
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SyncPlayerScreen(task: task),
        ),
      );
    }
  }

  /// 快速修改发言人姓名
  Future<void> _editSpeakerName(String speakerId, String currentName) async {
    final editController = TextEditingController(text: currentName);
    String? newName;
    try {
      newName = await showDialog<String>(
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
    } finally {
      editController.dispose();
    }

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

  /// 处理返回上级/纪要库逻辑
  Future<void> _handleBack() async {
    final isBusy = _recorderState == MeetingRecorderState.recording ||
        _recorderState == MeetingRecorderState.paused;

    if (isBusy) {
      final shouldLeave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: AppColors.primary),
              SizedBox(width: 10),
              Text('会议正在进行中', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            '当前实时会议录制尚未结束。\n切回纪要库后，录音与转录将在后台持续进行，您可以随时通过侧边栏切回本页面继续查看。',
            style: TextStyle(color: AppColors.textSecondary, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('留在此页', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('切回纪要库', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (shouldLeave != true) return;
    }

    if (!mounted) return;

    if (widget.onBackToHome != null) {
      widget.onBackToHome!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
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
      ),
    );
  }

  /// 顶部状态信息栏 (支持窄屏自适应，彻底消除横向溢出)
  Widget _buildTopHeader() {
    final isRecording = _recorderState == MeetingRecorderState.recording;
    final isPaused = _recorderState == MeetingRecorderState.paused;
    final isCompact = MediaQuery.of(context).size.width < 600;

    String shortSourceLabel;
    switch (_selectedSourceMode) {
      case AudioSourceMode.microphone:
        shortSourceLabel = isCompact ? '麦克风' : _selectedSourceMode.title;
        break;
      case AudioSourceMode.systemAudio:
        shortSourceLabel = isCompact ? '系统内录' : _selectedSourceMode.title;
        break;
      case AudioSourceMode.both:
        shortSourceLabel = isCompact ? '双路音源' : _selectedSourceMode.title;
        break;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 12 : 20, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.cardBorder, width: 1)),
      ),
      child: Row(
        children: [
          // 返回纪要库按钮
          Tooltip(
            message: '返回纪要库',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _handleBack,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.arrow_back_ios_new_rounded, size: 13, color: AppColors.textSecondary),
                    if (!isCompact) ...[
                      const SizedBox(width: 6),
                      const Text(
                        '纪要库',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: isCompact ? 10 : 14),
          // 状态光环与文字
          AnimatedBuilder(
            animation: _pulseScaleAnim,
            builder: (context, child) {
              return Transform.scale(
                scale: isRecording ? _pulseScaleAnim.value : 1.0,
                child: Container(
                  width: 10,
                  height: 10,
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
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              isRecording ? '实时转录中' : (isPaused ? '已暂停' : '待命就绪'),
              style: TextStyle(
                fontSize: isCompact ? 13.5 : 15,
                fontWeight: FontWeight.bold,
                color: isRecording ? Colors.white : (isPaused ? AppColors.amber : AppColors.textSecondary),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: isCompact ? 8 : 14),
          // 局部高性能计时器 (不导致父级组件全部重绘)
          _MeetingTimerDisplay(elapsedNotifier: _elapsedMsNotifier, isCompact: isCompact),
          const Spacer(),
          // 当前音源状态微标
          Container(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10, vertical: 4),
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
                  size: 13,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  shortSourceLabel,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 模型未就绪提示横幅 (窄屏内边距自适应)
  Widget _buildModelNoticeBanner() {
    final isCompact = MediaQuery.of(context).size.width < 600;
    if (_isEngineInitializing) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: isCompact ? 12 : 20, vertical: 8),
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
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 12 : 20, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0x1FF59E0B),
        border: Border(bottom: BorderSide(color: Color(0x33F59E0B))),
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

  /// 待命配置界面 (未点击开始录音前的精致就绪引导，手机端高度紧凑确保首屏直达开始按钮)
  Widget _buildIdleSetupView() {
    final isCompact = MediaQuery.of(context).size.width < 600;
    final isWindowsNative = NativeAudioBridge.isWindowsNativeSupported;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isCompact ? 16 : 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: isCompact ? 4 : 12),
              if (isCompact)
                // 手机端：采用紧凑横幅式头部，释放纵向空间
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primary.withValues(alpha: 0.2),
                        AppColors.surface,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppColors.primary, AppColors.primaryDark],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.mic_none_rounded, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '开启全新实时会议纪要',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            SizedBox(height: 3),
                            Text(
                              '16kHz 离线端侧识别 · 在线声纹聚类 · 音字同步',
                              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                // 桌面端：完整科技感徽标
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
              ],
              SizedBox(height: isCompact ? 14 : 28),

              // 会议标题输入框
              Container(
                padding: EdgeInsets.all(isCompact ? 14 : 16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
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
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
              SizedBox(height: isCompact ? 12 : 20),

              // 音源选择卡片组
              Container(
                padding: EdgeInsets.all(isCompact ? 14 : 18),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.tune_rounded, color: AppColors.primary, size: 17),
                        const SizedBox(width: 8),
                        const Text(
                          '选择输入音源',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const Spacer(),
                        Text(
                          isWindowsNative ? '支持随时切换' : '移动端高清拾音',
                          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (isWindowsNative) ...[
                      _buildSourceOptionTile(
                        mode: AudioSourceMode.both,
                        icon: Icons.multitrack_audio_rounded,
                        title: '麦克风 + 系统声音 (推荐)',
                        subtitle: '双向全捕获：近端发言与远端腾讯会议/Zoom/钉钉声音同时清晰识别',
                        isCompact: isCompact,
                      ),
                      const SizedBox(height: 8),
                      _buildSourceOptionTile(
                        mode: AudioSourceMode.microphone,
                        icon: Icons.mic_rounded,
                        title: '仅麦克风输入',
                        subtitle: '只捕获物理麦克风近端人声，适合单人现场口述与线下独立访谈',
                        isCompact: isCompact,
                      ),
                      const SizedBox(height: 8),
                      _buildSourceOptionTile(
                        mode: AudioSourceMode.systemAudio,
                        icon: Icons.speaker_rounded,
                        title: '仅系统声音 (扬声器内录)',
                        subtitle: '只捕获电脑正在播放的声音，免受周围环境噪音干扰，适合网课与远程宣讲',
                        isCompact: isCompact,
                      ),
                    ] else ...[
                      _buildSourceOptionTile(
                        mode: AudioSourceMode.microphone,
                        icon: Icons.mic_rounded,
                        title: '手机高灵敏度麦克风阵列 (推荐)',
                        subtitle: '16kHz 硬件降噪直采，自动区分多位现场发言人并流式生成文字',
                        isCompact: isCompact,
                      ),
                      const SizedBox(height: 8),
                      _buildSourceOptionTile(
                        mode: AudioSourceMode.both,
                        icon: Icons.multitrack_audio_rounded,
                        title: '免提外放增强模式 (会议/网课)',
                        subtitle: '同时拾取近端人声与扬声器外放内容，自适应弱音增益补偿',
                        isCompact: isCompact,
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: isCompact ? 18 : 28),

              // 开始录音转录大按钮
              SizedBox(
                height: isCompact ? 48 : 52,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 6,
                    shadowColor: AppColors.primary.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
                  label: const Text(
                    '开始会议转录',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, letterSpacing: 0.5),
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
    bool isCompact = false,
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
        padding: EdgeInsets.all(isCompact ? 11 : 14),
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
              padding: EdgeInsets.all(isCompact ? 8 : 10),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: isSelected ? Colors.white : AppColors.textSecondary, size: isCompact ? 18 : 20),
            ),
            SizedBox(width: isCompact ? 10 : 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: isCompact ? 13 : 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: isCompact ? 11 : 12,
                      color: isSelected ? AppColors.textSecondary : AppColors.textMuted,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 18,
              height: 18,
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
                        width: 9,
                        height: 9,
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
            // 实时发言人质心池与字数统计胶囊条
            if (_segments.isNotEmpty) _buildLiveStatsAndSpeakersBar(),
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

  /// 实时发言人质心池与字数统计胶囊条
  Widget _buildLiveStatsAndSpeakersBar() {
    final totalWords = _segments.fold<int>(0, (acc, s) => acc + s.text.length);
    final speakerMap = <String, String>{};
    for (final s in _segments) {
      speakerMap[s.speakerId] = s.speakerName ?? AppColors.getSpeakerColor(s.speakerId).defaultRoleName;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.cardBorder, width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.people_alt_outlined, size: 15, color: AppColors.primary),
          const SizedBox(width: 6),
          const Text(
            '在线声纹角色:',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: speakerMap.entries.map((entry) {
                  final spkColor = AppColors.getSpeakerColor(entry.key);
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _editSpeakerName(entry.key, entry.value),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: spkColor.color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: spkColor.color.withValues(alpha: 0.35)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: spkColor.color, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              entry.value,
                              style: TextStyle(
                                color: spkColor.color,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.edit_outlined, size: 11, color: spkColor.color.withValues(alpha: 0.7)),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_segments.length} 段 · $totalWords 字',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
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
    final isCompact = MediaQuery.of(context).size.width < 600;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 24, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 暂停 / 恢复转录按钮
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: isRecording ? AppColors.amber : AppColors.emerald),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                icon: Icon(
                  isRecording ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 20,
                  color: isRecording ? AppColors.amber : AppColors.emerald,
                ),
                label: Text(
                  isRecording ? '暂停转录' : '恢复转录',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: isRecording ? AppColors.amber : AppColors.emerald,
                  ),
                ),
                onPressed: _togglePauseResume,
              ),
            ),
            const SizedBox(width: 12),
            // 完成并生成纪要大按钮
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.rose,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  elevation: 4,
                ),
                icon: const Icon(Icons.stop_rounded, size: 20),
                label: Text(
                  isCompact ? '结束并保存' : '结束并保存纪要',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
                ),
                onPressed: _handleFinishMeeting,
              ),
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
  final bool isCompact;

  const _MeetingTimerDisplay({required this.elapsedNotifier, this.isCompact = false});

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
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Text(
            '$hours:$minutes:$seconds',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: isCompact ? 13 : 15,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 0.8,
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
