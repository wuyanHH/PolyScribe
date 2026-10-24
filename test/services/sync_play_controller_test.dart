import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/services/sync_play_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (MethodCall methodCall) async => 1,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (MethodCall methodCall) async => 1,
    );
  });

  group('SyncPlayController 单元测试', () {
    test('updateSpeakerName 纯内存零延迟乐观更新发言人姓名', () {
      final controller = SyncPlayController();
      final initialSegments = [
        const TranscriptSegment(
          id: 1,
          taskId: 't1',
          speakerId: 'SPK_01',
          speakerName: '发言人 1',
          startMs: 0,
          endMs: 2000,
          text: '第一句',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 't1',
          speakerId: 'SPK_01',
          speakerName: '发言人 1',
          startMs: 2200,
          endMs: 4000,
          text: '第二句',
        ),
        const TranscriptSegment(
          id: 3,
          taskId: 't1',
          speakerId: 'SPK_02',
          speakerName: '发言人 2',
          startMs: 4200,
          endMs: 6000,
          text: '第三句',
        ),
      ];

      controller.loadTask(audioPath: '', segments: initialSegments);

      bool notified = false;
      controller.addListener(() {
        notified = true;
      });

      // 执行无延迟改名
      controller.updateSpeakerName('SPK_01', '张总');

      expect(notified, isTrue);
      expect(controller.segments[0].speakerName, '张总');
      expect(controller.segments[1].speakerName, '张总');
      expect(controller.segments[2].speakerName, '发言人 2'); // 未受影响

      controller.dispose();
    });

    test('updateSegments 纯内存替换优化后的段落列表', () {
      final controller = SyncPlayController();
      final initialSegments = [
        const TranscriptSegment(
          id: 1,
          taskId: 't1',
          speakerId: 'SPK_01',
          startMs: 0,
          endMs: 2000,
          text: '第一句',
        ),
        const TranscriptSegment(
          id: 2,
          taskId: 't1',
          speakerId: 'SPK_01',
          startMs: 2100,
          endMs: 4000,
          text: '第二句',
        ),
      ];

      controller.loadTask(audioPath: '', segments: initialSegments);

      // 上下文优化合并为一句
      final mergedSegments = [
        const TranscriptSegment(
          id: 1,
          taskId: 't1',
          speakerId: 'SPK_01',
          startMs: 0,
          endMs: 4000,
          text: '第一句第二句',
        ),
      ];

      controller.updateSegments(mergedSegments);

      expect(controller.segments.length, 1);
      expect(controller.segments.first.text, '第一句第二句');
      expect(controller.segments.first.endMs, 4000);

      controller.dispose();
    });
  });
}
