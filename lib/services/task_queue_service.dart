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
import '../engine/audio/native_audio_bridge.dart';
import '../engine/audio/wav_codec.dart';
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

/// 智能语音切片区间
class _SpeechSliceRange {
  final int startSample;
  final int endSample;
  const _SpeechSliceRange(this.startSample, this.endSample);
}

/// 顶级后台 WAV 解码函数 (运行在 compute 独立 Isolate 中，杜绝阻塞主线程)
DecodedAudioResult? _decodeWavBytesInBackground(Uint8List bytes) {
  return WavCodec.decodeWavBytes(
    bytes,
    targetSampleRate: 16000,
    normalizeVolume: true,
  );
}

/// 录音批处理调度中心 (串行防 OOM 队列 + 全格式原生音频解码 + 智能静音停顿切分)
class TaskQueueService {
  static TaskQueueService? _instance;
  static TaskQueueService get instance => _instance ??= TaskQueueService._();

  TaskQueueService._();

  final List<String> _queue = [];
  bool _isProcessing = false;
  bool _hasTriggeredAutoRecovery = false;

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
    if (!_queue.contains(taskId)) {
      _queue.add(taskId);
    }
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

  /// 重新转写指定任务 (用于失败任务重试或重新识别)
  Future<void> retryTask(String taskId) async {
    final task = await AppDatabase.instance.getTask(taskId);
    if (task == null) return;

    // 清理旧的段落记录并重置状态为排队中
    await AppDatabase.instance.clearSegmentsForTask(taskId);
    final updated = task.copyWith(status: TaskStatus.queued);
    await AppDatabase.instance.saveTask(updated);

    if (!_queue.contains(taskId)) {
      _queue.add(taskId);
    }
    _progressController.add(TaskProgressEvent(
      taskId: taskId,
      progress: 0.05,
      stageDescription: '已重新加入队列，准备转写...',
      status: TaskStatus.queued,
    ));

    _processNext();
  }

  /// 应用启动时自动恢复上次未完成或因解码异常中断的导入任务
  Future<void> recoverPendingOrFailedImportedTasks() async {
    if (_hasTriggeredAutoRecovery) return;
    _hasTriggeredAutoRecovery = true;

    try {
      final modelConfig = await ModelManager.instance.resolveModels();
      if (!modelConfig.isSenseVoiceReady) return;

      final allTasks = await AppDatabase.instance.getAllTasks();
      for (final task in allTasks) {
        if (task.sourceType != TaskSourceType.importedAudio) continue;
        final audioExists = task.audioPath.isNotEmpty && File(task.audioPath).existsSync();
        if (!audioExists) continue;

        // 仅自动恢复由于意外终止而中断的排队中/处理中任务，绝不自动强行重试已经标记为 error 的任务
        if (task.status == TaskStatus.queued ||
            task.status == TaskStatus.processing) {
          final existingSegs = await AppDatabase.instance.getSegmentsForTask(task.id);
          if (existingSegs.isEmpty && !_queue.contains(task.id)) {
            debugPrint('[TaskQueueService] 自动恢复待转写导入任务: ${task.title} (${task.id})');
            await retryTask(task.id);
          }
        }
      }
    } catch (e) {
      debugPrint('[TaskQueueService] 自动恢复任务检查异常: $e');
    }
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
        stageDescription: '处理失败: ${e.toString().replaceAll('Exception:', '').trim()}',
        status: TaskStatus.error,
      ));
    } finally {
      _isProcessing = false;
      _processNext();
    }
  }

  /// 执行单个任务
  Future<void> _executeTask(MeetingTask task) async {
    await AppDatabase.instance.saveTask(task.copyWith(status: TaskStatus.processing));

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.1,
      stageDescription: '正在解码音频并分析物理声道...',
      status: TaskStatus.processing,
    ));

    final file = File(task.audioPath);
    if (!file.existsSync()) {
      throw Exception('音频文件不存在: ${task.audioPath}');
    }

    // 若注入了单元测试模拟转写器，优先执行模拟分支
    if (mockTranscriber != null) {
      final bytes = await file.readAsBytes();
      final pcmSamples = _tryExtractInt16Pcm(bytes);
      final channelAnalysis = DualChannelDetector.analyzeInterleavedPcm(pcmSamples);
      final segments = await mockTranscriber!(task, channelAnalysis.isStereoSeparated);

      for (final seg in segments) {
        await AppDatabase.instance.insertSegment(seg);
      }
      final totalDurationMs = segments.isNotEmpty ? segments.last.endMs : 10000;
      await AppDatabase.instance.saveTask(task.copyWith(
        status: TaskStatus.completed,
        durationMs: totalDurationMs,
      ));
      _progressController.add(TaskProgressEvent(
        taskId: task.id,
        progress: 1.0,
        stageDescription: '转写完成',
        status: TaskStatus.completed,
      ));
      return;
    }

    // 真实环境：全格式解码音频为 16kHz 单声道 Float32 样本
    final decoded = await _decodeAudioFileTo16k(task.audioPath);
    debugPrint(
      '[TaskQueueService] 音频解码完成: 时长=${decoded.durationMs}ms, 采样点=${decoded.monoSamples.length}, 声道=${decoded.channelAnalysis.description}',
    );

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.25,
      stageDescription: decoded.channelAnalysis.isStereoSeparated
          ? '检测到独立双声道，启动物理零算力解耦'
          : '启动 SenseVoice 离线智能语音与声纹识别...',
      status: TaskStatus.processing,
    ));

    // 2. 调用推理 Worker 生成分段转写
    final segments = await _transcribeDecodedAudio(
      task,
      decoded,
    );

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.92,
      stageDescription: '正在写入段落并建立 FTS5 全文索引...',
      status: TaskStatus.processing,
    ));

    // 3. 落库与更新状态 (使用高效事务批量写入，彻底杜绝高频刷新卡死)
    await AppDatabase.instance.clearSegmentsForTask(task.id);
    await AppDatabase.instance.insertSegmentsBatch(segments);

    final totalDurationMs = decoded.durationMs > 0
        ? decoded.durationMs
        : (segments.isNotEmpty ? segments.last.endMs : 1000);
    final updatedTask = task.copyWith(
      status: TaskStatus.completed,
      durationMs: totalDurationMs,
    );
    await AppDatabase.instance.saveTask(updatedTask);

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 1.0,
      stageDescription: '转写完成 (共 ${segments.length} 段)',
      status: TaskStatus.completed,
    ));
  }

  /// 全格式音频解码器：支持 WAV (全位深/浮点/多声道) 及 M4A/MP3/AAC/FLAC/OGG/OPUS/AMR 等全部外部音频
  Future<DecodedAudioResult> _decodeAudioFileTo16k(String inputPath) async {
    final file = File(inputPath);
    if (!file.existsSync() || file.lengthSync() < 44) {
      throw Exception('音频文件无效或内容为空');
    }

    // 1. 若文件为标准 RIFF WAVE 格式，使用后台 Isolate 解码或原生 readWave
    try {
      final headerBytes = await file.openRead(0, 16).fold<List<int>>([], (a, b) => a..addAll(b));
      if (headerBytes.length >= 12) {
        final riff = String.fromCharCodes(headerBytes.sublist(0, 4));
        final wave = String.fromCharCodes(headerBytes.sublist(8, 12));
        if ((riff == 'RIFF' || riff == 'RIFX') && wave == 'WAVE') {
          // 优先尝试 sherpa 原生快速读取 (C 语言极速处理)
          try {
            final waveObj = sherpa.readWave(inputPath);
            if (waveObj.samples.isNotEmpty) {
              Float32List samples = waveObj.samples;
              if (waveObj.sampleRate > 0 && waveObj.sampleRate != 16000) {
                samples = WavCodec.resampleLinear(samples, waveObj.sampleRate, 16000);
              }
              WavCodec.applyAdaptiveNormalization(samples);
              final durationMs = (samples.length * 1000) ~/ 16000;
              return DecodedAudioResult(
                monoSamples: samples,
                sampleRate: 16000,
                originalChannels: 1,
                durationMs: durationMs,
                channelAnalysis: const DualChannelAnalysis(
                  isStereoSeparated: false,
                  correlation: 1.0,
                  description: '原生极速读取 WAV',
                ),
                standardWavPath: waveObj.sampleRate == 16000 ? inputPath : '',
              );
            }
          } catch (_) {}

          // 备用：在独立后台 Isolate 解析
          final fullBytes = await file.readAsBytes();
          final wavDecoded = await compute(_decodeWavBytesInBackground, fullBytes);
          if (wavDecoded != null && wavDecoded.monoSamples.isNotEmpty) {
            return wavDecoded;
          }
        }
      }
    } catch (e) {
      debugPrint('[TaskQueueService] WAV 直接解析跳过: $e');
    }

    // 2. 调用系统原生硬件解码器 (Windows Media Foundation / Android MediaCodec) + FFmpeg 兜底转码为标准 16kHz WAV
    final decodedWavPath = await _transcodeToStandardWav(inputPath);
    if (decodedWavPath != null && File(decodedWavPath).existsSync()) {
      // 优先：使用原生 C 库极速读取转码后的标准 16kHz WAV (零 Dart 线程阻塞)
      try {
        final wave = sherpa.readWave(decodedWavPath);
        if (wave.samples.isNotEmpty) {
          Float32List samples = wave.samples;
          if (wave.sampleRate > 0 && wave.sampleRate != 16000) {
            samples = WavCodec.resampleLinear(samples, wave.sampleRate, 16000);
          }
          WavCodec.applyAdaptiveNormalization(samples);
          final durationMs = (samples.length * 1000) ~/ 16000;
          return DecodedAudioResult(
            monoSamples: samples,
            sampleRate: 16000,
            originalChannels: 1,
            durationMs: durationMs,
            channelAnalysis: const DualChannelAnalysis(
              isStereoSeparated: false,
              correlation: 1.0,
              description: '原生硬件解码单声道音频',
            ),
            standardWavPath: decodedWavPath,
          );
        }
      } catch (e) {
        debugPrint('[TaskQueueService] sherpa.readWave 读取转码音频失败，尝试后台降级: $e');
      }

      // 备用：在后台 Isolate 进行纯 Dart 解析
      try {
        final wavBytes = await File(decodedWavPath).readAsBytes();
        final wavResult = await compute(_decodeWavBytesInBackground, wavBytes);
        if (wavResult != null && wavResult.monoSamples.isNotEmpty) {
          return wavResult;
        }
      } catch (e) {
        debugPrint('[TaskQueueService] 读取转码后 WAV 异常: $e');
      }
    }

    // 3. 若源文件本身就是裸 .pcm 文件，按 16-bit Little Endian PCM 解析
    final ext = p.extension(inputPath).toLowerCase();
    if (ext == '.pcm') {
      final bytes = await file.readAsBytes();
      final pcmSamples = _tryExtractInt16Pcm(bytes);
      if (pcmSamples.length >= 4000) {
        final floatSamples = Float32List(pcmSamples.length);
        for (int i = 0; i < pcmSamples.length; i++) {
          floatSamples[i] = pcmSamples[i] / 32768.0;
        }
        WavCodec.applyAdaptiveNormalization(floatSamples);
        return DecodedAudioResult(
          monoSamples: floatSamples,
          sampleRate: 16000,
          originalChannels: 1,
          durationMs: (floatSamples.length * 1000) ~/ 16000,
          channelAnalysis: const DualChannelAnalysis(
            isStereoSeparated: false,
            correlation: 1.0,
            description: 'PCM 原始音频流',
          ),
        );
      }
    }

    throw Exception('无法解码该音频文件 (格式: ${ext.isEmpty ? "未知" : ext})，文件可能已损坏或不包含有效音轨');
  }

  /// 将任意压缩音频 (m4a, mp3, aac, flac, ogg, opus, amr, wma...) 转换为 16kHz 单声道 WAV
  Future<String?> _transcodeToStandardWav(String inputPath) async {
    try {
      final appSupport = await getApplicationSupportDirectory();
      final tempDir = Directory(p.join(appSupport.path, 'decoded_wavs'));
      if (!tempDir.existsSync()) {
        tempDir.createSync(recursive: true);
      }
      final outWavPath = p.join(
        tempDir.path,
        '${p.basenameWithoutExtension(inputPath)}_${DateTime.now().millisecondsSinceEpoch}.wav',
      );

      // 优先级 1：调用应用内置的原生解码通道 (Windows Media Foundation C++ / Android MediaCodec)
      final nativeOk = await NativeAudioBridge.decodeAudioToWav(
        inputPath: inputPath,
        outputPath: outWavPath,
        targetSampleRate: 16000,
      );
      if (nativeOk && File(outWavPath).existsSync() && File(outWavPath).lengthSync() > 44) {
        debugPrint('[TaskQueueService] 原生硬件引擎音频解码成功: $outWavPath');
        return outWavPath;
      }

      // 优先级 2：若系统安装了 ffmpeg CLI 则尝试使用 ffmpeg
      try {
        final result = await Process.run('ffmpeg', [
          '-y',
          '-i',
          inputPath,
          '-ar',
          '16000',
          '-ac',
          '1',
          '-c:a',
          'pcm_s16le',
          outWavPath,
        ]);
        if (result.exitCode == 0 && File(outWavPath).existsSync() && File(outWavPath).lengthSync() > 44) {
          debugPrint('[TaskQueueService] FFmpeg 音频转码成功: $outWavPath');
          return outWavPath;
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('[TaskQueueService] 转码为标准 WAV 失败: $e');
    }
    return null;
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

  /// 基于能量静音谷底的智能长句切片算法
  /// 在 5~14 秒的自然语句窗口内自动寻找说话停顿点切分，绝不将词语从中间硬切断
  List<_SpeechSliceRange> _splitSamplesByEnergyPause(Float32List samples, int sampleRate) {
    final ranges = <_SpeechSliceRange>[];
    if (samples.isEmpty) return ranges;

    final minChunkSamples = sampleRate * 4; // 最短 4 秒尝试寻找停顿
    final idealMaxSamples = sampleRate * 10; // 理想最大 10 秒
    final hardMaxSamples = sampleRate * 15; // 强制切分上限 15 秒
    final windowSize = (sampleRate * 0.12).floor(); // 120ms 能量分析窗

    int offset = 0;
    while (offset < samples.length) {
      final remaining = samples.length - offset;
      if (remaining <= idealMaxSamples) {
        if (remaining >= (sampleRate * 0.25).floor()) {
          ranges.add(_SpeechSliceRange(offset, samples.length));
        }
        break;
      }

      // 在 [offset + minChunkSamples, min(samples.length, offset + hardMaxSamples)] 区间内寻找静音停顿谷底
      final searchStart = offset + minChunkSamples;
      final searchEnd = min(samples.length - windowSize, offset + hardMaxSamples);

      int bestCutPoint = min(samples.length, offset + idealMaxSamples);
      double minWindowRms = double.infinity;

      for (int pos = searchStart; pos <= searchEnd; pos += windowSize ~/ 2) {
        double sumSq = 0.0;
        for (int k = 0; k < windowSize && (pos + k) < samples.length; k++) {
          final v = samples[pos + k];
          sumSq += v * v;
        }
        final rms = sqrt(sumSq / windowSize);

        // 若遇到明显的静音停顿 (< 0.012) 且已达到 5 秒以上，直接在此停顿中心切分
        if (rms < 0.012 && (pos - offset) >= sampleRate * 5) {
          bestCutPoint = pos + (windowSize ~/ 2);
          break;
        }

        if (rms < minWindowRms) {
          minWindowRms = rms;
          bestCutPoint = pos + (windowSize ~/ 2);
        }
      }

      ranges.add(_SpeechSliceRange(offset, bestCutPoint));
      offset = bestCutPoint;
    }

    return ranges;
  }

  /// 确保生成符合标准 16kHz 16-bit 单声道的临时物理 WAV 文件 (供原生推理 Worker 直接读取)
  Future<String> _ensureStandard16kWavFile(String originalPath, DecodedAudioResult decoded) async {
    if (decoded.standardWavPath.isNotEmpty && File(decoded.standardWavPath).existsSync()) {
      return decoded.standardWavPath;
    }

    final appSupport = await getApplicationSupportDirectory();
    final tempDir = Directory(p.join(appSupport.path, 'decoded_wavs'));
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
    final outPath = p.join(
      tempDir.path,
      'std_${p.basenameWithoutExtension(originalPath)}_${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    final samples = decoded.monoSamples;
    final byteCount = samples.length * 2;
    final builder = BytesBuilder(copy: false);

    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + byteCount, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6d); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // 1 channel
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, byteCount, Endian.little);
    builder.add(header.buffer.asUint8List());

    final pcmBytes = Int16List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      pcmBytes[i] = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    }
    builder.add(pcmBytes.buffer.asUint8List());

    await File(outPath).writeAsBytes(builder.toBytes(), flush: true);
    return outPath;
  }

  /// 对已解码的 16kHz 音频执行 Silero-VAD 神经网络自然切句与纯净多角色转写
  Future<List<TranscriptSegment>> _transcribeDecodedAudio(
    MeetingTask task,
    DecodedAudioResult decoded,
  ) async {
    final modelConfig = await ModelManager.instance.resolveModels();
    if (!modelConfig.isSenseVoiceReady) {
      throw Exception('SenseVoice 语音识别模型未就绪，请前往模型管理中心下载模型后重试');
    }

    final worker = InferenceWorkerCoordinator.instance;
    final isInitialized = await worker.initialize(modelConfig);
    if (!isInitialized) {
      throw Exception('离线语音识别引擎初始化失败，请确认模型资产文件是否完整无损坏');
    }

    final wavPath = await _ensureStandard16kWavFile(task.audioPath, decoded);

    // 实时监听子 Isolate 派发的自然句平滑转写进度
    final progressSub = worker.onProgressNotification.listen((notif) {
      if (notif.taskId == task.id) {
        _progressController.add(TaskProgressEvent(
          taskId: task.id,
          progress: notif.progress,
          stageDescription: notif.stageDescription,
          status: TaskStatus.processing,
        ));
      }
    });

    try {
      final fileResponse = await worker.transcribeFile(TranscribeFileCommand(
        messageId: 'file_${task.id}_${DateTime.now().millisecondsSinceEpoch}',
        taskId: task.id,
        audioFilePath: wavPath,
        enableDiarization: true,
      ));

      if (fileResponse == null || !fileResponse.isSuccess) {
        throw Exception(fileResponse?.errorMessage ?? '离线语音转写未返回有效结果');
      }

      final segments = fileResponse.segments
          .map((p) => TranscriptSegment(
                taskId: p.taskId,
                speakerId: p.speakerId,
                speakerName: p.speakerName,
                startMs: p.startMs,
                endMs: p.endMs,
                text: p.text,
              ))
          .toList();

      return segments;
    } finally {
      await progressSub.cancel();
    }
  }
}
