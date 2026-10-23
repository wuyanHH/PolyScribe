import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/audio/wav_codec.dart';

void main() {
  group('WavCodec 全规格 WAV 编解码与重采样测试', () {
    test('标准 16kHz 16-bit 单声道 WAV 编码与解码闭环测试', () {
      final srcSamples = Float32List(16000);
      for (int i = 0; i < srcSamples.length; i++) {
        srcSamples[i] = 0.5 * sin(2 * pi * 440 * i / 16000);
      }

      final wavBytes = WavCodec.encodeMono16BitWavBytes(srcSamples, sampleRate: 16000);
      expect(wavBytes.length, 44 + 16000 * 2);

      final decoded = WavCodec.decodeWavBytes(
        wavBytes,
        targetSampleRate: 16000,
        normalizeVolume: false,
      );
      expect(decoded, isNotNull);
      expect(decoded!.sampleRate, 16000);
      expect(decoded.originalChannels, 1);
      expect(decoded.durationMs, 1000);
      expect(decoded.monoSamples.length, 16000);
    });

    test('48kHz 双声道 32-bit IEEE Float WAV 解码并重采样为 16kHz 单声道测试', () {
      const srcRate = 48000;
      const channels = 2;
      const frames = 48000; // 1 秒
      const dataBytes = frames * channels * 4;
      final buf = Uint8List(44 + dataBytes);
      final bd = ByteData.sublistView(buf);

      // 写入 48kHz 双声道 32-bit Float (audioFormat = 3) WAV 头
      for (int i = 0; i < 4; i++) {
        buf[i] = 'RIFF'.codeUnitAt(i);
        buf[8 + i] = 'WAVE'.codeUnitAt(i);
        buf[12 + i] = 'fmt '.codeUnitAt(i);
        buf[36 + i] = 'data'.codeUnitAt(i);
      }
      bd.setUint32(4, 36 + dataBytes, Endian.little);
      bd.setUint32(16, 16, Endian.little);
      bd.setUint16(20, 3, Endian.little); // 3 = IEEE Float
      bd.setUint16(22, channels, Endian.little);
      bd.setUint32(24, srcRate, Endian.little);
      bd.setUint32(28, srcRate * channels * 4, Endian.little);
      bd.setUint16(32, channels * 4, Endian.little);
      bd.setUint16(34, 32, Endian.little); // 32-bit float
      bd.setUint32(40, dataBytes, Endian.little);

      for (int f = 0; f < frames; f++) {
        final v = 0.05 * sin(2 * pi * 300 * f / srcRate);
        bd.setFloat32(44 + f * 8, v, Endian.little);
        bd.setFloat32(44 + f * 8 + 4, v, Endian.little);
      }

      final decoded = WavCodec.decodeWavBytes(
        buf,
        targetSampleRate: 16000,
        normalizeVolume: true,
      );
      expect(decoded, isNotNull);
      expect(decoded!.sampleRate, 16000);
      expect(decoded.originalChannels, 2);
      expect(decoded.monoSamples.length, 16000);

      // 验证弱音自动归一化已将原 0.05 峰值提振至 > 0.7
      double maxPeak = 0.0;
      for (final s in decoded.monoSamples) {
        if (s.abs() > maxPeak) maxPeak = s.abs();
      }
      expect(maxPeak, greaterThan(0.7));
    });
  });
}
