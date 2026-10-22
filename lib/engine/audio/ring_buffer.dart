import 'dart:math';
import 'dart:typed_data';
import '../../core/constants/app_constants.dart';

/// 30 秒定长音频环形缓冲区 (零内存膨胀内存管理)
///
/// 针对超长会议 (2~4 小时) 场景：
/// 录音数据严禁全量常驻内存中，本缓冲区仅在内存中维护固定 30 秒窗口容量，
/// 新采集的数据自动覆盖最老数据，保证运行时内存始终在水位线以内。
class AudioRingBuffer {
  final int capacitySamples;
  late final Float32List _buffer;
  int _writeIndex = 0;
  int _totalWrittenSamples = 0;

  AudioRingBuffer({
    int seconds = AppConstants.ringBufferSeconds,
    int sampleRate = AppConstants.sampleRate,
  }) : capacitySamples = seconds * sampleRate {
    _buffer = Float32List(capacitySamples);
  }

  /// 写入新的音频浮点采样点流
  void write(Float32List samples) {
    for (int i = 0; i < samples.length; i++) {
      _buffer[_writeIndex] = samples[i];
      _writeIndex = (_writeIndex + 1) % capacitySamples;
      _totalWrittenSamples++;
    }
  }

  /// 获取最近 N 秒的音频切片 (例如用于 VAD 切片或声纹特征抽取)
  Float32List readRecentSeconds(double seconds, {int sampleRate = AppConstants.sampleRate}) {
    final requestedSamples = min((seconds * sampleRate).toInt(), capacitySamples);
    final count = min(requestedSamples, _totalWrittenSamples);
    if (count <= 0) return Float32List(0);

    final result = Float32List(count);
    int readStart = (_writeIndex - count + capacitySamples) % capacitySamples;

    for (int i = 0; i < count; i++) {
      result[i] = _buffer[(readStart + i) % capacitySamples];
    }
    return result;
  }

  /// 当前总写入样本数
  int get totalWrittenSamples => _totalWrittenSamples;

  /// 已录制累计时长 (毫秒)
  int get recordedDurationMs =>
      ((_totalWrittenSamples / AppConstants.sampleRate) * 1000).toInt();

  /// 清空并重置缓冲区
  void clear() {
    _writeIndex = 0;
    _totalWrittenSamples = 0;
    _buffer.fillRange(0, capacitySamples, 0.0);
  }
}
