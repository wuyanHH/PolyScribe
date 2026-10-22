import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/services/export_center_service.dart';

void main() {
  group('ExportCenterService 生产力导出中心测试', () {
    final task = MeetingTask(
      id: 'task_exp',
      title: '产品技术架构评审会',
      sourceType: TaskSourceType.liveMeeting,
      audioPath: '/test/audio.wav',
      durationMs: 6500,
      createdAt: 1700000000000,
      status: TaskStatus.completed,
    );

    final segments = [
      const TranscriptSegment(
        taskId: 'task_exp',
        speakerId: 'SPK_01',
        speakerName: '张总',
        startMs: 500,
        endMs: 2500,
        text: 'PolyScribe 端侧架构设计非常完备。',
      ),
      const TranscriptSegment(
        taskId: 'task_exp',
        speakerId: 'SPK_02',
        speakerName: '李工',
        startMs: 3000,
        endMs: 6000,
        text: '是的，完全满足离线、低内存与高保活标准。',
      ),
    ];

    test('SRT 导出格式与序号、时间戳验证', () {
      final srt = ExportCenterService.formatContent(
        task: task,
        segments: segments,
        format: ExportFormat.srt,
      );

      expect(srt, contains('1\n00:00:00,500 --> 00:00:02,500'));
      expect(srt, contains('[张总]: PolyScribe 端侧架构设计非常完备。'));
      expect(srt, contains('2\n00:00:03,000 --> 00:00:06,000'));
      expect(srt, contains('[李工]: 是的，完全满足离线、低内存与高保活标准。'));
    });

    test('WebVTT 导出格式验证', () {
      final vtt = ExportCenterService.formatContent(
        task: task,
        segments: segments,
        format: ExportFormat.vtt,
      );

      expect(vtt, startsWith('WEBVTT'));
      expect(vtt, contains('00:00:00.500 --> 00:00:02.500'));
      expect(vtt, contains('<v 张总>PolyScribe 端侧架构设计非常完备。'));
    });

    test('Markdown 纪要导出格式验证', () {
      final md = ExportCenterService.formatContent(
        task: task,
        segments: segments,
        format: ExportFormat.markdown,
      );

      expect(md, contains('# 产品技术架构评审会'));
      expect(md, contains('### **[张总]** `[00:00]`'));
      expect(md, contains('PolyScribe 端侧架构设计非常完备。'));
    });

    test('JSON 格式序列化验证', () {
      final json = ExportCenterService.formatContent(
        task: task,
        segments: segments,
        format: ExportFormat.json,
      );

      expect(json, contains('"task_id": "task_exp"'));
      expect(json, contains('"title": "产品技术架构评审会"'));
    });
  });
}
