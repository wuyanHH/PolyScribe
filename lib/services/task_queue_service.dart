import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../data/database/app_database.dart';
import '../data/models/meeting_task.dart';
import '../data/models/transcript_segment.dart';
import '../engine/diarization/dual_channel_detector.dart';
import '../engine/isolate/inference_worker.dart';
import '../engine/isolate/worker_message.dart';
import '../engine/model_manager.dart';

/// 任务处理进度事件
class TaskProgressEvent {
  final String taskId;
  final double progress; // 0.0 ~ 1.0
  final String stageDescription;
  final TaskStatus status;

  const TaskProgressEvent({
    required this.taskId,
    required this.progress,
    required this.stageDescription,
    required this.status,
  });
}

/// 录音批处理调度中心 (串行防 OOM 队列)
class TaskQueueService {
  static TaskQueueService? _instance;
  static TaskQueueService get instance => _instance ??= TaskQueueService._();

  TaskQueueService._();

  final List<String> _queue = [];
  bool _isProcessing = false;

  final StreamController<TaskProgressEvent> _progressController =
      StreamController<TaskProgressEvent>.broadcast();

  Stream<TaskProgressEvent> get onProgress => _progressController.stream;

  /// 可选自定义转写处理器 (用于单元测试或自定义引擎注入)
  Future<List<TranscriptSegment>> Function(MeetingTask task, bool isStereoSeparated)? mockTranscriber;

  /// 添加音频任务到批处理队列
  Future<MeetingTask> enqueueAudioFile(String filePath, {String? customTitle}) async {
    final fileName = p.basenameWithoutExtension(filePath);
    final taskId = 'task_${DateTime.now().millisecondsSinceEpoch}_${_queue.length}';

    // 1. 将原音频立即安全拷贝到应用的私有存储目录，杜绝原文件移动或删除导致丢失
    String safeAudioPath = filePath;
    try {
      final sourceFile = File(filePath);
      if (sourceFile.existsSync()) {
        final appSupport = await getApplicationSupportDirectory();
        final audioDir = Directory(p.join(appSupport.path, 'imported_audios'));
        if (!audioDir.existsSync()) {
          audioDir.createSync(recursive: true);
        }
        final destPath = p.join(audioDir.path, '${taskId}_${p.basename(filePath)}');
        await sourceFile.copy(destPath);
        safeAudioPath = destPath;
      }
    } catch (e) {
      debugPrint('[TaskQueueService] 复制音频失败，使用原路径: $e');
    }

    final task = MeetingTask(
      id: taskId,
      title: customTitle ?? fileName,
      sourceType: TaskSourceType.importedAudio,
      audioPath: safeAudioPath,
      durationMs: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.queued,
    );

    await AppDatabase.instance.saveTask(task);
    _queue.add(taskId);
    _progressController.add(TaskProgressEvent(
      taskId: taskId,
      progress: 0.0,
      stageDescription: '排队中...',
      status: TaskStatus.queued,
    ));

    _processNext();
    return task;
  }

  /// 批量导入多个文件
  Future<List<MeetingTask>> enqueueMultipleFiles(List<String> filePaths) async {
    final tasks = <MeetingTask>[];
    for (final path in filePaths) {
      final task = await enqueueAudioFile(path);
      tasks.add(task);
    }
    return tasks;
  }

  /// 串行执行任务调度
  Future<void> _processNext() async {
    if (_isProcessing || _queue.isEmpty) return;

    _isProcessing = true;
    final taskId = _queue.removeAt(0);

    try {
      final task = await AppDatabase.instance.getTask(taskId);
      if (task == null) {
        _isProcessing = false;
        _processNext();
        return;
      }

      await _executeTask(task);
    } catch (e, stack) {
      debugPrint('[TaskQueueService] 任务执行异常: $e\n$stack');
      try {
        final currentTask = await AppDatabase.instance.getTask(taskId);
        if (currentTask != null) {
          await AppDatabase.instance.saveTask(currentTask.copyWith(status: TaskStatus.error));
        }
      } catch (dbErr) {
        debugPrint('[TaskQueueService] 更新数据库任务错误状态异常: $dbErr');
      }

      _progressController.add(TaskProgressEvent(
        taskId: taskId,
        progress: 1.0,
        stageDescription: '处理失败: $e',
        status: TaskStatus.error,
      ));
    } finally {
      _isProcessing = false;
      _processNext();
    }
  }

  /// 执行单个任务
  Future<void> _executeTask(MeetingTask task) async {
    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.1,
      stageDescription: '正在分析物理声道特征...',
      status: TaskStatus.processing,
    ));

    final file = File(task.audioPath);
    if (!file.existsSync()) {
      throw Exception('音频文件不存在: ${task.audioPath}');
    }

    final bytes = await file.readAsBytes();
    // 假设 PCM 或尝试解析声道样本
    final pcmSamples = _tryExtractInt16Pcm(bytes);

    // 1. 声道相关性分析
    final channelAnalysis = DualChannelDetector.analyzeInterleavedPcm(pcmSamples);
    debugPrint('[TaskQueueService] 声道检测: ${channelAnalysis.description}');

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.3,
      stageDescription: channelAnalysis.isStereoSeparated
          ? '检测到独立双声道，启动物理零算力解耦'
          : '启动离线智能声纹聚类识别',
      status: TaskStatus.processing,
    ));

    // 2. 调用推理 Worker 生成分段转写
    final segments = await _transcribeAudioSegments(task, channelAnalysis.isStereoSeparated);

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.8,
      stageDescription: '正在建立 FTS5 全文索引...',
      status: TaskStatus.processing,
    ));

    // 3. 落库与更新状态
    for (final seg in segments) {
      await AppDatabase.instance.insertSegment(seg);
    }

    final totalDurationMs = segments.isNotEmpty ? segments.last.endMs : 10000;
    final updatedTask = task.copyWith(
      status: TaskStatus.completed,
      durationMs: totalDurationMs,
    );
    await AppDatabase.instance.saveTask(updatedTask);

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 1.0,
      stageDescription: '转写完成',
      status: TaskStatus.completed,
    ));
  }

  /// 提取字节为 Int16List (支持安全跨度)
  Int16List _tryExtractInt16Pcm(Uint8List bytes) {
    if (bytes.length < 2) return Int16List(0);
    final count = bytes.length ~/ 2;
    final int16 = Int16List(count);
    final byteData = ByteData.sublistView(bytes);
    for (int i = 0; i < count; i++) {
      int16[i] = byteData.getInt16(i * 2, Endian.little);
    }
    return int16;
  }

  /// 简易线性重采样为 16kHz
  Float32List _resampleTo16k(Float32List input, int srcRate) {
    if (srcRate == 16000 || input.isEmpty) return input;
    final double ratio = srcRate / 16000.0;
    final int targetLength = (input.length / ratio).floor();
    final output = Float32List(targetLength);
    for (int i = 0; i < targetLength; i++) {
      final double srcIndex = i * ratio;
      final int index0 = srcIndex.floor();
      final int index1 = min(index0 + 1, input.length - 1);
      final double fraction = srcIndex - index0;
      output[i] = input[index0] * (1.0 - fraction) + input[index1] * fraction;
    }
    return output;
  }

  /// 分段转写生成器 (真实调用本地 ONNX 引擎与声纹聚类，杜绝任何硬编码测试数据)
  Future<List<TranscriptSegment>> _transcribeAudioSegments(
    MeetingTask task,
    bool isStereoSeparated,
  ) async {
    // 若设置了注入转写器 (如单元测试环境)，优先委托处理
    if (mockTranscriber != null) {
      return await mockTranscriber!(task, isStereoSeparated);
    }

    final modelConfig = await ModelManager.instance.resolveModels();
    if (!modelConfig.isSenseVoiceReady) {
      throw Exception('SenseVoice 语音识别模型未就绪，请前往系统设置下载模型后重试');
    }

    final worker = InferenceWorkerCoordinator.instance;
    await worker.initialize(modelConfig);

    final file = File(task.audioPath);
    if (!file.existsSync()) {
      throw Exception('音频源文件不存在或无法访问: ${task.audioPath}');
    }

    Float32List float32Samples = Float32List(0);
    int sampleRate = 16000;

    // 1. 优先使用 sherpa-onnx 原生 C++ 音频解码器解析 WAV
    try {
      final wave = sherpa.readWave(task.audioPath);
      if (wave.samples.isNotEmpty) {
        float32Samples = wave.samples;
        sampleRate = wave.sampleRate;
      }
    } catch (e) {
      debugPrint('[TaskQueueService] 原生 readWave 尝试异常，回退纯二进制分析: $e');
    }

    // 2. 若原生解码未提取到数据，尝试直接二进制 Int16 PCM 提取
    if (float32Samples.isEmpty) {
      final bytes = await file.readAsBytes();
      final pcmSamples = _tryExtractInt16Pcm(bytes);
      if (pcmSamples.isNotEmpty) {
        float32Samples = Float32List(pcmSamples.length);
        for (int i = 0; i < pcmSamples.length; i++) {
          float32Samples[i] = pcmSamples[i] / 32768.0;
        }
      }
    }

    if (float32Samples.isEmpty) {
      throw Exception('无法解析音频样本数据，请确认文件完整或尝试转换为标准 WAV 格式');
    }

    // 3. 对齐采样率为 16kHz
    if (sampleRate > 0 && sampleRate != 16000) {
      float32Samples = _resampleTo16k(float32Samples, sampleRate);
    }

    const targetSampleRate = 16000;
    const chunkSize = targetSampleRate * 3; // 3 秒切片
    final segments = <TranscriptSegment>[];

    int chunkIndex = 0;
    for (int offset = 0; offset < float32Samples.length; offset += chunkSize) {
      final end = (offset + chunkSize < float32Samples.length)
          ? offset + chunkSize
          : float32Samples.length;
      if (end - offset < targetSampleRate * 0.5) break;

      final slice = float32Samples.sublist(offset, end);
      final startMs = (offset / targetSampleRate * 1000).toInt();
      final endMs = (end / targetSampleRate * 1000).toInt();

      final res = await worker.transcribeChunk(TranscribeChunkCommand(
        messageId: 'chunk_${task.id}_$chunkIndex',
        taskId: task.id,
        chunkIndex: chunkIndex,
        startMs: startMs,
        endMs: endMs,
        samples: slice,
      ));

      if (res != null && res.isSuccess && res.text.trim().isNotEmpty) {
        final text = res.text.trim();
        if (text.length >= 2 || RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]').hasMatch(text)) {
          segments.add(TranscriptSegment(
            taskId: task.id,
            speakerId: res.speakerId,
            speakerName: res.speakerName,
            startMs: startMs,
            endMs: endMs,
            text: text,
          ));
        }
      }
      chunkIndex++;
    }

    if (segments.isEmpty) {
      throw Exception('音频已完整扫描，但未检测到有效的人声发言文本');
    }

    return segments;
  }
}
