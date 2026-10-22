import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/constants/app_constants.dart';

/// 会议音频分段写盘与容灾刷新器
class AudioChunkFlusher {
  final String outputDirectory;
  final String taskId;
  int _chunkIndex = 0;
  IOSink? _currentSink;
  File? _currentFile;
  int _currentChunkSamples = 0;

  AudioChunkFlusher({
    required this.outputDirectory,
    required this.taskId,
  });

  /// 写入音频流并按时间分段落盘 (默认 5 分钟切片)
  Future<void> appendPcm(Uint8List pcmBytes) async {
    if (_currentSink == null) {
      await _openNewChunk();
    }

    _currentSink?.add(pcmBytes);
    _currentChunkSamples += pcmBytes.length ~/ 2;

    // 检查是否达到 5 分钟分段阈值 (16000 * 60 * 5 个样本)
    final fiveMinSamples = AppConstants.sampleRate * 60 * AppConstants.autoChunkFlushMinutes;
    if (_currentChunkSamples >= fiveMinSamples) {
      await flushAndRotate();
    }
  }

  /// 刷新当前切片并开启下一个分段文件
  Future<void> flushAndRotate() async {
    if (_currentSink != null) {
      await _currentSink!.flush();
      await _currentSink!.close();
      _currentSink = null;
      debugPrint('[AudioChunkFlusher] 已完成分段落盘: ${_currentFile?.path}');
    }
    _chunkIndex++;
    _currentChunkSamples = 0;
  }

  Future<void> _openNewChunk() async {
    final dir = Directory(outputDirectory);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    final path = '${dir.path}/${taskId}_chunk_${_chunkIndex.toString().padLeft(3, '0')}.pcm';
    _currentFile = File(path);
    _currentSink = _currentFile!.openWrite(mode: FileMode.append);
  }

  /// 结束录音并关闭所有句柄
  Future<String?> finalizeRecording() async {
    await flushAndRotate();
    return _currentFile?.path;
  }
}
