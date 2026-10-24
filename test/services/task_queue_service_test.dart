import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/database/app_database.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/engine/audio/wav_codec.dart';
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

  test('TaskQueueService 异常容错测试 (模型未就绪或损坏时数据库正确落库 TaskStatus.error)', () async {
    // 清除 mock，触发无模型或损坏文件时的真实异常分支
    TaskQueueService.instance.mockTranscriber = null;

    final audioFile = File('${tempDir.path}/sample_error.wav');
    await audioFile.writeAsBytes(List<int>.filled(2000, 100));

    final task = await TaskQueueService.instance.enqueueAudioFile(
      audioFile.path,
      customTitle: '异常测试录音',
    );

    // 轮询等待异步队列捕获异常并持久化
    MeetingTask? savedTask;
    for (int i = 0; i < 25; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
      savedTask = await AppDatabase.instance.getTask(task.id);
      if (savedTask?.status == TaskStatus.error) break;
    }

    expect(savedTask, isNotNull);
    // 验证数据库状态更新为 error 而非永久卡死在 queued
    expect(savedTask!.status, TaskStatus.error);
  });

  test('TaskQueueService 断点续转测试 (resumeTask 应保留旧段落并追加新段落)', () async {
    final audioFile = File('${tempDir.path}/sample_resume.wav');
    final dummyWav = WavCodec.encodeMono16BitWavBytes(
      Float32List(16000 * 4), // 4 秒
      sampleRate: 16000,
    );
    await audioFile.writeAsBytes(dummyWav);

    // 模拟首次转录中断：预置两个已转写段落
    final task = MeetingTask(
      id: 'task_resume_test_${DateTime.now().microsecondsSinceEpoch}',
      title: '断点续转测试录音',
      sourceType: TaskSourceType.importedAudio,
      audioPath: audioFile.path,
      durationMs: 4000,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.error,
    );
    await AppDatabase.instance.saveTask(task);

    await AppDatabase.instance.insertSegment(TranscriptSegment(
      taskId: task.id,
      speakerId: 'SPK_01',
      startMs: 0,
      endMs: 1500,
      text: '第一句已完成内容',
    ));
    await AppDatabase.instance.insertSegment(TranscriptSegment(
      taskId: task.id,
      speakerId: 'SPK_01',
      startMs: 1600,
      endMs: 2500,
      text: '第二句已完成内容',
    ));

    // 注入模拟续转器：追加第三句
    TaskQueueService.instance.mockTranscriber = (t, isStereo) async {
      return [
        TranscriptSegment(
          taskId: t.id,
          speakerId: 'SPK_02',
          startMs: 2600,
          endMs: 3800,
          text: '第三句断点续转内容',
        ),
      ];
    };

    // 触发断点续转
    await TaskQueueService.instance.resumeTask(task.id);

    // 轮询等待任务完成
    MeetingTask? doneTask;
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      doneTask = await AppDatabase.instance.getTask(task.id);
      if (doneTask?.status == TaskStatus.completed) break;
    }

    expect(doneTask, isNotNull);
    expect(doneTask!.status, TaskStatus.completed);

    // 验证段落不仅没有被冲掉，反而成功保留了前两句，并追加了第三句
    final segs = await AppDatabase.instance.getSegmentsForTask(task.id);
    expect(segs.length, 3);
    expect(segs[0].text, '第一句已完成内容');
    expect(segs[1].text, '第二句已完成内容');
    expect(segs[2].text, '第三句断点续转内容');
  });

  test('TaskQueueService 暂停与恢复转写测试 (pauseTask 与 resumeTask)', () async {
    final audioFile = File('${tempDir.path}/sample_pause_resume.wav');
    final dummyWav = WavCodec.encodeMono16BitWavBytes(
      Float32List(16000 * 2),
      sampleRate: 16000,
    );
    await audioFile.writeAsBytes(dummyWav);

    final task = MeetingTask(
      id: 'task_pause_${DateTime.now().microsecondsSinceEpoch}',
      title: '暂停恢复测试录音',
      sourceType: TaskSourceType.importedAudio,
      audioPath: audioFile.path,
      durationMs: 2000,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.queued,
    );
    await AppDatabase.instance.saveTask(task);

    // 1. 测试暂停
    await TaskQueueService.instance.pauseTask(task.id);
    final pausedTask = await AppDatabase.instance.getTask(task.id);
    expect(pausedTask?.status, TaskStatus.paused);

    // 2. 测试恢复
    TaskQueueService.instance.mockTranscriber = (t, isStereo) async {
      return [
        TranscriptSegment(
          taskId: t.id,
          speakerId: 'SPK_01',
          startMs: 0,
          endMs: 1800,
          text: '暂停后恢复转写成功',
        ),
      ];
    };

    await TaskQueueService.instance.resumeTask(task.id);

    MeetingTask? resumedDoneTask;
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      resumedDoneTask = await AppDatabase.instance.getTask(task.id);
      if (resumedDoneTask?.status == TaskStatus.completed) break;
    }

    expect(resumedDoneTask, isNotNull);
    expect(resumedDoneTask!.status, TaskStatus.completed);
    final segs = await AppDatabase.instance.getSegmentsForTask(task.id);
    expect(segs.length, 1);
    expect(segs.first.text, '暂停后恢复转写成功');
  });

  test('TaskQueueService 删除正在执行的任务自动流转下一个测试 (cancelOrDeleteTask 防卡死调度)', () async {
    final audioFile1 = File('${tempDir.path}/sample_queue_del1.wav');
    final audioFile2 = File('${tempDir.path}/sample_queue_del2.wav');
    final dummyWav = WavCodec.encodeMono16BitWavBytes(Float32List(16000 * 2), sampleRate: 16000);
    await audioFile1.writeAsBytes(dummyWav);
    await audioFile2.writeAsBytes(dummyWav);

    // 模拟第一个任务耗时较长（模拟卡住或慢速识别），第二个任务正常
    TaskQueueService.instance.mockTranscriber = (t, isStereo) async {
      if (t.audioPath.contains('del1')) {
        // 等待较久
        await Future.delayed(const Duration(milliseconds: 800));
        return [];
      }
      return [
        TranscriptSegment(
          taskId: t.id,
          speakerId: 'SPK_02',
          startMs: 0,
          endMs: 1500,
          text: '队列自动流转执行成功',
        ),
      ];
    };

    final task1 = await TaskQueueService.instance.enqueueAudioFile(audioFile1.path, customTitle: '卡住任务1');
    final task2 = await TaskQueueService.instance.enqueueAudioFile(audioFile2.path, customTitle: '后置任务2');

    // 稍作等待让 task1 开始执行
    await Future.delayed(const Duration(milliseconds: 100));

    // 删除正在执行的卡住任务 task1
    await TaskQueueService.instance.cancelOrDeleteTask(task1.id);

    // 验证 task1 已从数据库中删除
    final deletedTask1 = await AppDatabase.instance.getTask(task1.id);
    expect(deletedTask1, isNull);

    // 轮询等待 task2 是否能自动被流转调度并完成！
    MeetingTask? doneTask2;
    for (int i = 0; i < 25; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
      doneTask2 = await AppDatabase.instance.getTask(task2.id);
      if (doneTask2?.status == TaskStatus.completed) break;
    }

    expect(doneTask2, isNotNull);
    expect(doneTask2!.status, TaskStatus.completed);

    final segs2 = await AppDatabase.instance.getSegmentsForTask(task2.id);
    expect(segs2, isNotEmpty);
    expect(segs2.first.text, '队列自动流转执行成功');
  });
}
