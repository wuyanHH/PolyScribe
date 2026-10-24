import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show Int16List;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/database/app_database.dart';
import '../data/models/meeting_task.dart';
import '../data/models/transcript_segment.dart';
import '../engine/audio/native_audio_bridge.dart';
import '../engine/audio/wav_codec.dart';
import '../engine/diarization/dual_channel_detector.dart';
import '../engine/isolate/inference_worker.dart';
import '../engine/isolate/worker_message.dart';
import '../engine/model_manager.dart';
import '../engine/text/transcript_context_optimizer.dart';

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

/// 格式化毫秒为 mm:ss
String _formatMs(int ms) {
  final totalSec = ms ~/ 1000;
  final m = (totalSec ~/ 60).toString().padLeft(2, '0');
  final s = (totalSec % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 顶级后台 WAV 解码函数 (运行在 compute 独立 Isolate 中，杜绝阻塞主线程)
DecodedAudioResult? _decodeWavBytesInBackground(Uint8List bytes) {
  return WavCodec.decodeWavBytes(
    bytes,
    targetSampleRate: 16000,
    normalizeVolume: true,
  );
}

/// 录音批处理调度中心 (串行防 OOM 队列 + 全格式原生音频解码 + 智能静音停顿切分 + 毫秒级断点续转)
class TaskQueueService {
  static TaskQueueService? _instance;
  static TaskQueueService get instance => _instance ??= TaskQueueService._();

  TaskQueueService._();

  final List<String> _queue = [];
  final Map<String, int> _resumeOffsetMap = {};
  final Set<String> _pausedOrCancelledTaskIds = {};
  String? _currentProcessingTaskId;
  bool _isProcessing = false;
  bool _hasTriggeredAutoRecovery = false;

  /// 获取当前正在转写的任务 ID (null 表示队列空闲)
  String? get currentProcessingTaskId => _currentProcessingTaskId;

  /// 检查某任务是否在等待队列中
  bool isTaskQueued(String taskId) => _queue.contains(taskId);

  final StreamController<TaskProgressEvent> _progressController =
      StreamController<TaskProgressEvent>.broadcast();

  Stream<TaskProgressEvent> get onProgress => _progressController.stream;

  /// 可选自定义转写处理器 (用于单元测试或自定义引擎注入)
  Future<List<TranscriptSegment>> Function(MeetingTask task, bool isStereoSeparated)? mockTranscriber;

  /// 添加音频任务到批处理队列
  Future<MeetingTask> enqueueAudioFile(String filePath, {String? customTitle}) async {
    final fileName = p.basenameWithoutExtension(filePath);
    final randSuffix = Random().nextInt(90000) + 10000;
    final taskId = 'task_${DateTime.now().microsecondsSinceEpoch}_$randSuffix';

    // 1. 将原音频立即安全拷贝到应用的私有存储目录，杜绝原文件移动或删除导致丢失与同名覆盖
    String safeAudioPath = filePath;
    try {
      final sourceFile = File(filePath);
      if (sourceFile.existsSync()) {
        final appSupport = await getApplicationSupportDirectory();
        final audioDir = Directory(p.join(appSupport.path, 'imported_audios'));
        if (!audioDir.existsSync()) {
          audioDir.createSync(recursive: true);
        }
        final ext = p.extension(filePath);
        final safeName = p.basenameWithoutExtension(filePath).replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\-_]'), '_');
        final destPath = p.join(audioDir.path, '${taskId}_$safeName$ext');
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

  /// 重新转写指定任务 (清空旧段落，从第 0 秒从头识别)
  Future<void> retryTask(String taskId) async {
    final task = await AppDatabase.instance.getTask(taskId);
    if (task == null) return;

    _resumeOffsetMap.remove(taskId);
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
      stageDescription: '已重新加入队列，准备从头全量转写...',
      status: TaskStatus.queued,
    ));

    _processNext();
  }

  /// 暂停指定任务的转写 (支持断点记录，下次可从断点秒级继续)
  Future<void> pauseTask(String taskId) async {
    _pausedOrCancelledTaskIds.add(taskId);
    _queue.remove(taskId);

    final task = await AppDatabase.instance.getTask(taskId);
    if (task == null) return;

    // 1. 计算当前已完成的最大断点 offset
    final existingSegs = await AppDatabase.instance.getSegmentsForTask(taskId);
    int startOffsetMs = 0;
    if (existingSegs.isNotEmpty) {
      for (final s in existingSegs) {
        if (s.endMs > startOffsetMs) {
          startOffsetMs = s.endMs;
        }
      }
    }
    _resumeOffsetMap[taskId] = startOffsetMs;

    // 2. 若是当前正在执行的任务，通知底层工作线程中断
    if (_currentProcessingTaskId == taskId) {
      debugPrint('[TaskQueueService] 正在执行的任务被主动暂停: $taskId, 已保存断点: ${_formatMs(startOffsetMs)}');
      InferenceWorkerCoordinator.instance.cancelTask(taskId);
      _currentProcessingTaskId = null;
      _isProcessing = false;
    }

    // 3. 更新数据库状态为 paused
    final updated = task.copyWith(status: TaskStatus.paused);
    await AppDatabase.instance.saveTask(updated);

    _progressController.add(TaskProgressEvent(
      taskId: taskId,
      progress: existingSegs.isNotEmpty ? 0.5 : 0.0,
      stageDescription: startOffsetMs > 0
          ? '已暂停转写 (已记录断点 ${_formatMs(startOffsetMs)}，随时可继续)'
          : '已暂停转写',
      status: TaskStatus.paused,
    ));

    // 4. 触发下一个排队任务流转
    _processNext();
  }

  /// 取消并彻底删除指定任务 (若正在执行中，秒级中断底层并自动继续执行下一个排队任务)
  Future<void> cancelOrDeleteTask(String taskId, {bool deleteAudioFile = false}) async {
    _pausedOrCancelledTaskIds.add(taskId);
    _resumeOffsetMap.remove(taskId);
    _queue.remove(taskId);

    // 1. 若当前任务正在转写运行中，立即通知底层中断工作线程
    if (_currentProcessingTaskId == taskId) {
      debugPrint('[TaskQueueService] 正在运行的任务被删除，通知底层中断并重置队列状态: $taskId');
      InferenceWorkerCoordinator.instance.cancelTask(taskId);
      _currentProcessingTaskId = null;
      _isProcessing = false;
    }

    // 2. 彻底从数据库删除该任务
    await AppDatabase.instance.deleteTask(taskId, deleteAudioFile: deleteAudioFile);

    // 3. 广播已取消事件
    _progressController.add(TaskProgressEvent(
      taskId: taskId,
      progress: 0.0,
      stageDescription: '任务已取消并删除',
      status: TaskStatus.error,
    ));

    // 4. 【核心修复】：立即触发队列调度，无缝启动下一个任务！
    _processNext();
  }

  /// 断点续转/继续指定任务 (从上次已保存段落的最后位置继续识别，杜绝重复计算)
  Future<void> resumeTask(String taskId) async {
    _pausedOrCancelledTaskIds.remove(taskId);
    final task = await AppDatabase.instance.getTask(taskId);
    if (task == null) return;

    final existingSegs = await AppDatabase.instance.getSegmentsForTask(taskId);
    int startOffsetMs = 0;
    if (existingSegs.isNotEmpty) {
      for (final s in existingSegs) {
        if (s.endMs > startOffsetMs) {
          startOffsetMs = s.endMs;
        }
      }
    }

    _resumeOffsetMap[taskId] = startOffsetMs;
    final updated = task.copyWith(status: TaskStatus.queued);
    await AppDatabase.instance.saveTask(updated);

    if (!_queue.contains(taskId)) {
      _queue.add(taskId);
    }
    _progressController.add(TaskProgressEvent(
      taskId: taskId,
      progress: 0.05,
      stageDescription: startOffsetMs > 0
          ? '已准备从断点恢复转写 (已完成 ${existingSegs.length} 段 · 从 ${_formatMs(startOffsetMs)} 继续)...'
          : '已重新加入队列，准备转写...',
      status: TaskStatus.queued,
    ));

    _processNext();
  }

  /// 应用启动时自动恢复上次未完成或因异常中断的导入任务 (遵循设置开关，默认开启)
  Future<void> recoverPendingOrFailedImportedTasks() async {
    if (_hasTriggeredAutoRecovery) return;
    _hasTriggeredAutoRecovery = true;

    try {
      // 读取用户设置：启动时是否自动继续转写 (默认开启 true)
      final autoResumeSetting = await AppDatabase.instance.getSetting('auto_resume_transcription');
      final isAutoResumeEnabled = autoResumeSetting == null || autoResumeSetting == 'true';
      if (!isAutoResumeEnabled) {
        debugPrint('[TaskQueueService] 用户已关闭启动自动继续转写，跳过自动恢复');
        return;
      }

      final modelConfig = await ModelManager.instance.resolveModels();
      if (!modelConfig.isSenseVoiceReady) return;

      final allTasks = await AppDatabase.instance.getAllTasks();
      for (final task in allTasks) {
        if (task.sourceType != TaskSourceType.importedAudio) continue;
        final audioExists = task.audioPath.isNotEmpty && File(task.audioPath).existsSync();
        if (!audioExists) continue;

        // 自动恢复排队中、处理中或暂停中的未完成任务，支持秒级断点续转
        if (task.status == TaskStatus.queued ||
            task.status == TaskStatus.processing ||
            task.status == TaskStatus.paused) {
          if (!_queue.contains(task.id)) {
            debugPrint('[TaskQueueService] 启动自动从断点恢复未完成导入任务: ${task.title} (${task.id})');
            await resumeTask(task.id);
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
    _currentProcessingTaskId = taskId;

    try {
      final task = await AppDatabase.instance.getTask(taskId);
      if (task == null || _pausedOrCancelledTaskIds.contains(taskId)) {
        _currentProcessingTaskId = null;
        _isProcessing = false;
        _processNext();
        return;
      }

      await _executeTask(task);
    } catch (e, stack) {
      debugPrint('[TaskQueueService] 任务执行异常: $e\n$stack');
      try {
        final currentTask = await AppDatabase.instance.getTask(taskId);
        if (currentTask != null && !_pausedOrCancelledTaskIds.contains(taskId)) {
          await AppDatabase.instance.saveTask(currentTask.copyWith(status: TaskStatus.error));
        }
      } catch (dbErr) {
        debugPrint('[TaskQueueService] 更新数据库任务错误状态异常: $dbErr');
      }

      if (!_pausedOrCancelledTaskIds.contains(taskId)) {
        _progressController.add(TaskProgressEvent(
          taskId: taskId,
          progress: 1.0,
          stageDescription: '处理失败: ${e.toString().replaceAll('Exception:', '').trim()}',
          status: TaskStatus.error,
        ));
      }
    } finally {
      _currentProcessingTaskId = null;
      _isProcessing = false;
      _processNext();
    }
  }

  /// 执行单个任务
  Future<void> _executeTask(MeetingTask task) async {
    await AppDatabase.instance.saveTask(task.copyWith(status: TaskStatus.processing));

    final resumeStartMs = _resumeOffsetMap.remove(task.id) ?? 0;
    final existingSegs = await AppDatabase.instance.getSegmentsForTask(task.id);
    final initialSegmentCount = resumeStartMs > 0 ? existingSegs.length : 0;

    // 若不是断点续转，清空旧段落记录重新开始
    if (resumeStartMs == 0) {
      await AppDatabase.instance.clearSegmentsForTask(task.id);
    }

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.05,
      stageDescription: resumeStartMs > 0
          ? '正在从断点准备恢复 (已保存 $initialSegmentCount 段 · 从 ${_formatMs(resumeStartMs)} 继续)...'
          : '正在分析音频音轨与声道结构...',
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

    // 真实环境：先校验离线模型是否就绪，避免无模型时白白耗费解码算力与内存
    final modelConfig = await ModelManager.instance.resolveModels();
    if (!modelConfig.isSenseVoiceReady) {
      throw Exception('SenseVoice 语音识别模型未就绪，请前往模型管理中心下载模型后重试');
    }

    // 全格式流式解码音频为 16kHz 单声道标准 WAV (带动态耗时与平滑进度反馈，告别 10% 假死状态)
    int decodeTicks = 0;
    final decodeTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      decodeTicks++;
      final p = (0.05 + (decodeTicks * 0.012)).clamp(0.05, 0.22);
      final elapsedSec = (decodeTicks * 0.7).toStringAsFixed(1);
      _progressController.add(TaskProgressEvent(
        taskId: task.id,
        progress: p,
        stageDescription: '正在流式解码与重采样音频 (已耗时 ${elapsedSec}s)...',
        status: TaskStatus.processing,
      ));
    });

    DecodedAudioResult decoded;
    try {
      decoded = await _decodeAudioFileTo16k(task.audioPath);
    } finally {
      decodeTimer.cancel();
    }

    debugPrint(
      '[TaskQueueService] 音频解码完成: 时长=${decoded.durationMs}ms, 标准WAV=${decoded.standardWavPath}, 声道=${decoded.channelAnalysis.description}',
    );

    // 将标准化 16kHz WAV 保留为高精度对齐音频源 (彻底解决压缩音频 Seek 漂移和音频文字错位)
    MeetingTask currentTask = task;
    if (decoded.standardWavPath.isNotEmpty && File(decoded.standardWavPath).existsSync()) {
      try {
        final appSupport = await getApplicationSupportDirectory();
        final audioDir = Directory(p.join(appSupport.path, 'imported_audios'));
        final permanentAlignedWav = p.join(audioDir.path, '${task.id}_aligned_16k.wav');
        if (decoded.standardWavPath != permanentAlignedWav) {
          final sourceStd = File(decoded.standardWavPath);
          if (sourceStd.existsSync()) {
            await sourceStd.copy(permanentAlignedWav);
            currentTask = currentTask.copyWith(audioPath: permanentAlignedWav);
            await AppDatabase.instance.saveTask(currentTask);
          }
        }
      } catch (e) {
        debugPrint('[TaskQueueService] 固化高精度对齐音频跳过: $e');
      }
    }

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.23,
      stageDescription: decoded.channelAnalysis.isStereoSeparated
          ? '检测到独立双声道，启动物理零算力解耦'
          : '启动 SenseVoice 离线智能语音识别引擎...',
      status: TaskStatus.processing,
    ));

    // 2. 调用推理 Worker 生成分段转写 (支持分句增量实时落库与断点续转)
    await _transcribeDecodedAudio(
      currentTask,
      decoded,
      modelConfig: modelConfig,
      startOffsetMs: resumeStartMs,
      initialSegmentIndex: initialSegmentCount,
    );

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 0.95,
      stageDescription: '正在刷新段落与全文索引...',
      status: TaskStatus.processing,
    ));

    // 若在转写过程中已被用户暂停或取消删除，不覆盖为完成
    if (_pausedOrCancelledTaskIds.contains(task.id)) {
      debugPrint('[TaskQueueService] 任务已在过程中被暂停或取消，跳过完成落库: ${task.id}');
      return;
    }

    // 3. 查询当前所有已保存的段落并最终对齐任务时长
    final allSegments = await AppDatabase.instance.getSegmentsForTask(task.id);
    final totalDurationMs = decoded.durationMs > 0
        ? decoded.durationMs
        : (allSegments.isNotEmpty ? allSegments.last.endMs : 1000);
    final updatedTask = currentTask.copyWith(
      status: TaskStatus.completed,
      durationMs: totalDurationMs,
    );
    await AppDatabase.instance.saveTask(updatedTask);

    _progressController.add(TaskProgressEvent(
      taskId: task.id,
      progress: 1.0,
      stageDescription: '转写完成 (共 ${allSegments.length} 段)',
      status: TaskStatus.completed,
    ));
  }

  /// 检查文件是否本身就是标准的 16kHz 单声道 16-bit PCM WAV，若是则直接返回时长 (毫秒)
  Future<int?> _inspectStandard16kMonoWavDurationMs(File file) async {
    try {
      final len = file.lengthSync();
      if (len < 44) return null;
      final raf = await file.open(mode: FileMode.read);
      try {
        final header = await raf.read(minHeaderSize(len));
        if (header.length < 44) return null;
        final bd = ByteData.sublistView(header);
        final riff = String.fromCharCodes(header.sublist(0, 4));
        final wave = String.fromCharCodes(header.sublist(8, 12));
        if (riff != 'RIFF' || wave != 'WAVE') return null;

        int offset = 12;
        int audioFormat = 0;
        int numChannels = 0;
        int sampleRate = 0;
        int bitsPerSample = 0;
        int dataBytes = 0;

        while (offset + 8 <= header.length) {
          final chunkId = String.fromCharCodes(header.sublist(offset, offset + 4));
          final chunkSize = bd.getUint32(offset + 4, Endian.little);
          offset += 8;
          if (chunkId == 'fmt ' && offset + 16 <= header.length) {
            audioFormat = bd.getUint16(offset, Endian.little);
            numChannels = bd.getUint16(offset + 2, Endian.little);
            sampleRate = bd.getUint32(offset + 4, Endian.little);
            bitsPerSample = bd.getUint16(offset + 14, Endian.little);
          } else if (chunkId == 'data') {
            dataBytes = chunkSize > 0 && (offset + chunkSize <= len)
                ? chunkSize
                : (len - offset);
            break;
          }
          offset += chunkSize + (chunkSize.isOdd ? 1 : 0);
        }

        if (audioFormat == 1 &&
            numChannels == 1 &&
            sampleRate == 16000 &&
            bitsPerSample == 16 &&
            dataBytes > 0) {
          final totalSamples = dataBytes ~/ 2;
          return (totalSamples * 1000) ~/ 16000;
        }
      } finally {
        await raf.close();
      }
    } catch (_) {}
    return null;
  }

  int minHeaderSize(int fileLen) => fileLen < 512 ? fileLen : 512;

  /// 全格式音频解码器：支持 WAV (全位深/浮点/多声道) 及 M4A/MP3/AAC/FLAC/OGG/OPUS/AMR 等全部外部音频
  /// 采用磁盘流式直写架构，主 Isolate 不驻留整段音频的 Float32List，彻底根治手机端长音频 OOM 闪退
  Future<DecodedAudioResult> _decodeAudioFileTo16k(String inputPath) async {
    final file = File(inputPath);
    if (!file.existsSync() || file.lengthSync() < 44) {
      throw Exception('音频文件无效或内容为空');
    }

    // 1. 快速通道：若原文件已经是 16kHz 16-bit 单声道标准 WAV，零拷贝直接复用原文件路径
    final directDurationMs = await _inspectStandard16kMonoWavDurationMs(file);
    if (directDurationMs != null && directDurationMs > 0) {
      return DecodedAudioResult(
        monoSamples: Float32List(0),
        sampleRate: 16000,
        originalChannels: 1,
        durationMs: directDurationMs,
        channelAnalysis: const DualChannelAnalysis(
          isStereoSeparated: false,
          correlation: 1.0,
          description: '原生 16kHz 标准 WAV 直通流式读取',
        ),
        standardWavPath: inputPath,
      );
    }

    // 2. 主力通道：调用系统原生流式硬件解码器 (Android MediaCodec 恒定 64KB 缓冲 / Windows Media Foundation) + FFmpeg 兜底转码为标准 16kHz WAV
    final decodedWavPath = await _transcodeToStandardWav(inputPath);
    if (decodedWavPath != null && File(decodedWavPath).existsSync()) {
      final decodedFile = File(decodedWavPath);
      final durationMs = await _inspectStandard16kMonoWavDurationMs(decodedFile) ??
          (((decodedFile.lengthSync() - 44).clamp(0, 1 << 30) ~/ 2) * 1000) ~/ 16000;
      if (durationMs > 0) {
        return DecodedAudioResult(
          monoSamples: Float32List(0),
          sampleRate: 16000,
          originalChannels: 1,
          durationMs: durationMs,
          channelAnalysis: const DualChannelAnalysis(
            isStereoSeparated: false,
            correlation: 1.0,
            description: '原生硬件流式解码 16kHz WAV',
          ),
          standardWavPath: decodedWavPath,
        );
      }
    }

    // 3. 备用通道：若文件为特殊格式 RIFF WAVE 且未通过原生通道转码（且体积在安全范围内），在后台 Isolate 解析
    try {
      final fileSize = file.lengthSync();
      if (fileSize <= 64 * 1024 * 1024) {
        final headerBytes = await file.openRead(0, 16).fold<List<int>>([], (a, b) => a..addAll(b));
        if (headerBytes.length >= 12) {
          final riff = String.fromCharCodes(headerBytes.sublist(0, 4));
          final wave = String.fromCharCodes(headerBytes.sublist(8, 12));
          if ((riff == 'RIFF' || riff == 'RIFX') && wave == 'WAVE') {
            final fullBytes = await file.readAsBytes();
            final wavDecoded = await compute(_decodeWavBytesInBackground, fullBytes);
            if (wavDecoded != null && wavDecoded.monoSamples.isNotEmpty) {
              return wavDecoded;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[TaskQueueService] WAV 备用后台解析跳过: $e');
    }

    // 4. 若源文件本身就是裸 .pcm 文件，按 16-bit Little Endian PCM 解析
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

  /// 确保生成符合标准 16kHz 16-bit 单声道的临时物理 WAV 文件 (供原生推理 Worker 流式读取)
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
    final raf = await File(outPath).open(mode: FileMode.write);
    try {
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
      await raf.writeFrom(header.buffer.asUint8List());

      // 分块流式写出，避免一次性分配完整 Int16List + BytesBuilder 双倍缓冲
      const chunkSamples = 32768;
      final pcmBlock = Int16List(chunkSamples);
      int offset = 0;
      while (offset < samples.length) {
        final end = (offset + chunkSamples < samples.length) ? (offset + chunkSamples) : samples.length;
        final count = end - offset;
        for (int i = 0; i < count; i++) {
          pcmBlock[i] = (samples[offset + i].clamp(-1.0, 1.0) * 32767.0).round();
        }
        await raf.writeFrom(Uint8List.view(pcmBlock.buffer, 0, count * 2));
        offset = end;
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    return outPath;
  }

  /// 对已解码的 16kHz 音频执行 Silero-VAD 神经网络自然切句与纯净多角色转写 (支持分句实时落库与毫秒级断点续转)
  Future<List<TranscriptSegment>> _transcribeDecodedAudio(
    MeetingTask task,
    DecodedAudioResult decoded, {
    required ModelConfig modelConfig,
    int startOffsetMs = 0,
    int initialSegmentIndex = 0,
  }) async {
    final worker = InferenceWorkerCoordinator.instance;
    final isInitialized = await worker.initialize(modelConfig);
    if (!isInitialized) {
      throw Exception('离线语音识别引擎初始化失败，请确认模型资产文件是否完整无损坏');
    }

    final wavPath = await _ensureStandard16kWavFile(task.audioPath, decoded);
    final isTempDecodedWav = wavPath != task.audioPath && wavPath.contains('decoded_wavs');

    // 1. 实时监听子 Isolate 派发的自然句平滑转写进度
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

    // 2. 实时监听每一句转写完成，立即执行增量持久化落库 (断点保护核心机制)
    final segmentSub = worker.onSegmentTranscribed.listen((event) async {
      if (event.taskId == task.id && event.text.trim().isNotEmpty) {
        final seg = TranscriptSegment(
          taskId: event.taskId,
          speakerId: event.speakerId,
          speakerName: event.speakerName,
          startMs: event.startMs,
          endMs: event.endMs,
          text: event.text,
        );
        try {
          await AppDatabase.instance.insertSegment(seg);
        } catch (e) {
          debugPrint('[TaskQueueService] 实时增量落库段落异常: $e');
        }
      }
    });

    try {
      final fileResponse = await worker.transcribeFile(TranscribeFileCommand(
        messageId: 'file_${task.id}_${DateTime.now().millisecondsSinceEpoch}',
        taskId: task.id,
        audioFilePath: wavPath,
        enableDiarization: true,
        startOffsetMs: startOffsetMs,
        initialSegmentIndex: initialSegmentIndex,
      ));

      if (fileResponse == null || !fileResponse.isSuccess) {
        throw Exception(fileResponse?.errorMessage ?? '离线语音转写未返回有效结果');
      }

      final rawSegments = fileResponse.segments
          .map((p) => TranscriptSegment(
                taskId: p.taskId,
                speakerId: p.speakerId,
                speakerName: p.speakerName,
                startMs: p.startMs,
                endMs: p.endMs,
                text: p.text,
              ))
          .toList();

      // 自动执行智能上下文与同发言人破碎断句整合优化
      final optimizeResult = TranscriptContextOptimizer.optimize(rawSegments);
      final segments = optimizeResult.segments;

      if (optimizeResult.mergedCount > 0) {
        debugPrint(
            '[TaskQueueService] 转写完成，自动整合上下文完成: 原始 ${rawSegments.length} 段 -> 优化后 ${segments.length} 段 (合并 ${optimizeResult.mergedCount} 处碎片断句)');
        await AppDatabase.instance.replaceSegmentsForTask(task.id, segments);
      } else if (startOffsetMs == 0 && segments.isNotEmpty) {
        // 若无合并且为首次转写，进行兜底事务批量落库校验
        final saved = await AppDatabase.instance.getSegmentsForTask(task.id);
        if (saved.length < segments.length) {
          await AppDatabase.instance.clearSegmentsForTask(task.id);
          await AppDatabase.instance.insertSegmentsBatch(segments);
        }
      }

      return segments;
    } finally {
      await progressSub.cancel();
      await segmentSub.cancel();
      if (isTempDecodedWav) {
        try {
          final tempFile = File(wavPath);
          if (tempFile.existsSync()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }
  }
}
