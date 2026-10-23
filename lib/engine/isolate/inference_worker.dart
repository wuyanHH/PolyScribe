import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../diarization/online_centroid_bank.dart';
import '../model_manager.dart';
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
  bool _isModelLoaded = false;
  Future<bool>? _initializingFuture;
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

  /// 初始化并启动工作线程 Isolate (支持并发重入保护与失败重试)
  Future<bool> initialize(ModelConfig config) async {
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
      debugName: 'InferenceWorkerIsolate',
    );

    _workerSendPort = await readyCompleter.future;

    // 发送初始化模型指令
    final initMsgId = 'init_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<WorkerResponse>();
    _pendingRequests[initMsgId] = completer;

    _workerSendPort!.send(InitWorkerCommand(
      messageId: initMsgId,
      config: config,
    ));

    final response = await completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => const InitWorkerResponse(
        messageId: 'timeout',
        isSuccess: false,
        isModelLoaded: false,
        errorMessage: '工作线程初始化超时',
      ),
    );

    _isModelLoaded = response.isSuccess;
    debugPrint('[InferenceWorker] 初始化结果: ${response.isSuccess}, err: ${response.errorMessage}');
    return response.isSuccess;
  }

  /// 发送音频切片转写
  Future<SegmentTranscriptionResponse?> transcribeChunk(TranscribeChunkCommand cmd) async {
    if (_workerSendPort == null) return null;

    final completer = Completer<WorkerResponse>();
    _pendingRequests[cmd.messageId] = completer;
    _workerSendPort!.send(cmd);

    final res = await completer.future;
    if (res is SegmentTranscriptionResponse) return res;
    return null;
  }

  /// 发送离线完整音频文件转写请求 (支持 Silero-VAD 神经网络自然语音切句与多角色纯净聚类)
  Future<TranscribeFileResponse?> transcribeFile(TranscribeFileCommand cmd) async {
    if (_workerSendPort == null) return null;

    final completer = Completer<WorkerResponse>();
    _pendingRequests[cmd.messageId] = completer;
    _workerSendPort!.send(cmd);

    final res = await completer.future;
    if (res is TranscribeFileResponse) return res;
    return null;
  }

  /// 销毁并退出工作线程
  Future<void> dispose() async {
    _workerSendPort?.send(DisposeWorkerCommand(
      messageId: 'dispose_${DateTime.now().millisecondsSinceEpoch}',
    ));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerSendPort = null;
    _isModelLoaded = false;
    _hostReceivePort?.close();
    _hostReceivePort = null;
  }
}

/// 对送入识别器的切片做局部弱音增益与去直流偏置
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
  // 若有微弱人声信号但振幅过小，自动提振到最佳识别区间
  if (peak > 0.002 && rms > 0.0003 && peak < 0.65) {
    final gain = min(0.82 / peak, 20.0);
    for (int i = 0; i < out.length; i++) {
      out[i] = (out[i] * gain).clamp(-1.0, 1.0);
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

/// 使用 Silero-VAD 神经网络进行高精度自然语句切分 (剔除留白静音，杜绝混合声纹)
List<_VadSpeechSlice> _sliceAudioWithSileroVad({
  required sherpa.VoiceActivityDetector vad,
  required Float32List fullSamples,
  required int sampleRate,
}) {
  vad.reset();
  const windowSize = 512;
  final slices = <_VadSpeechSlice>[];

  for (int offset = 0; offset < fullSamples.length; offset += windowSize) {
    final end = min(offset + windowSize, fullSamples.length);
    final count = end - offset;
    final chunk = Float32List(windowSize);
    for (int k = 0; k < count; k++) {
      chunk[k] = fullSamples[offset + k];
    }
    vad.acceptWaveform(chunk);

    while (!vad.isEmpty()) {
      final seg = vad.front();
      if (seg.samples.length >= 1600) {
        final startSample = seg.start;
        final endSample = startSample + seg.samples.length;
        slices.add(_VadSpeechSlice(
          startSample: startSample,
          endSample: endSample,
          samples: seg.samples,
        ));
      }
      vad.pop();
    }
  }

  vad.flush();
  while (!vad.isEmpty()) {
    final seg = vad.front();
    if (seg.samples.length >= 1600) {
      final startSample = seg.start;
      final endSample = startSample + seg.samples.length;
      slices.add(_VadSpeechSlice(
        startSample: startSample,
        endSample: endSample,
        samples: seg.samples,
      ));
    }
    vad.pop();
  }

  return slices;
}

/// 当 VAD 模型不可用时的能量平滑切分降级算法
List<_VadSpeechSlice> _sliceAudioWithEnergyFallback({
  required Float32List fullSamples,
  required int sampleRate,
}) {
  final slices = <_VadSpeechSlice>[];
  if (fullSamples.isEmpty) return slices;

  final minChunkSamples = sampleRate * 3;
  final idealMaxSamples = sampleRate * 8;
  final hardMaxSamples = sampleRate * 12;
  final windowSize = (sampleRate * 0.12).floor();

  int offset = 0;
  while (offset < fullSamples.length) {
    final remaining = fullSamples.length - offset;
    if (remaining <= idealMaxSamples) {
      if (remaining >= 1600) {
        slices.add(_VadSpeechSlice(
          startSample: offset,
          endSample: fullSamples.length,
          samples: fullSamples.sublist(offset, fullSamples.length),
        ));
      }
      break;
    }

    final searchStart = offset + minChunkSamples;
    final searchEnd = min(fullSamples.length - windowSize, offset + hardMaxSamples);
    int bestCutPoint = min(fullSamples.length, offset + idealMaxSamples);
    double minWindowRms = double.infinity;

    for (int pos = searchStart; pos <= searchEnd; pos += windowSize ~/ 2) {
      double sumSq = 0.0;
      for (int k = 0; k < windowSize && (pos + k) < fullSamples.length; k++) {
        final v = fullSamples[pos + k];
        sumSq += v * v;
      }
      final rms = sqrt(sumSq / windowSize);
      if (rms < 0.012 && (pos - offset) >= sampleRate * 4) {
        bestCutPoint = pos + (windowSize ~/ 2);
        break;
      }
      if (rms < minWindowRms) {
        minWindowRms = rms;
        bestCutPoint = pos + (windowSize ~/ 2);
      }
    }

    if (bestCutPoint - offset >= 1600) {
      slices.add(_VadSpeechSlice(
        startSample: offset,
        endSample: bestCutPoint,
        samples: fullSamples.sublist(offset, bestCutPoint),
      ));
    }
    offset = bestCutPoint;
  }
  return slices;
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
  OnlineCentroidBank centroidBank = OnlineCentroidBank(similarityThreshold: 0.58);
  String lastTaskId = '';

  workerReceivePort.listen((message) {
    if (message is InitWorkerCommand) {
      try {
        final config = message.config;

        if (config.isSenseVoiceReady) {
          // 初始化 SenseVoice-Small 识别器
          final featConfig = sherpa.FeatureConfig(
            sampleRate: 16000,
            featureDim: 80,
          );
          final modelConfig = sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: config.senseVoiceModelPath,
              language: 'auto',
              useInverseTextNormalization: true,
            ),
            tokens: config.senseVoiceTokensPath,
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          );
          final recognizerConfig = sherpa.OfflineRecognizerConfig(
            feat: featConfig,
            model: modelConfig,
          );
          recognizer = sherpa.OfflineRecognizer(recognizerConfig);
        } else {
          throw Exception('SenseVoice 模型资产不完整，缺少权重文件或 tokens 字典: ${config.senseVoiceModelPath}');
        }

        if (config.isVadReady) {
          try {
            final sileroConfig = sherpa.SileroVadModelConfig(
              model: config.vadModelPath,
              minSilenceDuration: 0.4,
              minSpeechDuration: 0.2,
              windowSize: 512,
              maxSpeechDuration: 20.0,
            );
            vad = sherpa.VoiceActivityDetector(
              config: sherpa.VadModelConfig(
                sileroVad: sileroConfig,
                sampleRate: 16000,
                numThreads: 1,
                provider: 'cpu',
              ),
              bufferSizeInSeconds: 30,
            );
          } catch (e) {
            debugPrint('[InferenceWorker] Silero-VAD 初始化警告: $e');
          }
        }

        // 若 CAM++ / 3D-Speaker 声纹特征提取模型存在，则加载声纹提取器支持多角色分离
        if (config.camppModelPath != null && File(config.camppModelPath!).existsSync()) {
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
          centroidBank = OnlineCentroidBank(similarityThreshold: 0.58);
        }

        final normalizedSamples = _prepareSliceForAsr(message.samples);

        // 使用 try-finally 确保 Stream 无论任何异常都安全释放，彻底杜绝底层句柄泄露
        String recognizedText = '';
        final stream = recognizer!.createStream();
        try {
          stream.acceptWaveform(samples: normalizedSamples, sampleRate: 16000);
          recognizer!.decode(stream);
          final result = recognizer!.getResult(stream);
          recognizedText = formatSenseVoiceText(result.text);
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
            final spkStream = embeddingExtractor!.createStream();
            try {
              spkStream.acceptWaveform(samples: normalizedSamples, sampleRate: 16000);
              spkStream.inputFinished();
              if (embeddingExtractor!.isReady(spkStream)) {
                final embedding = embeddingExtractor!.compute(spkStream);
                if (embedding.isNotEmpty) {
                  final diar = centroidBank.assignSpeaker(
                    embedding: embedding,
                    durationMs: message.endMs - message.startMs,
                    startMs: message.startMs,
                    endMs: message.endMs,
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
      try {
        if (recognizer == null) {
          throw StateError('离线语音识别器未就绪或加载失败，无法转写');
        }

        centroidBank = OnlineCentroidBank(similarityThreshold: 0.60);

        final waveObj = sherpa.readWave(message.audioFilePath);
        if (waveObj.samples.isEmpty) {
          throw Exception('音频文件波形解析为空');
        }

        Float32List fullSamples = waveObj.samples;
        final sampleRate = waveObj.sampleRate > 0 ? waveObj.sampleRate : 16000;
        final totalDurationMs = (fullSamples.length * 1000) ~/ sampleRate;

        // 1. 神经网络级自然语义断句 (Silero-VAD 优先，能量分析平滑降级)
        List<_VadSpeechSlice> slices;
        if (vad != null) {
          slices = _sliceAudioWithSileroVad(
            vad: vad!,
            fullSamples: fullSamples,
            sampleRate: sampleRate,
          );
        } else {
          slices = _sliceAudioWithEnergyFallback(
            fullSamples: fullSamples,
            sampleRate: sampleRate,
          );
        }

        final segments = <TranscriptSegmentPayload>[];

        for (int i = 0; i < slices.length; i++) {
          final slice = slices[i];
          final startMs = (slice.startSample * 1000) ~/ sampleRate;
          final endMs = (slice.endSample * 1000) ~/ sampleRate;

          // 发送中间平滑进度通知 (0.28 ~ 0.90)
          final progressRatio = (i + 1) / max(1, slices.length);
          hostSendPort.send(WorkerProgressNotification(
            taskId: message.taskId,
            progress: 0.25 + progressRatio * 0.65,
            stageDescription: '正在转写自然语句 (${i + 1}/${slices.length})...',
          ));

          if (slice.samples.length < 1600) continue;

          final normalized = _prepareSliceForAsr(slice.samples);

          // ASR 识别
          String recognizedText = '';
          final stream = recognizer!.createStream();
          try {
            stream.acceptWaveform(samples: normalized, sampleRate: sampleRate);
            recognizer!.decode(stream);
            final result = recognizer!.getResult(stream);
            recognizedText = formatSenseVoiceText(result.text);
          } finally {
            stream.free();
          }

          if (recognizedText.isEmpty) continue;

          // 声纹特征提取与纯净单人聚类 (因 VAD 单句不含混合声纹，准度达到最高水准)
          String assignedSpeakerId = 'SPK_01';
          String assignedSpeakerName = '发言人 1';

          if (message.enableDiarization &&
              embeddingExtractor != null &&
              normalized.length >= 12000) {
            try {
              final spkStream = embeddingExtractor!.createStream();
              try {
                spkStream.acceptWaveform(samples: normalized, sampleRate: sampleRate);
                spkStream.inputFinished();
                if (embeddingExtractor!.isReady(spkStream)) {
                  final embedding = embeddingExtractor!.compute(spkStream);
                  if (embedding.isNotEmpty) {
                    final diar = centroidBank.assignSpeaker(
                      embedding: embedding,
                      durationMs: endMs - startMs,
                      startMs: startMs,
                      endMs: endMs,
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

          final segmentPayload = TranscriptSegmentPayload(
            taskId: message.taskId,
            speakerId: assignedSpeakerId,
            speakerName: assignedSpeakerName,
            startMs: startMs,
            endMs: endMs,
            text: recognizedText,
          );
          segments.add(segmentPayload);

          // 实时流式通知
          hostSendPort.send(SegmentTranscriptionResponse(
            messageId: 'seg_${message.taskId}_$i',
            taskId: message.taskId,
            segmentIndex: i,
            speakerId: assignedSpeakerId,
            speakerName: assignedSpeakerName,
            startMs: startMs,
            endMs: endMs,
            text: recognizedText,
            isFinal: true,
            isSuccess: true,
          ));
        }

        // 纯静音/无对白容错保护
        if (segments.isEmpty) {
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
    } else if (message is DisposeWorkerCommand) {
      recognizer?.free();
      vad?.free();
      embeddingExtractor?.free();
      workerReceivePort.close();
    }
  });
}
