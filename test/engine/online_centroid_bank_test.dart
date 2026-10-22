import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/voice_print.dart';
import 'package:polyscribe/engine/diarization/online_centroid_bank.dart';

void main() {
  group('OnlineCentroidBank 动态声纹质心池测试', () {
    test('新角色判定与递增分配', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.65);

      // 创建一个维数为 4 的测试向量 [1.0, 0.0, 0.0, 0.0]
      final spk1Vec = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      final res1 = bank.assignSpeaker(
        embedding: spk1Vec,
        durationMs: 2000,
        startMs: 0,
        endMs: 2000,
      );

      expect(res1.speakerId, 'SPK_01');
      expect(res1.isNewSpeaker, true);

      // 创建正交向量 [0.0, 1.0, 0.0, 0.0]，相似度为 0
      final spk2Vec = Float32List.fromList([0.0, 1.0, 0.0, 0.0]);
      final res2 = bank.assignSpeaker(
        embedding: spk2Vec,
        durationMs: 2500,
        startMs: 2500,
        endMs: 5000,
      );

      expect(res2.speakerId, 'SPK_02');
      expect(res2.isNewSpeaker, true);
    });

    test('相似向量应聚合至同一角色并更新质心', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.65);

      final v1 = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      bank.assignSpeaker(
        embedding: v1,
        durationMs: 2000,
        startMs: 0,
        endMs: 2000,
      );

      // 高度相似向量 [0.95, 0.05, 0.0, 0.0]
      final v1Similar = Float32List.fromList([0.95, 0.05, 0.0, 0.0]);
      final res = bank.assignSpeaker(
        embedding: v1Similar,
        durationMs: 1500,
        startMs: 2500,
        endMs: 4000,
      );

      expect(res.speakerId, 'SPK_01');
      expect(res.isNewSpeaker, false);
      expect(res.similarity, greaterThan(0.9));
    });

    test('极短语音漂移抑制 (短于800ms且间隔短于400ms时继承上一角色)', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.65);

      // 角色 1 发言到 2000ms
      final v1 = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      bank.assignSpeaker(
        embedding: v1,
        durationMs: 2000,
        startMs: 0,
        endMs: 2000,
      );

      // 仅持续 300ms 的语气词“嗯/啊”，即使特征向量完全不同（由于离散性），也应继承 SPK_01
      final driftVec = Float32List.fromList([0.0, 0.0, 1.0, 0.0]);
      final res = bank.assignSpeaker(
        embedding: driftVec,
        durationMs: 300,
        startMs: 2100, // 间隔仅 100ms
        endMs: 2400,
      );

      expect(res.speakerId, 'SPK_01');
      expect(res.isNewSpeaker, false);
    });

    test('实名声纹库先验匹配', () {
      final zhangZongVector = Float32List.fromList([0.0, 0.0, 0.0, 1.0]);
      final zhangZongPrint = VoicePrint(
        id: 'VP_001',
        personName: '张总',
        embedding: zhangZongVector,
        createdAt: 1000,
        updatedAt: 1000,
      );

      final bank = OnlineCentroidBank(
        similarityThreshold: 0.65,
        initialVoicePrints: [zhangZongPrint],
      );

      // 输入张总相符的声纹
      final testVec = Float32List.fromList([0.0, 0.0, 0.0, 0.98]);
      final res = bank.assignSpeaker(
        embedding: testVec,
        durationMs: 3000,
        startMs: 0,
        endMs: 3000,
      );

      expect(res.speakerName, '张总');
      expect(res.similarity, greaterThan(0.95));
    });
  });
}
