import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/voice_print.dart';
import 'package:polyscribe/engine/diarization/online_centroid_bank.dart';

void main() {
  group('OnlineCentroidBank 动态声纹质心池测试', () {
    test('新角色判定与递增分配', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.52);

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
        startMs: 5000,
        endMs: 7500,
      );

      expect(res2.speakerId, 'SPK_02');
      expect(res2.isNewSpeaker, true);
    });

    test('相似向量应聚合至同一角色并更新质心', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.52);

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

    test('短语音漂移抑制 (短于1200ms且间隔在2.5秒内平滑继承上一角色)', () {
      final bank = OnlineCentroidBank(similarityThreshold: 0.52);

      // 角色 1 发言到 2000ms
      final v1 = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      bank.assignSpeaker(
        embedding: v1,
        durationMs: 2000,
        startMs: 0,
        endMs: 2000,
      );

      // 持续 800ms 的短句，间隔 1.2 秒（自然换气停顿），即使由于短音离散特征偏离，也应稳健继承 SPK_01
      final driftVec = Float32List.fromList([0.0, 0.0, 1.0, 0.0]);
      final res = bank.assignSpeaker(
        embedding: driftVec,
        durationMs: 800,
        startMs: 3200, // 间隔 1200ms <= 2500ms
        endMs: 4000,
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
        similarityThreshold: 0.52,
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

    test('全局声纹质心收敛合并 (消除同一个人误切多角)', () {
      // 模拟极端情况下设置了较高的初始判定门限 (0.70)，导致同一个人的两个向量被误判为不同角色
      final bank = OnlineCentroidBank(similarityThreshold: 0.70);

      // SPK_01：向量 [1.0, 0.0, 0.0]
      final res1 = bank.assignSpeaker(
        embedding: Float32List.fromList([1.0, 0.0, 0.0]),
        durationMs: 2500,
        startMs: 0,
        endMs: 2500,
      );
      expect(res1.speakerId, 'SPK_01');

      // SPK_02：向量 [0.55, 0.835, 0.0]，相似度约为 0.55 < 0.70，被分裂为 SPK_02
      final res2 = bank.assignSpeaker(
        embedding: Float32List.fromList([0.55, 0.835, 0.0]),
        durationMs: 2500,
        startMs: 8000,
        endMs: 10500,
      );
      expect(res2.speakerId, 'SPK_02');

      // 后处理全局收敛：以自然松弛阈值 0.50 合并
      final mergeMap = bank.consolidateSpeakers(mergeThreshold: 0.50);

      // SPK_02 应成功被重定向收敛归并至 SPK_01
      expect(mergeMap['SPK_02'], 'SPK_01');
    });
  });
}
