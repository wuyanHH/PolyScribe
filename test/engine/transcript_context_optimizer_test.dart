import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/engine/text/transcript_context_optimizer.dart';

void main() {
  group('TranscriptContextOptimizer 上下文整合优化引擎测试', () {
    test('相同说话人短暂停顿的一句话分为两句，应被精准合并', () {
      final segments = [
        const TranscriptSegment(
          id: 1,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          speakerName: '张经理',
          startMs: 1000,
          endMs: 3000,
          text: '今天我们主要讨论一下关于这个',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          speakerName: '张经理',
          startMs: 3400, // 停顿 400ms
          endMs: 6000,
          text: '新版本的架构设计方案。',
        ),
      ];

      final res = TranscriptContextOptimizer.optimize(segments);
      expect(res.optimizedCount, 1);
      expect(res.mergedCount, 1);
      expect(res.segments.first.startMs, 1000);
      expect(res.segments.first.endMs, 6000);
      expect(res.segments.first.text, '今天我们主要讨论一下关于这个，新版本的架构设计方案。');
    });

    test('不同发言人的连续发言不应被合并', () {
      final segments = [
        const TranscriptSegment(
          id: 1,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          speakerName: '张经理',
          startMs: 1000,
          endMs: 2500,
          text: '大家好。',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 'task_1',
          speakerId: 'SPK_02',
          speakerName: '李工程师',
          startMs: 2800,
          endMs: 4000,
          text: '张总好。',
        ),
      ];

      final res = TranscriptContextOptimizer.optimize(segments);
      expect(res.optimizedCount, 2);
      expect(res.mergedCount, 0);
    });

    test('同一发言人时间间隔过久 (大于2.5秒)，不应强行粘连', () {
      final segments = [
        const TranscriptSegment(
          id: 1,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          startMs: 1000,
          endMs: 3000,
          text: '这是第一项任务说明。',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          startMs: 8000, // 停顿 5000ms
          endMs: 11000,
          text: '过了一会儿，我们再看第二项。',
        ),
      ];

      final res = TranscriptContextOptimizer.optimize(segments);
      expect(res.optimizedCount, 2);
      expect(res.mergedCount, 0);
    });

    test('极短语气词与碎片 (<=4字) 即使有一定间隔也应整合进主发言', () {
      final segments = [
        const TranscriptSegment(
          id: 1,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          startMs: 1000,
          endMs: 1600,
          text: '然后',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          startMs: 2200,
          endMs: 4500,
          text: '我们来看具体的实现代码。',
        ),
      ];

      final res = TranscriptContextOptimizer.optimize(segments);
      expect(res.optimizedCount, 1);
      expect(res.segments.first.text, '然后，我们来看具体的实现代码。');
    });

    test('双向三元组说话人平滑：消除 A-B-A 孤立声学漂移夹心短片并重构连贯段落', () {
      // 模拟张总发言过程中，中间仅 1 秒因为声调或轻度漂移被声学模型孤立误切为 SPK_02，前后紧接着都是张总
      final segments = [
        const TranscriptSegment(
          id: 1,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          speakerName: '张总',
          startMs: 1000,
          endMs: 3500,
          text: '关于下个阶段的总体战略布局，',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 'task_1',
          speakerId: 'SPK_02', // 假阳性声学漂移夹心
          speakerName: '发言人 2',
          startMs: 4000, // 间隔 500ms
          endMs: 5200,   // 时长 1.2s <= 2.5s
          text: '特别关键的是，',
        ),
        const TranscriptSegment(
          id: 3,
          taskId: 'task_1',
          speakerId: 'SPK_01',
          speakerName: '张总',
          startMs: 5600, // 间隔 400ms
          endMs: 8500,
          text: '我们要把端侧模型的性能提升一倍。',
        ),
      ];

      final res = TranscriptContextOptimizer.optimize(segments);

      // SPK_02 应当被双向平滑吸收纠正为张总 (SPK_01)
      expect(res.smoothedSpeakerCount, 1);
      // 并最终无缝合并为一个连贯长句
      expect(res.optimizedCount, 1);
      expect(res.segments.first.speakerId, 'SPK_01');
      expect(res.segments.first.speakerName, '张总');
      expect(
        res.segments.first.text,
        '关于下个阶段的总体战略布局，特别关键的是，我们要把端侧模型的性能提升一倍。',
      );
    });
  });
}
