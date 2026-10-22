import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/audio/ring_buffer.dart';

void main() {
  group('AudioRingBuffer 30秒环形缓冲区测试', () {
    test('基本写入与读取最近数据', () {
      // 设定容量为 1 秒 (16000 采样点)
      final ring = AudioRingBuffer(seconds: 1, sampleRate: 16000);

      // 写入 8000 个采样点 (0.5秒)
      final chunk1 = Float32List(8000);
      for (int i = 0; i < 8000; i++) {
        chunk1[i] = 1.0;
      }
      ring.write(chunk1);

      expect(ring.totalWrittenSamples, 8000);
      expect(ring.recordedDurationMs, 500);

      // 读取最近 0.25 秒 (4000 个采样点)
      final recent = ring.readRecentSeconds(0.25, sampleRate: 16000);
      expect(recent.length, 4000);
      expect(recent[0], 1.0);
    });

    test('循环覆盖与无内存膨胀测试 (多次写入超出容量)', () {
      final ring = AudioRingBuffer(seconds: 1, sampleRate: 16000);

      // 连续写入 10 次 8000 个样本 (总共 80000 样本，超过 1 秒容量 5 倍)
      for (int step = 0; step < 10; step++) {
        final chunk = Float32List(8000);
        chunk.fillRange(0, 8000, step.toDouble());
        ring.write(chunk);
      }

      // 总写入量正确记录
      expect(ring.totalWrittenSamples, 80000);

      // 读取最近 0.5 秒 (4000 个样本)，应该全部是最新的 step = 9 的数据
      final recent = ring.readRecentSeconds(0.25, sampleRate: 16000);
      expect(recent.length, 4000);
      expect(recent.last, 9.0);
    });

    test('重置缓冲区', () {
      final ring = AudioRingBuffer(seconds: 1, sampleRate: 16000);
      ring.write(Float32List(5000));
      expect(ring.totalWrittenSamples, 5000);

      ring.clear();
      expect(ring.totalWrittenSamples, 0);
      expect(ring.recordedDurationMs, 0);
    });
  });
}
