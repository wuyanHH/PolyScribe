import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/database/app_database.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/services/task_queue_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('polyscribe_doc_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return tempDir.path;
      },
    );
  });

  tearDownAll(() async {
    TaskQueueService.instance.mockTranscriber = null;
    await AppDatabase.instance.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('TaskQueueService 导入批处理排队与转写落库测试 (模拟转写器注入)', () async {
    // 注入模拟转写结果
    TaskQueueService.instance.mockTranscriber = (task, isStereo) async {
      return [
        TranscriptSegment(
          taskId: task.id,
          speakerId: 'SPK_01',
          speakerName: '主讲人',
          startMs: 0,
          endMs: 3000,
          text: '端侧模型离线运行测试正常，支持实时聚类。',
        ),
      ];
    };

    final audioFile = File('${tempDir.path}/sample_call.wav');
    await audioFile.writeAsBytes(List<int>.filled(2000, 100));

    // 入队执行
    final task = await TaskQueueService.instance.enqueueAudioFile(
      audioFile.path,
      customTitle: '测试通话录音',
    );

    expect(task.id, startsWith('task_'));
    expect(task.title, '测试通话录音');

    // 等待异步队列调度执行完成
    await Future.delayed(const Duration(milliseconds: 600));

    final savedTask = await AppDatabase.instance.getTask(task.id);
    expect(savedTask, isNotNull);
    expect(savedTask!.status, TaskStatus.completed);

    // 验证段落已生成
    final segs = await AppDatabase.instance.getSegmentsForTask(task.id);
    expect(segs, isNotEmpty);

    // 验证全文检索 (搜索单声道生成的文本 '端侧模型')
    final searchHits = await AppDatabase.instance.searchSegments('端侧模型');
    expect(searchHits, isNotEmpty);
  });

  test('TaskQueueService 异常容错测试 (模型未就绪时数据库正确落库 TaskStatus.error)', () async {
    // 清除 mock，触发无模型时的真实异常分支
    TaskQueueService.instance.mockTranscriber = null;

    final audioFile = File('${tempDir.path}/sample_error.wav');
    await audioFile.writeAsBytes(List<int>.filled(2000, 100));

    final task = await TaskQueueService.instance.enqueueAudioFile(
      audioFile.path,
      customTitle: '异常测试录音',
    );

    // 等待异步队列捕获异常并持久化
    await Future.delayed(const Duration(milliseconds: 600));

    final savedTask = await AppDatabase.instance.getTask(task.id);
    expect(savedTask, isNotNull);
    // 验证数据库状态更新为 error 而非永久卡死在 queued
    expect(savedTask!.status, TaskStatus.error);
  });
}
