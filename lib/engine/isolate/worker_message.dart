import 'dart:typed_data';
import '../model_manager.dart';

/// 工作线程接收的指令基础类
abstract class WorkerCommand {
  final String messageId;
  const WorkerCommand({required this.messageId});
}

/// 模型初始化指令
class InitWorkerCommand extends WorkerCommand {
  final ModelConfig config;
  const InitWorkerCommand({
    required super.messageId,
    required this.config,
  });
}

/// 离线文件转写请求
class TranscribeFileCommand extends WorkerCommand {
  final String taskId;
  final String audioFilePath;
  final bool enableDiarization;

  const TranscribeFileCommand({
    required super.messageId,
    required this.taskId,
    required this.audioFilePath,
    this.enableDiarization = true,
  });
}

/// 实时 PCM 流切片转写请求
class TranscribeChunkCommand extends WorkerCommand {
  final String taskId;
  final Float32List samples; // 16kHz Float32 PCM 单声道样本
  final int chunkIndex;
  final int startMs;
  final int endMs;

  const TranscribeChunkCommand({
    required super.messageId,
    required this.taskId,
    required this.samples,
    required this.chunkIndex,
    required this.startMs,
    required this.endMs,
  });
}

/// 释放或重置工作线程模型
class DisposeWorkerCommand extends WorkerCommand {
  const DisposeWorkerCommand({required super.messageId});
}

/// 工作线程返回的响应基础类
class WorkerResponse {
  final String messageId;
  final bool isSuccess;
  final String? errorMessage;

  const WorkerResponse({
    required this.messageId,
    required this.isSuccess,
    this.errorMessage,
  });
}

/// 初始化结果返回
class InitWorkerResponse extends WorkerResponse {
  final bool isModelLoaded;
  const InitWorkerResponse({
    required super.messageId,
    required super.isSuccess,
    required this.isModelLoaded,
    super.errorMessage,
  });
}

/// 转写段落结果返回
class SegmentTranscriptionResponse extends WorkerResponse {
  final String taskId;
  final int segmentIndex;
  final String speakerId;
  final String? speakerName;
  final int startMs;
  final int endMs;
  final String text;
  final String language;
  final bool isFinal;

  const SegmentTranscriptionResponse({
    required super.messageId,
    required this.taskId,
    required this.segmentIndex,
    required this.speakerId,
    this.speakerName,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.language = 'zh',
    this.isFinal = true,
    super.isSuccess = true,
    super.errorMessage,
  });
}
