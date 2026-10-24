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
      expect(res.segments.first.text, '今天我们主要讨论一下关于这个新版本的架构设计方案。');
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
      expect(res.segments.first.text, '然后我们来看具体的实现代码。');
    });
  });
}
