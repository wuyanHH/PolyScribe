import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/database/app_database.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
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
    await AppDatabase.instance.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('TaskQueueService 导入批处理排队与落库测试', () async {
    final audioFile = File('${tempDir.path}/sample_call.wav');

    // 写入模拟 PCM 样本数据
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
}
