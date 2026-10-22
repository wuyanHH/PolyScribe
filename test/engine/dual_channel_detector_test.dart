import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/diarization/dual_channel_detector.dart';

void main() {
  group('DualChannelDetector 通话录音双声道互相关测试', () {
    test('物理独立双声道检测 (左声道与右声道独立无关)', () {
      // 构造交织 PCM: 左声道为方波 1000，右声道为方波 -1000
      final pcm = Int16List(4000);
      for (int i = 0; i < 2000; i++) {
        pcm[i * 2] = (i % 20 < 10) ? 1500 : -1500;     // L
        pcm[i * 2 + 1] = (i % 30 < 15) ? 1200 : -1200; // R
      }

      final result = DualChannelDetector.analyzeInterleavedPcm(pcm);
      expect(result.correlation, lessThan(0.35));
      expect(result.isStereoSeparated, true);
    });

    test('单声道立体声检测 (左右声道波形完全一致)', () {
      final pcm = Int16List(4000);
      for (int i = 0; i < 2000; i++) {
        final val = (i % 20 < 10) ? 1000 : -1000;
        pcm[i * 2] = val;     // L
        pcm[i * 2 + 1] = val; // R 相同
      }

      final result = DualChannelDetector.analyzeInterleavedPcm(pcm);
      expect(result.correlation, greaterThan(0.99));
      expect(result.isStereoSeparated, false);
    });
  });
}
