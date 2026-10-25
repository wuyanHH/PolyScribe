import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../../core/constants/app_constants.dart';
import '../../data/models/transcript_segment.dart';
import '../diarization/online_centroid_bank.dart';
import '../model_manager.dart';
import '../text/transcript_cleaner.dart';
import 'worker_message.dart';

/// 推理工作线程协调器 (运行在主线程，通过 Isolate 与底层 AI 交互)
class InferenceWorkerCoordinator {
  static InferenceWorkerCoordinator? _instance;
  static InferenceWorkerCoordinator get instance =>
      _instance ??= InferenceWorkerCoordinator._();

  InferenceWorkerCoordinator._();

  Isolate? _isolate;
  SendPort? _workerSendPort;
  ReceivePort? _hostReceivePort;
  ReceivePort? _exitReceivePort;
  ReceivePort? _errorReceivePort;
  bool _isModelLoaded = false;
  Future<bool>? _initializingFuture;
  ModelConfig? _lastConfig;
  Timer? _idleTimer;
  final Map<String, Completer<WorkerResponse>> _pendingRequests = {};

  final StreamController<SegmentTranscriptionResponse> _segmentStreamController =
      StreamController<SegmentTranscriptionResponse>.broadcast();

  final StreamController<WorkerProgressNotification> _progressStreamController =
      StreamController<WorkerProgressNotification>.broadcast();

  Stream<SegmentTranscriptionResponse> get onSegmentTranscribed =>
      _segmentStreamController.stream;

  Stream<WorkerProgressNotification> get onProgressNotification =>
      _progressStreamController.stream;

  bool get isReady => _workerSendPort != null && _isModelLoaded;

  /// 激活活动标志，刷新或重置空闲休眠计时器
  void _touchActive() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// 安排空闲自动休眠 (3分钟无任务自动释放推理内存)
  void _scheduleIdleSuspend() {
    _idleTimer?.cancel();
    if (_isolate != null && _isModelLoaded) {
      _idleTimer = Timer(const Duration(minutes: 3), () {
        if (_pendingRequests.isEmpty) {
          suspend();
        }
      });
    }
  }

  /// 初始化并启动工作线程 Isolate (支持并发重入保护与失败重试)
  Future<bool> initialize(ModelConfig config) async {
    _lastConfig = config;
    _touchActive();
    if (_isolate != null && _isModelLoaded) return true;
    if (_initializingFuture != null) return await _initializingFuture!;

    _initializingFuture = _doInitialize(config);
    try {
      return await _initializingFuture!;
    } finally {
      _initializingFuture = null;
    }
  }

  Future<bool> _doInitialize(ModelConfig config) async {
    if (_isolate != null && !_isModelLoaded) {
      await dispose();
    }

    final readyCompleter = Completer<SendPort>();
    _hostReceivePort = ReceivePort();
    _exitReceivePort = ReceivePort();
    _errorReceivePort = ReceivePort();

    _exitReceivePort!.listen((_) {
      debugPrint('[InferenceWorker] 检测到工作线程 Isolate 退出，自动重置状态');
      _handleWorkerTerminated('推理工作线程意外终止');
    });

    _errorReceivePort!.listen((err) {
      debugPrint('[InferenceWorker] 工作线程未捕获异常: $err');
      _handleWorkerTerminated('推理工作线程发生异常: $err');
    });

    _hostReceivePort!.listen((message) {
      if (message is SendPort) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete(message);
        }
      } else if (message is WorkerResponse) {
        final completer = _pendingRequests.remove(message.messageId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message);
        }

        if (message is SegmentTranscriptionResponse) {
          _segmentStreamController.add(message);
        }
      } else if (message is WorkerProgressNotification) {
        _progressStreamController.add(message);
      }
    });

    _isolate = await Isolate.spawn(
      _inferenceWorkerEntryPoint,
      _hostReceivePort!.sendPort,
      onExit: _exitReceivePort!.sendPort,
      onError: _errorReceivePort!.sendPort,
      debugName: 'InferenceWorkerIsolate',
    );

    _workerSendPort = await readyCompleter.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('启动推理 Isolate 握手超时'),
    );

    // 发送初始化模型指令
    final initMsgId = 'init_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<WorkerResponse>();
    _pendingRequests[initMsgId] = completer;

    _workerSendPort!.send(InitWorkerCommand(
      messageId: initMsgId,
      config: config,
    ));

    final response = await completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => const InitWorkerResponse(
        messageId: 'timeout',
        isSuccess: false,
        isModelLoaded: false,
        errorMessage: '工作线程加载模型超时',
      ),
    );

    _isModelLoaded = response.isSuccess;
    debugPrint('[InferenceWorker] 初始化结果: ${response.isSuccess}, err: ${response.errorMessage}');
    return response.isSuccess;
  }

  void _handleWorkerTerminated(String reason) {
    _isolate = null;
    _workerSendPort = null;
    _isModelLoaded = false;
    _hostReceivePort?.close();
    _hostReceivePort = null;
    _exitReceivePort?.close();
    _exitReceivePort = null;
    _errorReceivePort?.close();
    _errorReceivePort = null;

    if (_pendingRequests.isNotEmpty) {
      final pending = Map<String, Completer<WorkerResponse>>.from(_pendingRequests);
      _pendingRequests.clear();
      for (final entry in pending.entries) {
        if (!entry.value.isCompleted) {
          entry.value.complete(WorkerResponse(
            messageId: entry.key,
            isSuccess: false,
            errorMessage: reason,
          ));
        }
      }
    }
  }

  /// 发送音频切片转写 (看门狗自愈保护 + 自动唤醒)
  Future<SegmentTranscriptionResponse?> transcribeChunk(TranscribeChunkCommand cmd) async {
    _touchActive();
    if (!isReady && _lastConfig != null) {
      debugPrint('[InferenceWorker] 推理线程未就绪或处于休眠，看门狗自动预热拉起...');
      await initialize(_lastConfig!);
    }
    if (_workerSendPort == null) return null;

    final completer = Completer<WorkerResponse>();
    _pendingRequests[cmd.messageId] = completer;
    _workerSendPort!.send(cmd);

    try {
      final res = await completer.future;
      if (res is SegmentTranscriptionResponse) return res;
      return null;
    } finally {
      if (_pendingRequests.isEmpty) {
        _scheduleIdleSuspend();
      }
    }
  }

  /// 发送离线完整音频文件转写请求 (支持 Silero-VAD 自然切句、看门狗自愈与任务完成后自动安排休眠)
  Future<TranscribeFileResponse?> transcribeFile(TranscribeFileCommand cmd) async {
    _touchActive();
    if (!isReady && _lastConfig != null) {
      debugPrint('[InferenceWorker] 推理线程未就绪或处于休眠，看门狗自动预热拉起...');
      await initialize(_lastConfig!);
    }
    if (_workerSendPort == null) return null;

    final completer = Completer<WorkerResponse>();
    _pendingRequests[cmd.messageId] = completer;
    _workerSendPort!.send(cmd);

    try {
      final res = await completer.future;
      if (res is TranscribeFileResponse) return res;
      return null;
    } finally {
      if (_pendingRequests.isEmpty) {
        _scheduleIdleSuspend();
      }
    }
  }

  /// 中断或取消指定转写任务 (用于任务暂停、队列删除与防死锁保护)
  void cancelTask(String taskId) {
    _touchActive();
    _workerSendPort?.send(CancelTaskCommand(
      messageId: 'cancel_${DateTime.now().millisecondsSinceEpoch}',
      taskId: taskId,
    ));
    _scheduleIdleSuspend();
  }

  /// 重新加载或热切换模型
  Future<bool> reloadModel(ModelConfig config) async {
    debugPrint('[InferenceWorker] 触发模型热重载: ${config.currentAsrName}');
    await dispose();
    return await initialize(config);
  }

  /// 空闲自动挂起与显存回收：释放底层大型 ONNX 权重以大幅降低手机待机功耗
  Future<void> suspend() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_isolate == null) return;

    debugPrint('[InferenceWorker] 触发空闲自动休眠，卸载底层 ONNX 权重以回收系统内存');
    _workerSendPort?.send(DisposeWorkerCommand(
      messageId: 'suspend_${DateTime.now().millisecondsSinceEpoch}',
    ));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerSendPort = null;
    _isModelLoaded = false;
    _hostReceivePort?.close();
    _hostReceivePort = null;
    _exitReceivePort?.close();
    _exitReceivePort = null;
    _errorReceivePort?.close();
    _errorReceivePort = null;
  }

  /// 销毁并退出工作线程
  Future<void> dispose() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _workerSendPort?.send(DisposeWorkerCommand(
      messageId: 'dispose_${DateTime.now().millisecondsSinceEpoch}',
    ));
    _isolate?.kill(priority: Isolate.immediate);
    _handleWorkerTerminated('工作线程已主动销毁');
  }
}

/// 对送入识别器的切片做高保真去直流偏置与保护性动态增益
Float32List _prepareSliceForAsr(Float32List input) {
  if (input.isEmpty) return input;
  double mean = 0.0;
  for (int i = 0; i < input.length; i++) {
    mean += input[i];
  }
  mean /= input.length;

  double peak = 0.0;
  double sumSq = 0.0;
  final out = Float32List(input.length);
  for (int i = 0; i < input.length; i++) {
    final v = input[i] - mean;
    out[i] = v;
    final av = v.abs();
    if (av > peak) peak = av;
    sumSq += v * v;
  }

  final rms = sqrt(sumSq / input.length);
  // 高保真纯净识别：对微弱人声信号 (Peak < 0.25 且 RMS > 0.0001) 进行自适应平滑数字增益
  // 兼顾手机麦克风近远场低音量采集与避免削波失真 (Clipping)
  if (peak > 0.001 && rms > 0.0001 && peak < 0.25) {
    final gain = min(0.40 / peak, 4.5);
    for (int i = 0; i < out.length; i++) {
      out[i] = (out[i] * gain).clamp(-0.95, 0.95);
    }
  }
  return out;
}

/// 将 SenseVoice 富文本标签友好化转译 (保留笑声、掌声、音乐、中英混杂与情绪，过滤冗余系统控制符)
String formatSenseVoiceText(String raw) {
  if (raw.isEmpty) return '';

  String text = raw;

  // 1. 转译高价值声音事件 (以括号形式呈现，直观反映真实音频环境)
  text = text.replaceAll(RegExp(r'<\|(BGM|bgm)\|>', caseSensitive: false), ' [音乐] ');
  text = text.replaceAll(RegExp(r'<\|(Applause|applause)\|>', caseSensitive: false), ' [掌声] ');
  text = text.replaceAll(RegExp(r'<\|(Laughter|laughter)\|>', caseSensitive: false), ' [笑声] ');
  text = text.replaceAll(RegExp(r'<\|(Cry|cry)\|>', caseSensitive: false), ' [哭声] ');
  text = text.replaceAll(RegExp(r'<\|(Sneeze|sneeze)\|>', caseSensitive: false), ' [喷嚏] ');
  text = text.replaceAll(RegExp(r'<\|(Breath|breath)\|>', caseSensitive: false), ' [叹气] ');
  text = text.replaceAll(RegExp(r'<\|(Cough|cough)\|>', caseSensitive: false), ' [咳嗽] ');

  // 2. 转译强情感提示 (保留有价值的情绪色彩)
  text = text.replaceAll(RegExp(r'<\|(HAPPY|happy)\|>', caseSensitive: false), ' [喜悦] ');
  text = text.replaceAll(RegExp(r'<\|(ANGRY|angry)\|>', caseSensitive: false), ' [激动] ');
  text = text.replaceAll(RegExp(r'<\|(SAD|sad)\|>', caseSensitive: false), ' [低落] ');

  // 3. 剥离无须在正文中展示的基础控制标记 (语言标记、普通对白标记与中性平和情感)
  text = text.replaceAll(RegExp(r'<\|(zh|en|ja|ko|yue|Speech|speech|NEUTRAL|neutral)\|>', caseSensitive: false), '');

  // 4. 清理其他可能出现的未知系统控制符号
  text = text.replaceAll(RegExp(r'<\|[^|]*\|>'), '');

  // 5. 规范化空格与标点
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  return text;
}

/// 自然语句切片区间
class _VadSpeechSlice {
  final int startSample;
  final int endSample;
  final Float32List samples;
  const _VadSpeechSlice({
    required this.startSample,
    required this.endSample,
    required this.samples,
  });
}

/// 对过长的单段语音 (> 9.5 秒) 在内部静音微停顿处进行二次安全切分，
/// 杜绝手机端 ONNX Runtime 因长序列 Self-Attention 矩阵过大触发 Native OOM / SIGABRT 闪退
List<_VadSpeechSlice> _enforceMaxSliceDuration(
  _VadSpeechSlice rawSlice,
  int sampleRate,
) {
  final maxSafeSamples = (sampleRate * 9.5).floor();
  if (rawSlice.samples.length <= maxSafeSamples) {
    return [rawSlice];
  }

  final subSlices = <_VadSpeechSlice>[];
  final minSubSamples = sampleRate * 4;
  final idealSubSamples = sampleRate * 7;
  final hardSubSamples = sampleRate * 9;
  final windowSize = max(160, (sampleRate * 0.1).floor());

  int localOffset = 0;
  final full = rawSlice.samples;
  while (localOffset < full.length) {
    final remaining = full.length - localOffset;
    if (remaining <= maxSafeSamples) {
      if (remaining >= 1600) {
        subSlices.add(_VadSpeechSlice(
          startSample: rawSlice.startSample + localOffset,
          endSample: rawSlice.startSample + full.length,
          samples: Float32List.sublistView(full, localOffset, full.length),
        ));
      }
      break;
    }

    final searchStart = localOffset + minSubSamples;
    final searchEnd = min(full.length - windowSize, localOffset + hardSubSamples);
    int bestCut = min(full.length, localOffset + idealSubSamples);
    double minRms = double.infinity;

    for (int pos = searchStart; pos <= searchEnd; pos += windowSize ~/ 2) {
      double sumSq = 0.0;
      for (int k = 0; k < windowSize && (pos + k) < full.length; k++) {
        final v = full[pos + k];
        sumSq += v * v;
      }
      final rms = sqrt(sumSq / windowSize);
      if (rms < minRms) {
        minRms = rms;
        bestCut = pos + (windowSize ~/ 2);
      }
    }

    if (bestCut - localOffset >= 1600) {
      subSlices.add(_VadSpeechSlice(
        startSample: rawSlice.startSample + localOffset,
        endSample: rawSlice.startSample + bestCut,
        samples: Float32List.sublistView(full, localOffset, bestCut),
      ));
    }
    localOffset = bestCut;
  }

  return subSlices;
}

/// 解析标准 16-bit PCM WAV 头部，定位 data 数据区偏移量、字节长度与采样率
class _WavStreamHeaderInfo {
  final int sampleRate;
  final int numChannels;
  final int bitsPerSample;
  final int audioFormat;
  final int dataOffset;
  final int dataByteLength;

  const _WavStreamHeaderInfo({
    required this.sampleRate,
    required this.numChannels,
    required this.bitsPerSample,
    required this.audioFormat,
    required this.dataOffset,
    required this.dataByteLength,
  });

  int get bytesPerSample => (bitsPerSample ~/ 8).clamp(1, 8);
  int get bytesPerFrame => bytesPerSample * max(1, numChannels);
  int get totalFrames => dataByteLength ~/ max(1, bytesPerFrame);
}

_WavStreamHeaderInfo? _parseWavHeader(RandomAccessFile raf, int fileLength) {
  if (fileLength < 44) return null;
  raf.setPositionSync(0);
  final headerBytes = raf.readSync(min(fileLength, 4096));
  if (headerBytes.length < 44) return null;

  final bd = ByteData.sublistView(headerBytes);
  final riff = String.fromCharCodes(headerBytes.sublist(0, 4));
  final wave = String.fromCharCodes(headerBytes.sublist(8, 12));
  if ((riff != 'RIFF' && riff != 'RIFX') || wave != 'WAVE') return null;

  int audioFormat = 1;
  int numChannels = 1;
  int sampleRate = 16000;
  int bitsPerSample = 16;
  int offset = 12;

  while (offset + 8 <= headerBytes.length) {
    final chunkId = String.fromCharCodes(headerBytes.sublist(offset, offset + 4));
    final chunkSize = bd.getUint32(offset + 4, Endian.little);
    final chunkDataStart = offset + 8;

    if (chunkId == 'fmt ') {
      if (chunkDataStart + 16 > headerBytes.length) break;
      audioFormat = bd.getUint16(chunkDataStart, Endian.little);
      numChannels = bd.getUint16(chunkDataStart + 2, Endian.little);
      sampleRate = bd.getUint32(chunkDataStart + 4, Endian.little);
      bitsPerSample = bd.getUint16(chunkDataStart + 14, Endian.little);
      if (audioFormat == 0xFFFE && chunkSize >= 40 && chunkDataStart + 26 <= headerBytes.length) {
        audioFormat = bd.getUint16(chunkDataStart + 24, Endian.little);
      }
    } else if (chunkId == 'data') {
      final remaining = fileLength - chunkDataStart;
      final dataLen = (chunkSize == 0 || chunkSize > remaining) ? remaining : chunkSize;
      if (dataLen <= 0 || numChannels <= 0 || sampleRate <= 0) return null;
      return _WavStreamHeaderInfo(
        sampleRate: sampleRate,
        numChannels: numChannels,
        bitsPerSample: bitsPerSample,
        audioFormat: audioFormat,
        dataOffset: chunkDataStart,
        dataByteLength: dataLen,
      );
    }

    final paddedSize = (chunkSize + 1) & ~1;
    if (paddedSize < 0 || chunkDataStart + paddedSize <= offset) break;
    offset = chunkDataStart + paddedSize;
  }
  return null;
}

/// 工作线程入口函数 (运行在独立 Isolate 中)
void _inferenceWorkerEntryPoint(SendPort hostSendPort) {
  // 必须在子 Isolate 中初始化 sherpa-onnx 原生 FFI 绑定
  if (!kIsWeb) {
    try {
      String? dylibDir;
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        if (File(p.join(exeDir, 'sherpa-onnx-c-api.dll')).existsSync()) {
          dylibDir = exeDir;
        }
      }
      sherpa.initBindings(dylibDir);
    } catch (e) {
      debugPrint('[InferenceWorker] Isolate 原生 sherpa-onnx 绑定加载失败: $e');
    }
  }

  final workerReceivePort = ReceivePort();
  hostSendPort.send(workerReceivePort.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  sherpa.SpeakerEmbeddingExtractor? embeddingExtractor;
  OnlineCentroidBank centroidBank = OnlineCentroidBank(
    similarityThreshold: AppConstants.speakerSimilarityThreshold,
    emaAlpha: AppConstants.emaAlpha,
  );
  String lastTaskId = '';
  String lastSliceText = '';
  String lastLiveChunkText = '';
  String? cancelledTaskId;

  /// 根据配置构建 sherpa-onnx 离线识别器模型配置 (支持 SenseVoice / Paraformer / Qwen3-ASR / Parakeet)
  sherpa.OfflineModelConfig buildModelConfig(ModelConfig config) {
    final activeId = config.activeAsrModelId;

    // 1. Paraformer-zh 阿里达摩院工业级中文
    if (activeId == 'paraformer_zh' && config.isParaformerReady) {
      debugPrint('[InferenceWorker] 装载 ASR 引擎: Paraformer-zh');
      return sherpa.OfflineModelConfig(
        paraformer: sherpa.OfflineParaformerModelConfig(
          model: config.paraformerModelPath,
        ),
        tokens: config.paraformerTokensPath,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    // 2. Qwen3-ASR 0.6B 通义千问大模型语义识别
    if (activeId == 'qwen3_asr' && config.isQwen3Ready) {
      debugPrint('[InferenceWorker] 装载 ASR 引擎: Qwen3-ASR 0.6B');
      return sherpa.OfflineModelConfig(
        qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
          convFrontend: config.qwen3ConvFrontendPath,
          encoder: config.qwen3EncoderPath,
          decoder: config.qwen3DecoderPath,
          tokenizer: config.qwen3TokenizerPath,
          hotwords: config.hotwords,
        ),
        tokens: '',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    // 3. Parakeet-TDT 0.6B NVIDIA Transducer
    if (activeId == 'parakeet_tdt' && config.isParakeetReady) {
      debugPrint('[InferenceWorker] 装载 ASR 引擎: Parakeet-TDT 0.6B');
      return sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: config.parakeetEncoderPath,
          decoder: config.parakeetDecoderPath,
          joiner: config.parakeetJoinerPath,
        ),
        tokens: config.parakeetTokensPath,
        modelType: 'nemo_transducer',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    // 4. SenseVoice-Small (默认高兼容性)
    if (config.isSenseVoiceReady) {
      debugPrint('[InferenceWorker] 装载 ASR 引擎: SenseVoice-Small');
      return sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: config.senseVoiceModelPath,
          language: config.preferredLanguage.isNotEmpty ? config.preferredLanguage : 'zh',
          useInverseTextNormalization: true,
        ),
        tokens: config.senseVoiceTokensPath,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    // 自动回退保护：尝试任一已就绪的模型
    if (config.isParaformerReady) {
      debugPrint('[InferenceWorker] 回退装载就绪引擎: Paraformer-zh');
      return sherpa.OfflineModelConfig(
        paraformer: sherpa.OfflineParaformerModelConfig(
          model: config.paraformerModelPath,
        ),
        tokens: config.paraformerTokensPath,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    if (config.isQwen3Ready) {
      debugPrint('[InferenceWorker] 回退装载就绪引擎: Qwen3-ASR');
      return sherpa.OfflineModelConfig(
        qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
          convFrontend: config.qwen3ConvFrontendPath,
          encoder: config.qwen3EncoderPath,
          decoder: config.qwen3DecoderPath,
          tokenizer: config.qwen3TokenizerPath,
          hotwords: config.hotwords,
        ),
        tokens: '',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    if (config.isParakeetReady) {
      debugPrint('[InferenceWorker] 回退装载就绪引擎: Parakeet-TDT');
      return sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: config.parakeetEncoderPath,
          decoder: config.parakeetDecoderPath,
          joiner: config.parakeetJoinerPath,
        ),
        tokens: config.parakeetTokensPath,
        modelType: 'nemo_transducer',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }

    throw Exception('未找到任何已完整部署的 ASR 语音识别模型资产，请先在模型管理中心下载部署。');
  }

  /// 对单个安全切片执行识别 + 上下文清洗 + 声纹聚类并汇报段落
  TranscriptSegmentPayload? recognizeAndDiarizeSlice({
    required _VadSpeechSlice slice,
    required int sampleRate,
    required String taskId,
    required int segmentIndex,
    required bool enableDiarization,
  }) {
    if (slice.samples.length < 1600 || recognizer == null) return null;

    final startMs = (slice.startSample * 1000) ~/ sampleRate;
    final endMs = (slice.endSample * 1000) ~/ sampleRate;
    final normalized = _prepareSliceForAsr(slice.samples);

    String recognizedText = '';
    final words = <WordTimestamp>[];
    final stream = recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: normalized, sampleRate: sampleRate);
      recognizer!.decode(stream);
      final result = recognizer!.getResult(stream);
      // 1. 转译 SenseVoice 特殊标记并进行基础清洗
      final rawFormatted = formatSenseVoiceText(result.text);
      recognizedText = TranscriptCleaner.cleanRawText(rawFormatted);

      // 2. 提取 Token / Word 级精确时间戳 (解决时间错位，提供词级别音字同步)
      if (result.tokens.isNotEmpty && result.timestamps.length == result.tokens.length) {
        for (int i = 0; i < result.tokens.length; i++) {
          final tok = result.tokens[i].trim();
          if (tok.isEmpty || tok.startsWith('<|') || tok.startsWith('[')) continue;
          final tokStart = startMs + (result.timestamps[i] * 1000).toInt();
          final tokEnd = (i + 1 < result.timestamps.length)
              ? startMs + (result.timestamps[i + 1] * 1000).toInt()
              : min(endMs, tokStart + 350);
          words.add(WordTimestamp(
            word: tok,
            startMs: tokStart,
            endMs: max(tokStart + 10, tokEnd),
          ));
        }
      }

      // 3. 跨切片首尾重叠消除 (Contextual Deduplication)
      if (lastSliceText.isNotEmpty && recognizedText.isNotEmpty) {
        recognizedText = TranscriptCleaner.removeOverlap(lastSliceText, recognizedText);
      }
      if (recognizedText.isNotEmpty) {
        lastSliceText = recognizedText;
      }
    } finally {
      stream.free();
    }

    if (recognizedText.isEmpty) return null;

    String assignedSpeakerId = 'SPK_01';
    String assignedSpeakerName = '发言人 1';

    if (enableDiarization &&
        embeddingExtractor != null &&
        normalized.length >= (sampleRate * 0.75).floor()) {
      try {
        // 声纹提取最多取该句前 6 秒，避免长句提取耗费过多内存与算力
        final maxSpkSamples = min(normalized.length, sampleRate * 6);
        final spkInput = maxSpkSamples < normalized.length
            ? Float32List.sublistView(normalized, 0, maxSpkSamples)
            : normalized;
        final spkStream = embeddingExtractor!.createStream();
        try {
          spkStream.acceptWaveform(samples: spkInput, sampleRate: sampleRate);
          spkStream.inputFinished();
          if (embeddingExtractor!.isReady(spkStream)) {
            final embedding = embeddingExtractor!.compute(spkStream);
            if (embedding.isNotEmpty) {
              // 引入语音识别文本语义反哺说话人分离裁决 (Semantic-Acoustic Joint Diarization)
              final diar = centroidBank.assignSpeaker(
                embedding: embedding,
                durationMs: endMs - startMs,
                startMs: startMs,
                endMs: endMs,
                spokenText: recognizedText,
              );
              assignedSpeakerId = diar.speakerId;
              assignedSpeakerName = diar.speakerName ??
                  '发言人 ${int.tryParse(diar.speakerId.replaceAll("SPK_", "")) ?? 1}';
            }
          }
        } finally {
          spkStream.free();
        }
      } catch (_) {}
    }

    final payload = TranscriptSegmentPayload(
      taskId: taskId,
      speakerId: assignedSpeakerId,
      speakerName: assignedSpeakerName,
      startMs: startMs,
      endMs: endMs,
      text: recognizedText,
      words: words,
    );

    hostSendPort.send(SegmentTranscriptionResponse(
      messageId: 'seg_${taskId}_$segmentIndex',
      taskId: taskId,
      segmentIndex: segmentIndex,
      speakerId: assignedSpeakerId,
      speakerName: assignedSpeakerName,
      startMs: startMs,
      endMs: endMs,
      text: recognizedText,
      words: words,
      isFinal: true,
      isSuccess: true,
    ));

    return payload;
  }

  workerReceivePort.listen((message) {
    if (message is InitWorkerCommand) {
      try {
        final config = message.config;

        final featConfig = sherpa.FeatureConfig(
          sampleRate: 16000,
          featureDim: 80,
        );
        final modelConfig = buildModelConfig(config);
        final recognizerConfig = sherpa.OfflineRecognizerConfig(
          feat: featConfig,
          model: modelConfig,
        );
        recognizer = sherpa.OfflineRecognizer(recognizerConfig);

        if (config.isVadReady) {
          try {
            final sileroConfig = sherpa.SileroVadModelConfig(
              model: config.vadModelPath,
              minSilenceDuration: 0.4,
              minSpeechDuration: 0.2,
              windowSize: 512,
              maxSpeechDuration: 9.0,
            );
            vad = sherpa.VoiceActivityDetector(
              config: sherpa.VadModelConfig(
                sileroVad: sileroConfig,
                sampleRate: 16000,
                numThreads: 1,
                provider: 'cpu',
              ),
              bufferSizeInSeconds: 60,
            );
          } catch (e) {
            debugPrint('[InferenceWorker] Silero-VAD 初始化警告: $e');
          }
        }

        // 若 CAM++ / 3D-Speaker 声纹特征提取模型存在且校验完整，则加载声纹提取器支持多角色分离
        if (config.isCamppReady && config.camppModelPath != null) {
          try {
            embeddingExtractor = sherpa.SpeakerEmbeddingExtractor(
              config: sherpa.SpeakerEmbeddingExtractorConfig(
                model: config.camppModelPath!,
                numThreads: 1,
                debug: false,
                provider: 'cpu',
              ),
            );
          } catch (e) {
            debugPrint('[InferenceWorker] 声纹提取器加载警告: $e');
          }
        }

        hostSendPort.send(InitWorkerResponse(
          messageId: message.messageId,
          isSuccess: true,
          isModelLoaded: true,
          errorMessage: null,
        ));
      } catch (e) {
        hostSendPort.send(InitWorkerResponse(
          messageId: message.messageId,
          isSuccess: false,
          isModelLoaded: false,
          errorMessage: e.toString(),
        ));
      }
    } else if (message is TranscribeChunkCommand) {
      try {
        if (recognizer == null) {
          throw StateError('离线语音识别器未就绪或加载失败，无法转写');
        }

        // 严密防御：极短片段 (< 800 采样点 / 50ms) 直接安全跳过，绝不送入底层 C++ 算子引发 SIGFPE/崩盘
        if (message.samples.length < 800) {
          hostSendPort.send(SegmentTranscriptionResponse(
            messageId: message.messageId,
            taskId: message.taskId,
            segmentIndex: message.chunkIndex,
            speakerId: 'SPK_01',
            speakerName: '发言人 1',
            startMs: message.startMs,
            endMs: message.endMs,
            text: '',
            isFinal: true,
            isSuccess: true,
          ));
          return;
        }

        if (message.taskId != lastTaskId) {
          lastTaskId = message.taskId;
          lastLiveChunkText = '';
          centroidBank = OnlineCentroidBank(
            similarityThreshold: AppConstants.speakerSimilarityThreshold,
            emaAlpha: AppConstants.emaAlpha,
          );
        }

        final normalizedSamples = _prepareSliceForAsr(message.samples);

        // 使用 try-finally 确保 Stream 无论任何异常都安全释放，彻底杜绝底层句柄泄露
        String recognizedText = '';
        final words = <WordTimestamp>[];
        final stream = recognizer!.createStream();
        try {
          stream.acceptWaveform(samples: normalizedSamples, sampleRate: 16000);
          recognizer!.decode(stream);
          final result = recognizer!.getResult(stream);
          final raw = formatSenseVoiceText(result.text);
          recognizedText = TranscriptCleaner.cleanRawText(raw);

          // 提取 Token / Word 级精确时间戳
          if (result.tokens.isNotEmpty && result.timestamps.length == result.tokens.length) {
            for (int i = 0; i < result.tokens.length; i++) {
              final tok = result.tokens[i].trim();
              if (tok.isEmpty || tok.startsWith('<|') || tok.startsWith('[')) continue;
              final tokStart = message.startMs + (result.timestamps[i] * 1000).toInt();
              final tokEnd = (i + 1 < result.timestamps.length)
                  ? message.startMs + (result.timestamps[i + 1] * 1000).toInt()
                  : min(message.endMs, tokStart + 350);
              words.add(WordTimestamp(
                word: tok,
                startMs: tokStart,
                endMs: max(tokStart + 10, tokEnd),
              ));
            }
          }

          if (lastLiveChunkText.isNotEmpty && recognizedText.isNotEmpty) {
            recognizedText = TranscriptCleaner.removeOverlap(lastLiveChunkText, recognizedText);
          }
          if (recognizedText.isNotEmpty) {
            lastLiveChunkText = recognizedText;
          }
        } finally {
          stream.free();
        }

        String assignedSpeakerId = 'SPK_01';
        String assignedSpeakerName = '发言人 1';

        // 若识别出有效文本且声纹模型就绪，提取真实声纹向量并聚类发言人
        if (recognizedText.isNotEmpty &&
            embeddingExtractor != null &&
            normalizedSamples.length >= 12000) {
          try {
            final maxSpkSamples = min(normalizedSamples.length, 16000 * 6);
            final spkInput = maxSpkSamples < normalizedSamples.length
                ? Float32List.sublistView(normalizedSamples, 0, maxSpkSamples)
                : normalizedSamples;
            final spkStream = embeddingExtractor!.createStream();
            try {
              spkStream.acceptWaveform(samples: spkInput, sampleRate: 16000);
              spkStream.inputFinished();
              if (embeddingExtractor!.isReady(spkStream)) {
                final embedding = embeddingExtractor!.compute(spkStream);
                if (embedding.isNotEmpty) {
                  final diar = centroidBank.assignSpeaker(
                    embedding: embedding,
                    durationMs: message.endMs - message.startMs,
                    startMs: message.startMs,
                    endMs: message.endMs,
                    spokenText: recognizedText,
                  );
                  assignedSpeakerId = diar.speakerId;
                  assignedSpeakerName = diar.speakerName ??
                      '发言人 ${int.tryParse(diar.speakerId.replaceAll("SPK_", "")) ?? 1}';
                }
              }
            } finally {
              spkStream.free();
            }
          } catch (_) {}
        }

        hostSendPort.send(SegmentTranscriptionResponse(
          messageId: message.messageId,
          taskId: message.taskId,
          segmentIndex: message.chunkIndex,
          speakerId: assignedSpeakerId,
          speakerName: assignedSpeakerName,
          startMs: message.startMs,
          endMs: message.endMs,
          text: recognizedText,
          words: words,
          isFinal: true,
          isSuccess: true,
        ));
      } catch (e) {
        hostSendPort.send(SegmentTranscriptionResponse(
          messageId: message.messageId,
          taskId: message.taskId,
          segmentIndex: message.chunkIndex,
          speakerId: 'SPK_01',
          startMs: message.startMs,
          endMs: message.endMs,
          text: '',
          isSuccess: false,
          errorMessage: e.toString(),
        ));
      }
    } else if (message is TranscribeFileCommand) {
      if (cancelledTaskId == message.taskId) {
        cancelledTaskId = null;
      }
      try {
        if (recognizer == null) {
          throw StateError('离线语音识别器未就绪或加载失败，无法转写');
        }

        lastSliceText = '';
        centroidBank = OnlineCentroidBank(
          similarityThreshold: AppConstants.speakerSimilarityThreshold,
          emaAlpha: AppConstants.emaAlpha,
        );
        final audioFile = File(message.audioFilePath);
        if (!audioFile.existsSync()) {
          throw Exception('待转写音频文件不存在: ${message.audioFilePath}');
        }

        final fileLength = audioFile.lengthSync();
        final raf = audioFile.openSync(mode: FileMode.read);
        final segments = <TranscriptSegmentPayload>[];
        int totalDurationMs = 0;

        try {
          final header = _parseWavHeader(raf, fileLength);
          if (header != null &&
              header.audioFormat == 1 &&
              header.bitsPerSample == 16 &&
              header.totalFrames > 0) {
            // 流式分块读取 16-bit PCM WAV (每次仅读取约 15 秒数据，内存占用恒定 < 2MB，杜绝手机端大文件 OOM)
            final sampleRate = header.sampleRate;
            final totalFrames = header.totalFrames;
            totalDurationMs = (totalFrames * 1000) ~/ sampleRate;
            final bytesPerFrame = header.bytesPerFrame;
            final chunkFrames = sampleRate * 15; // 每次流式读取 15 秒
            final chunkByteCap = chunkFrames * bytesPerFrame;

            // 支持断点续转：若指定了 startOffsetMs，换算为起始采样点与字节偏移
            final int startSampleOffset = message.startOffsetMs > 0
                ? ((message.startOffsetMs * sampleRate) ~/ 1000).clamp(0, totalFrames)
                : 0;
            final int startByteOffset = startSampleOffset * bytesPerFrame;

            vad?.reset();
            const vadWin = 512;
            final vadRemainder = Float32List(vadWin);
            int vadRemCount = 0;

            // 当 VAD 未部署时的流式能量切分滑动缓冲
            final energyBuffer = <double>[];
            int energyBufferStartSample = startSampleOffset;

            int framesReadTotal = startSampleOffset;
            int byteCursor = header.dataOffset + startByteOffset;
            final dataEndByte = header.dataOffset + header.dataByteLength;
            int segCounter = message.initialSegmentIndex;

            void drainVadSegments() {
              if (vad == null) return;
              while (!vad!.isEmpty()) {
                final seg = vad!.front();
                vad!.pop();
                if (seg.samples.length >= 1600) {
                  final rawSlice = _VadSpeechSlice(
                    startSample: startSampleOffset + seg.start,
                    endSample: startSampleOffset + seg.start + seg.samples.length,
                    samples: seg.samples,
                  );
                  final safeSubSlices = _enforceMaxSliceDuration(rawSlice, sampleRate);
                  for (final sub in safeSubSlices) {
                    final payload = recognizeAndDiarizeSlice(
                      slice: sub,
                      sampleRate: sampleRate,
                      taskId: message.taskId,
                      segmentIndex: segCounter,
                      enableDiarization: message.enableDiarization,
                    );
                    if (payload != null) {
                      segments.add(payload);
                      segCounter++;
                    }
                  }
                }
              }
            }

            void processEnergyBuffer({required bool isFinalFlush}) {
              final minChunk = sampleRate * 3;
              final idealMax = sampleRate * 7;
              final hardMax = sampleRate * 9;
              final winSize = max(160, (sampleRate * 0.12).floor());

              while (energyBuffer.isNotEmpty) {
                final avail = energyBuffer.length;
                if (!isFinalFlush && avail < hardMax + winSize) {
                  break;
                }
                if (avail <= idealMax) {
                  if (isFinalFlush) {
                    if (avail >= 1600) {
                      final sliceSamples = Float32List.fromList(energyBuffer);
                      final rawSlice = _VadSpeechSlice(
                        startSample: energyBufferStartSample,
                        endSample: energyBufferStartSample + avail,
                        samples: sliceSamples,
                      );
                      final payload = recognizeAndDiarizeSlice(
                        slice: rawSlice,
                        sampleRate: sampleRate,
                        taskId: message.taskId,
                        segmentIndex: segCounter,
                        enableDiarization: message.enableDiarization,
                      );
                      if (payload != null) {
                        segments.add(payload);
                        segCounter++;
                      }
                    }
                    energyBufferStartSample += avail;
                    energyBuffer.clear();
                  }
                  break;
                }

                final searchStart = minChunk;
                final searchEnd = min(avail - winSize, hardMax);
                int bestCut = min(avail, idealMax);
                double minRms = double.infinity;

                for (int pos = searchStart; pos <= searchEnd; pos += winSize ~/ 2) {
                  double sumSq = 0.0;
                  for (int k = 0; k < winSize && (pos + k) < avail; k++) {
                    final v = energyBuffer[pos + k];
                    sumSq += v * v;
                  }
                  final rms = sqrt(sumSq / winSize);
                  if (rms < 0.012 && pos >= sampleRate * 4) {
                    bestCut = pos + (winSize ~/ 2);
                    break;
                  }
                  if (rms < minRms) {
                    minRms = rms;
                    bestCut = pos + (winSize ~/ 2);
                  }
                }

                if (bestCut >= 1600) {
                  final subList = energyBuffer.sublist(0, bestCut);
                  final rawSlice = _VadSpeechSlice(
                    startSample: energyBufferStartSample,
                    endSample: energyBufferStartSample + bestCut,
                    samples: Float32List.fromList(subList),
                  );
                  final payload = recognizeAndDiarizeSlice(
                    slice: rawSlice,
                    sampleRate: sampleRate,
                    taskId: message.taskId,
                    segmentIndex: segCounter,
                    enableDiarization: message.enableDiarization,
                  );
                  if (payload != null) {
                    segments.add(payload);
                    segCounter++;
                  }
                }
                energyBuffer.removeRange(0, bestCut);
                energyBufferStartSample += bestCut;
              }
            }

            raf.setPositionSync(byteCursor);
            while (byteCursor < dataEndByte) {
              if (cancelledTaskId == message.taskId) {
                debugPrint('[InferenceWorker] 收到任务中断信号，终止转写文件: ${message.taskId}');
                break;
              }
              final bytesToRead = min(chunkByteCap, dataEndByte - byteCursor);
              final alignedBytes = (bytesToRead ~/ bytesPerFrame) * bytesPerFrame;
              if (alignedBytes <= 0) break;

              final rawBytes = raf.readSync(alignedBytes);
              if (rawBytes.isEmpty) break;
              byteCursor += rawBytes.length;

              final bd = ByteData.sublistView(rawBytes);
              final frameCount = rawBytes.length ~/ bytesPerFrame;
              final chunkSamples = Float32List(frameCount);
              final ch = header.numChannels;

              for (int f = 0; f < frameCount; f++) {
                final fStart = f * bytesPerFrame;
                double sum = 0.0;
                for (int c = 0; c < ch; c++) {
                  final s16 = bd.getInt16(fStart + c * 2, Endian.little);
                  sum += s16 / 32768.0;
                }
                chunkSamples[f] = (sum / ch).clamp(-1.0, 1.0);
              }

              framesReadTotal += frameCount;
              final progressRatio = (framesReadTotal / max(1, totalFrames)).clamp(0.0, 1.0);
              final currentMs = (framesReadTotal * 1000) ~/ sampleRate;
              final currentSec = currentMs ~/ 1000;
              final totalSec = totalDurationMs ~/ 1000;
              final currTimeStr = '${(currentSec ~/ 60).toString().padLeft(2, '0')}:${(currentSec % 60).toString().padLeft(2, '0')}';
              final totalTimeStr = '${(totalSec ~/ 60).toString().padLeft(2, '0')}:${(totalSec % 60).toString().padLeft(2, '0')}';
              final pctStr = (progressRatio * 100).toStringAsFixed(1);
              hostSendPort.send(WorkerProgressNotification(
                taskId: message.taskId,
                progress: 0.25 + progressRatio * 0.65,
                stageDescription:
                    '正在离线转写 [$currTimeStr / $totalTimeStr] ($pctStr% · 已生成 ${segments.length + message.initialSegmentIndex} 段)...',
              ));

              if (vad != null) {
                int idx = 0;
                while (idx < chunkSamples.length) {
                  final space = vadWin - vadRemCount;
                  final take = min(space, chunkSamples.length - idx);
                  for (int k = 0; k < take; k++) {
                    vadRemainder[vadRemCount + k] = chunkSamples[idx + k];
                  }
                  vadRemCount += take;
                  idx += take;

                  if (vadRemCount == vadWin) {
                    vad!.acceptWaveform(vadRemainder);
                    vadRemCount = 0;
                    drainVadSegments();
                  }
                }
              } else {
                energyBuffer.addAll(chunkSamples);
                processEnergyBuffer(isFinalFlush: false);
              }
            }

            // 刷出尾部剩余采样点
            if (vad != null) {
              if (vadRemCount > 0) {
                for (int k = vadRemCount; k < vadWin; k++) {
                  vadRemainder[k] = 0.0;
                }
                vad!.acceptWaveform(vadRemainder);
                vadRemCount = 0;
              }
              vad!.flush();
              drainVadSegments();
            } else {
              processEnergyBuffer(isFinalFlush: true);
            }
          } else {
            // 兜底：若非标准 16-bit WAV，使用 sherpa.readWave 读取但对长切片做严格安全截断
            final waveObj = sherpa.readWave(message.audioFilePath);
            if (waveObj.samples.isEmpty) {
              throw Exception('音频文件波形解析为空');
            }
            final fullSamples = waveObj.samples;
            final sampleRate = waveObj.sampleRate > 0 ? waveObj.sampleRate : 16000;
            totalDurationMs = (fullSamples.length * 1000) ~/ sampleRate;

            final startSampleOffset = message.startOffsetMs > 0
                ? ((message.startOffsetMs * sampleRate) ~/ 1000).clamp(0, fullSamples.length)
                : 0;
            final subWaveSamples = startSampleOffset > 0
                ? Float32List.sublistView(fullSamples, startSampleOffset)
                : fullSamples;

            final fallbackSlices = _enforceMaxSliceDuration(
              _VadSpeechSlice(
                startSample: startSampleOffset,
                endSample: fullSamples.length,
                samples: subWaveSamples,
              ),
              sampleRate,
            );
            int segCounter = message.initialSegmentIndex;
            for (int i = 0; i < fallbackSlices.length; i++) {
              final progressRatio = (i + 1) / max(1, fallbackSlices.length);
              hostSendPort.send(WorkerProgressNotification(
                taskId: message.taskId,
                progress: 0.25 + progressRatio * 0.65,
                stageDescription: '正在转写自然语句 (${i + 1}/${fallbackSlices.length} · 已生成 ${segments.length + message.initialSegmentIndex} 段)...',
              ));
              final payload = recognizeAndDiarizeSlice(
                slice: fallbackSlices[i],
                sampleRate: sampleRate,
                taskId: message.taskId,
                segmentIndex: segCounter,
                enableDiarization: message.enableDiarization,
              );
              if (payload != null) {
                segments.add(payload);
                segCounter++;
              }
            }
          }
        } finally {
          raf.closeSync();
        }

        // 第二道全局声纹聚类收敛：合并相似度 >= 0.42 的冗余角色，彻底消除同一发言人多角色误切
        if (message.enableDiarization) {
          final speakerMergeMap = centroidBank.consolidateSpeakers(mergeThreshold: 0.42);
          if (speakerMergeMap.isNotEmpty) {
            for (int i = 0; i < segments.length; i++) {
              final oldSpk = segments[i].speakerId;
              final targetSpk = speakerMergeMap[oldSpk];
              if (targetSpk != null) {
                final newIndex = int.tryParse(targetSpk.replaceAll('SPK_', '')) ?? 1;
                segments[i] = TranscriptSegmentPayload(
                  taskId: segments[i].taskId,
                  speakerId: targetSpk,
                  speakerName: '发言人 $newIndex',
                  startMs: segments[i].startMs,
                  endMs: segments[i].endMs,
                  text: segments[i].text,
                );
              }
            }
          }
        }

        // 纯静音/无对白容错保护 (仅在从第 0 秒开始且总段落为空时添加系统提示)
        if (segments.isEmpty && message.initialSegmentIndex == 0) {
          segments.add(TranscriptSegmentPayload(
            taskId: message.taskId,
            speakerId: 'SPK_01',
            speakerName: '系统提示',
            startMs: 0,
            endMs: max(1000, totalDurationMs),
            text: '（该段音频已完成全量扫描，未检测到清晰的人声对白或声音事件）',
          ));
        }

        hostSendPort.send(TranscribeFileResponse(
          messageId: message.messageId,
          isSuccess: true,
          taskId: message.taskId,
          segments: segments,
          totalDurationMs: totalDurationMs,
        ));
      } catch (e) {
        hostSendPort.send(TranscribeFileResponse(
          messageId: message.messageId,
          isSuccess: false,
          taskId: message.taskId,
          segments: [],
          totalDurationMs: 0,
          errorMessage: e.toString(),
        ));
      }
    } else if (message is CancelTaskCommand) {
      cancelledTaskId = message.taskId;
      debugPrint('[InferenceWorker] 收到取消指令并标记任务: ${message.taskId}');
    } else if (message is DisposeWorkerCommand) {
      recognizer?.free();
      vad?.free();
      embeddingExtractor?.free();
      workerReceivePort.close();
    }
  });
}
