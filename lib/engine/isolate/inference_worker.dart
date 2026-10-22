import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
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
  final Map<String, Completer<WorkerResponse>> _pendingRequests = {};

  final StreamController<SegmentTranscriptionResponse> _segmentStreamController =
      StreamController<SegmentTranscriptionResponse>.broadcast();

  Stream<SegmentTranscriptionResponse> get onSegmentTranscribed =>
      _segmentStreamController.stream;

  bool get isReady => _workerSendPort != null;

  /// 初始化并启动工作线程 Isolate
  Future<bool> initialize(ModelConfig config) async {
    if (_isolate != null) return true;

    final readyCompleter = Completer<SendPort>();
    _hostReceivePort = ReceivePort();

    _hostReceivePort!.listen((message) {
      if (message is SendPort) {
        readyCompleter.complete(message);
      } else if (message is WorkerResponse) {
        final completer = _pendingRequests.remove(message.messageId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message);
        }

        if (message is SegmentTranscriptionResponse) {
          _segmentStreamController.add(message);
        }
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
      const Duration(seconds: 10),
      onTimeout: () => const InitWorkerResponse(
        messageId: 'timeout',
        isSuccess: false,
        isModelLoaded: false,
        errorMessage: '工作线程初始化超时',
      ),
    );

    debugPrint('[InferenceWorker] 初始化结果: ${response.isSuccess}');
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

  /// 销毁并退出工作线程
  Future<void> dispose() async {
    _workerSendPort?.send(DisposeWorkerCommand(
      messageId: 'dispose_${DateTime.now().millisecondsSinceEpoch}',
    ));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerSendPort = null;
    _hostReceivePort?.close();
    _hostReceivePort = null;
    await _segmentStreamController.close();
  }
}

/// 工作线程入口函数 (运行在独立 Isolate 中)
void _inferenceWorkerEntryPoint(SendPort hostSendPort) {
  final workerReceivePort = ReceivePort();
  hostSendPort.send(workerReceivePort.sendPort);

  final centroidBank = OnlineCentroidBank();
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;

  workerReceivePort.listen((message) {
    if (message is InitWorkerCommand) {
      try {
        final config = message.config;
        bool loaded = false;

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
          loaded = true;
        }

        if (config.isVadReady) {
          final sileroConfig = sherpa.SileroVadModelConfig(
            model: config.vadModelPath,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
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
        }

        hostSendPort.send(InitWorkerResponse(
          messageId: message.messageId,
          isSuccess: true,
          isModelLoaded: loaded,
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
        String recognizedText = '';

        if (recognizer != null) {
          final stream = recognizer!.createStream();
          stream.acceptWaveform(samples: message.samples, sampleRate: 16000);
          recognizer!.decode(stream);
          final result = recognizer!.getResult(stream);
          recognizedText = result.text;
          stream.free();
        } else {
          // 若模型处于开发准备状态，返回示例占位文本
          recognizedText = '语音切片 #${message.chunkIndex} 转写内容就绪';
        }

        // 分配说话人
        final diarResult = centroidBank.assignSpeaker(
          embedding: Float32List(192), // 模拟或提取特征向量
          durationMs: message.endMs - message.startMs,
          startMs: message.startMs,
          endMs: message.endMs,
        );

        hostSendPort.send(SegmentTranscriptionResponse(
          messageId: message.messageId,
          taskId: message.taskId,
          segmentIndex: message.chunkIndex,
          speakerId: diarResult.speakerId,
          speakerName: diarResult.speakerName,
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
    } else if (message is DisposeWorkerCommand) {
      recognizer?.free();
      vad?.free();
      workerReceivePort.close();
    }
  });
}
