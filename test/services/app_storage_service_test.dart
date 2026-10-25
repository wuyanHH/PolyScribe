import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:polyscribe/data/database/app_database.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/services/app_storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempBaseDir;
  late Directory tempTargetDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempBaseDir = Directory.systemTemp.createTempSync('polyscribe_storage_test_');
    tempTargetDir = Directory.systemTemp.createTempSync('polyscribe_target_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return tempBaseDir.path;
      },
    );
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    try {
      tempBaseDir.deleteSync(recursive: true);
      tempTargetDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('StorageMigrationStats 容量格式化逻辑验证', () {
    const stats = StorageMigrationStats(
      modelFilesCount: 2,
      modelBytes: 250 * 1024 * 1024, // 250 MB
      audioFilesCount: 3,
      audioBytes: 50 * 1024 * 1024,  // 50 MB
      recordingFilesCount: 1,
      recordingBytes: 10 * 1024 * 1024, // 10 MB
    );

    expect(stats.totalFiles, 6);
    expect(stats.totalBytes, 310 * 1024 * 1024);
    expect(stats.modelSizeDisplay.contains('250.00 MB'), isTrue);
    expect(stats.audioSizeDisplay.contains('60.00 MB'), isTrue);
    expect(stats.totalSizeDisplay.contains('310.00 MB'), isTrue);
  });

  test('AppStorageService 初始默认状态与目录解析测试', () async {
    final service = AppStorageService.instance;
    await service.init();

    expect(service.isCustomDirActive, isFalse);
    expect(service.customStoragePath, isNull);

    final defaultBase = await service.getDefaultBaseDirectory();
    expect(defaultBase.path, tempBaseDir.path);

    final modelDir = await service.getModelsDirectory();
    expect(modelDir.path, p.join(tempBaseDir.path, 'models'));
    expect(modelDir.existsSync(), isTrue);

    final audioDir = await service.getAudiosDirectory();
    expect(audioDir.path, p.join(tempBaseDir.path, 'imported_audios'));
    expect(audioDir.existsSync(), isTrue);
  });

  test('AppStorageService migrateAssetsTo 资产安全迁移与数据库路径重联测试', () async {
    final service = AppStorageService.instance;
    await service.init();

    // 1. 在原默认目录中放置伪造的模型文件与音频文件
    final oldModelDir = await service.getModelsDirectory();
    final fakeModelFile = File(p.join(oldModelDir.path, 'sensevoice_small_int8.onnx'));
    await fakeModelFile.writeAsString('FAKE_ONNX_MODEL_CONTENT');

    final oldAudioDir = await service.getAudiosDirectory();
    final fakeAudioFile = File(p.join(oldAudioDir.path, 'task_999_sample.wav'));
    await fakeAudioFile.writeAsString('RIFF_FAKE_WAV');

    // 2. 存入一条关联原音频路径的 MeetingTask
    final testTask = MeetingTask(
      id: 'task_999',
      title: '外部存储迁移测试会议',
      sourceType: TaskSourceType.importedAudio,
      audioPath: fakeAudioFile.path,
      durationMs: 12000,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: TaskStatus.completed,
    );
    await AppDatabase.instance.saveTask(testTask);

    // 3. 执行资产迁移到 targetDir
    final success = await service.migrateAssetsTo(
      targetDirPath: tempTargetDir.path,
      deleteSourceFiles: true,
    );
    expect(success, isTrue);
    expect(service.isCustomDirActive, isTrue);
    expect(service.customStoragePath, tempTargetDir.path);

    // 4. 验证新目录下文件是否存在
    final newModelFile = File(p.join(tempTargetDir.path, 'models', 'sensevoice_small_int8.onnx'));
    expect(newModelFile.existsSync(), isTrue);
    expect(await newModelFile.readAsString(), 'FAKE_ONNX_MODEL_CONTENT');

    final newAudioFile = File(p.join(tempTargetDir.path, 'imported_audios', 'task_999_sample.wav'));
    expect(newAudioFile.existsSync(), isTrue);

    // 5. 验证数据库中 Task 的 audioPath 自动更新为新路径
    final updatedTask = await AppDatabase.instance.getTask('task_999');
    expect(updatedTask, isNotNull);
    expect(updatedTask!.audioPath, newAudioFile.path);
  });
}
