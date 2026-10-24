import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../diarization/dual_channel_detector.dart';

/// 解码后的标准音频数据结果
class DecodedAudioResult {
  /// 单声道归一化浮点采样数据 (-1.0 ~ 1.0)
  final Float32List monoSamples;

  /// 采样率 (如 16000)
  final int sampleRate;

  /// 原始声道数
  final int originalChannels;

  /// 原始音频时长 (毫秒)
  final int durationMs;

  /// 双声道物理分离检测结果
  final DualChannelAnalysis channelAnalysis;

  /// 标准 16kHz WAV 物理文件缓存路径 (若已生成)
  final String standardWavPath;

  const DecodedAudioResult({
    required this.monoSamples,
    required this.sampleRate,
    required this.originalChannels,
    required this.durationMs,
    required this.channelAnalysis,
    this.standardWavPath = '',
  });
}

/// 全规格 RIFF/WAVE 编解码与重采样工具
/// 支持 8/16/24/32-bit PCM、32/64-bit IEEE Float、WAVE_FORMAT_EXTENSIBLE (0xFFFE)、
/// ALAW/MULAW 以及含 JUNK/LIST/fact/bext 等任意扩展块的 WAV 文件。
class WavCodec {
  /// 解析 WAV 字节数组并转换为指定采样率 (默认 16000Hz) 的单声道 Float32 样本
  static DecodedAudioResult? decodeWavBytes(
    Uint8List bytes, {
    int targetSampleRate = 16000,
    bool normalizeVolume = true,
  }) {
    if (bytes.length < 44) return null;
    final bd = ByteData.sublistView(bytes);

    // 检查 RIFF / WAVE 魔数
    final riff = _readFourCC(bytes, 0);
    final wave = _readFourCC(bytes, 8);
    if (riff != 'RIFF' && riff != 'RIFX') return null;
    if (wave != 'WAVE') return null;

    int audioFormat = 1;
    int numChannels = 1;
    int sampleRate = 16000;
    int bitsPerSample = 16;
    int dataOffset = -1;
    int dataLength = 0;

    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkId = _readFourCC(bytes, offset);
      final chunkSize = bd.getUint32(offset + 4, Endian.little);
      final chunkDataStart = offset + 8;

      if (chunkId == 'fmt ') {
        if (chunkDataStart + 16 > bytes.length) break;
        audioFormat = bd.getUint16(chunkDataStart, Endian.little);
        numChannels = bd.getUint16(chunkDataStart + 2, Endian.little);
        sampleRate = bd.getUint32(chunkDataStart + 4, Endian.little);
        bitsPerSample = bd.getUint16(chunkDataStart + 14, Endian.little);

        // 处理 WAVE_FORMAT_EXTENSIBLE (0xFFFE = 65534)
        if (audioFormat == 0xFFFE && chunkSize >= 40 && chunkDataStart + 26 <= bytes.length) {
          final validBits = bd.getUint16(chunkDataStart + 18, Endian.little);
          if (validBits > 0 && validBits <= bitsPerSample) {
            // 保持容器位深以正确步进，但记录子格式
          }
          // SubFormat GUID 的前 2 个字节表示真实的编码格式 (1 = PCM, 3 = IEEE_FLOAT)
          audioFormat = bd.getUint16(chunkDataStart + 24, Endian.little);
        }
      } else if (chunkId == 'data') {
        dataOffset = chunkDataStart;
        // 兼容流式录音未回填完 chunkSize (0xFFFFFFFF 或超出文件末尾) 的情况
        final remaining = bytes.length - chunkDataStart;
        dataLength = (chunkSize == 0 || chunkSize > remaining) ? remaining : chunkSize;
        break;
      }

      // 步进到下一个 chunk (RIFF 要求偶数字节对齐)
      final paddedSize = (chunkSize + 1) & ~1;
      if (paddedSize < 0 || chunkDataStart + paddedSize <= offset) break;
      offset = chunkDataStart + paddedSize;
    }

    if (dataOffset < 0 || dataLength <= 0 || numChannels <= 0 || sampleRate <= 0) {
      return null;
    }

    final bytesPerSample = (bitsPerSample ~/ 8).clamp(1, 8);
    final bytesPerFrame = bytesPerSample * numChannels;
    final totalFrames = dataLength ~/ bytesPerFrame;
    if (totalFrames <= 0) return null;

    final monoSamples = Float32List(totalFrames);
    // 用于双声道相关性分析的交错 Int16 样本 (最多取前 10 秒以提速)
    final maxAnalysisFrames = min(totalFrames, sampleRate * 10);
    final interleavedForAnalysis = numChannels >= 2
        ? Int16List(maxAnalysisFrames * 2)
        : Int16List(0);

    for (int f = 0; f < totalFrames; f++) {
      final frameStart = dataOffset + f * bytesPerFrame;
      double sum = 0.0;

      for (int c = 0; c < numChannels; c++) {
        final sampleStart = frameStart + c * bytesPerSample;
        final val = _readSampleAsDouble(
          bd,
          bytes,
          sampleStart,
          audioFormat,
          bitsPerSample,
        );
        sum += val;

        if (numChannels >= 2 && c < 2 && f < maxAnalysisFrames) {
          interleavedForAnalysis[f * 2 + c] =
              (val.clamp(-1.0, 1.0) * 32767.0).round();
        }
      }

      monoSamples[f] = (sum / numChannels).clamp(-1.0, 1.0);
    }

    final channelAnalysis = numChannels >= 2
        ? DualChannelDetector.analyzeInterleavedPcm(interleavedForAnalysis)
        : const DualChannelAnalysis(
            isStereoSeparated: false,
            correlation: 1.0,
            description: '单声道音频',
          );

    // 重采样至目标采样率 (如 16000Hz)
    Float32List finalSamples = monoSamples;
    if (sampleRate != targetSampleRate) {
      finalSamples = resampleLinear(monoSamples, sampleRate, targetSampleRate);
    }

    // 自适应音量归一化 (解决弱音/远场录音声音过小无法识别的问题)
    if (normalizeVolume && finalSamples.isNotEmpty) {
      applyAdaptiveNormalization(finalSamples);
    }

    final durationMs = (totalFrames * 1000) ~/ sampleRate;

    return DecodedAudioResult(
      monoSamples: finalSamples,
      sampleRate: targetSampleRate,
      originalChannels: numChannels,
      durationMs: durationMs,
      channelAnalysis: channelAnalysis,
    );
  }

  /// 读取单个样本并归一化至 [-1.0, 1.0]
  static double _readSampleAsDouble(
    ByteData bd,
    Uint8List raw,
    int offset,
    int audioFormat,
    int bitsPerSample,
  ) {
    if (audioFormat == 3) {
      // IEEE Float
      if (bitsPerSample == 32 && offset + 4 <= raw.length) {
        final v = bd.getFloat32(offset, Endian.little);
        return v.isNaN || v.isInfinite ? 0.0 : v.clamp(-1.0, 1.0);
      } else if (bitsPerSample == 64 && offset + 8 <= raw.length) {
        final v = bd.getFloat64(offset, Endian.little);
        return v.isNaN || v.isInfinite ? 0.0 : v.clamp(-1.0, 1.0);
      }
    } else if (audioFormat == 6 && offset < raw.length) {
      // A-Law
      return _alawToLinear(raw[offset]) / 32768.0;
    } else if (audioFormat == 7 && offset < raw.length) {
      // mu-Law
      return _ulawToLinear(raw[offset]) / 32768.0;
    }

    // 默认按 PCM 整数解析
    if (bitsPerSample == 8 && offset < raw.length) {
      // 8-bit WAV 为无符号 0~255
      return (raw[offset] - 128) / 128.0;
    } else if (bitsPerSample == 16 && offset + 2 <= raw.length) {
      return bd.getInt16(offset, Endian.little) / 32768.0;
    } else if (bitsPerSample == 24 && offset + 3 <= raw.length) {
      int v = raw[offset] | (raw[offset + 1] << 8) | (raw[offset + 2] << 16);
      if ((v & 0x800000) != 0) v |= ~0xFFFFFF; // 符号位扩展
      return v / 8388608.0;
    } else if (bitsPerSample == 32 && offset + 4 <= raw.length) {
      return bd.getInt32(offset, Endian.little) / 2147483648.0;
    }
    return 0.0;
  }

  /// 带简单抗混叠平滑的采样率转换
  static Float32List resampleLinear(
    Float32List input,
    int srcRate,
    int dstRate,
  ) {
    if (srcRate == dstRate || input.isEmpty || srcRate <= 0 || dstRate <= 0) {
      return input;
    }
    final double ratio = srcRate / dstRate;
    final int targetLength = (input.length / ratio).floor();
    if (targetLength <= 0) return Float32List(0);

    final output = Float32List(targetLength);
    if (ratio > 1.5) {
      // 下采样抗混叠：对邻域窗口取均值再插值，消除高频混叠噪声
      final int halfWin = max(1, (ratio * 0.5).floor());
      for (int i = 0; i < targetLength; i++) {
        final double center = i * ratio;
        final int cIdx = center.round();
        final int start = max(0, cIdx - halfWin);
        final int end = min(input.length - 1, cIdx + halfWin);
        double sum = 0.0;
        for (int k = start; k <= end; k++) {
          sum += input[k];
        }
        output[i] = sum / (end - start + 1);
      }
    } else {
      for (int i = 0; i < targetLength; i++) {
        final double srcIndex = i * ratio;
        final int index0 = srcIndex.floor();
        final int index1 = min(index0 + 1, input.length - 1);
        final double fraction = srcIndex - index0;
        output[i] = input[index0] * (1.0 - fraction) + input[index1] * fraction;
      }
    }
    return output;
  }

  /// 自适应音量归一化 (针对声音过小或内录弱信号自动增益，但不放大纯底噪)
  static void applyAdaptiveNormalization(Float32List samples) {
    if (samples.isEmpty) return;

    // 去除直流偏置 (DC Offset)
    double mean = 0.0;
    for (int i = 0; i < samples.length; i++) {
      mean += samples[i];
    }
    mean /= samples.length;

    double peak = 0.0;
    double sumSq = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final v = samples[i] - mean;
      samples[i] = v;
      final absV = v.abs();
      if (absV > peak) peak = absV;
      sumSq += v * v;
    }

    final rms = sqrt(sumSq / samples.length);
    // 高保真响度保护：对微弱录音 (Peak < 0.65 且非纯死寂) 进行平滑适度归一化 (目标峰值 0.75，最大增益限幅 15 倍)
    // 杜绝 25+ 倍过度拉伸导致的削顶失真，同时兼顾低电平微弱音频的清晰度
    if (peak > 0.002 && rms > 0.0003 && peak < 0.65) {
      final gain = min(0.75 / peak, 15.0);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = (samples[i] * gain).clamp(-0.95, 0.95);
      }
    }
  }

  /// 将单声道 Float32 样本写盘为标准 16-bit PCM WAV 文件
  static Future<void> writeMono16kWavFile(
    String filePath,
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    final pcmBytes = encodeMono16BitWavBytes(samples, sampleRate: sampleRate);
    final file = File(filePath);
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsBytes(pcmBytes, flush: true);
  }

  /// 将单声道 Float32 样本编码为完整 WAV 字节流 (含 44 字节 RIFF Header)
  static Uint8List encodeMono16BitWavBytes(
    Float32List samples, {
    int sampleRate = 16000,
  }) {
    final dataSize = samples.length * 2;
    final totalSize = 44 + dataSize;
    final out = Uint8List(totalSize);
    final bd = ByteData.sublistView(out);

    // RIFF Header
    _writeFourCC(out, 0, 'RIFF');
    bd.setUint32(4, 36 + dataSize, Endian.little);
    _writeFourCC(out, 8, 'WAVE');

    // fmt chunk
    _writeFourCC(out, 12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    bd.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
    bd.setUint16(22, 1, Endian.little); // NumChannels = 1
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    bd.setUint16(32, 2, Endian.little); // BlockAlign
    bd.setUint16(34, 16, Endian.little); // BitsPerSample

    // data chunk
    _writeFourCC(out, 36, 'data');
    bd.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < samples.length; i++) {
      final s = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
      bd.setInt16(44 + i * 2, s, Endian.little);
    }
    return out;
  }

  static String _readFourCC(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }

  static void _writeFourCC(Uint8List bytes, int offset, String cc) {
    for (int i = 0; i < 4; i++) {
      bytes[offset + i] = cc.codeUnitAt(i);
    }
  }

  static int _alawToLinear(int aVal) {
    aVal ^= 0x55;
    int t = (aVal & 0x0F) << 4;
    final seg = (aVal & 0x70) >> 4;
    switch (seg) {
      case 0:
        t += 8;
        break;
      case 1:
        t += 0x108;
        break;
      default:
        t += 0x108;
        t <<= seg - 1;
    }
    return (aVal & 0x80) != 0 ? t : -t;
  }

  static int _ulawToLinear(int uVal) {
    uVal = ~uVal & 0xFF;
    int t = ((uVal & 0x0F) << 3) + 0x84;
    t <<= (uVal & 0x70) >> 4;
    return (uVal & 0x80) != 0 ? (0x84 - t) : (t - 0x84);
  }
}
