import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/database/app_database.dart';

/// 资产迁移统计与报告信息
class StorageMigrationStats {
  final int modelFilesCount;
  final int modelBytes;
  final int audioFilesCount;
  final int audioBytes;
  final int recordingFilesCount;
  final int recordingBytes;

  const StorageMigrationStats({
    required this.modelFilesCount,
    required this.modelBytes,
    required this.audioFilesCount,
    required this.audioBytes,
    required this.recordingFilesCount,
    required this.recordingBytes,
  });

  int get totalFiles => modelFilesCount + audioFilesCount + recordingFilesCount;
  int get totalBytes => modelBytes + audioBytes + recordingBytes;

  String get totalSizeDisplay => formatBytes(totalBytes);
  String get modelSizeDisplay => formatBytes(modelBytes);
  String get audioSizeDisplay => formatBytes(audioBytes + recordingBytes);

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 全局外部存储目录设定与资产安全迁移服务
class AppStorageService {
  static AppStorageService? _instance;
  static AppStorageService get instance => _instance ??= AppStorageService._();

  AppStorageService._();

  static const String _prefCustomDirKey = 'app_custom_storage_directory';

  String? _customStoragePath;

  /// 当前是否已启用自定义外部存储目录
  bool get isCustomDirActive => _customStoragePath != null && _customStoragePath!.isNotEmpty;

  /// 当前自定义外部存储物理路径 (为 null 时代表使用系统默认路径)
  String? get customStoragePath => _customStoragePath;

  /// 初始化服务并从本地偏好加载已保存的存储路径
  Future<void> init() async {
    try {
      final savedPath = await AppDatabase.instance.getSetting(_prefCustomDirKey);
      if (savedPath != null && savedPath.trim().isNotEmpty) {
        final dir = Directory(savedPath.trim());
        if (dir.existsSync()) {
          _customStoragePath = dir.path;
          debugPrint('[AppStorageService] 已挂载自定义外部存储目录: $_customStoragePath');
        } else {
          debugPrint('[AppStorageService] 原设定的外部目录不存在或已离线，降级使用默认路径: $savedPath');
        }
      }
    } catch (e) {
      debugPrint('[AppStorageService] 读取存储偏好失败: $e');
    }
  }

  /// 获取系统默认的应用支持基础目录
  Future<Directory> getDefaultBaseDirectory() async {
    return await getApplicationSupportDirectory();
  }

  /// 获取当前生效的基准数据存储目录 (优先使用已通过验证的自定义外部目录)
  Future<Directory> getActiveBaseDirectory() async {
    if (isCustomDirActive) {
      final dir = Directory(_customStoragePath!);
      if (!dir.existsSync()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      if (dir.existsSync()) {
        return dir;
      }
    }
    return await getDefaultBaseDirectory();
  }

  /// 获取核心 AI 推理模型存放目录 (优先外部目录中的 models/ 子目录)
  Future<Directory> getModelsDirectory() async {
    final baseDir = await getActiveBaseDirectory();
    final modelDir = Directory(p.join(baseDir.path, 'models'));
    if (!modelDir.existsSync()) {
      await modelDir.create(recursive: true);
    }
    return modelDir;
  }

  /// 获取转入与标准化音频媒体存储目录
  Future<Directory> getAudiosDirectory() async {
    final baseDir = await getActiveBaseDirectory();
    final audioDir = Directory(p.join(baseDir.path, 'imported_audios'));
    if (!audioDir.existsSync()) {
      await audioDir.create(recursive: true);
    }
    return audioDir;
  }

  /// 获取实时会议现场录音媒体目录
  Future<Directory> getRecordingsDirectory({String? taskId}) async {
    final baseDir = await getActiveBaseDirectory();
    final recordingsDir = taskId != null && taskId.isNotEmpty
        ? Directory(p.join(baseDir.path, 'recordings', taskId))
        : Directory(p.join(baseDir.path, 'recordings'));
    if (!recordingsDir.existsSync()) {
      await recordingsDir.create(recursive: true);
    }
    return recordingsDir;
  }

  /// 扫描当前正在使用的资产总容量与文件数量
  Future<StorageMigrationStats> inspectCurrentAssets() async {
    final activeBase = await getActiveBaseDirectory();
    final modelDir = Directory(p.join(activeBase.path, 'models'));
    final audioDir = Directory(p.join(activeBase.path, 'imported_audios'));
    final recDir = Directory(p.join(activeBase.path, 'recordings'));

    final modelStats = await _scanDirectory(modelDir);
    final audioStats = await _scanDirectory(audioDir);
    final recStats = await _scanDirectory(recDir);

    return StorageMigrationStats(
      modelFilesCount: modelStats.$1,
      modelBytes: modelStats.$2,
      audioFilesCount: audioStats.$1,
      audioBytes: audioStats.$2,
      recordingFilesCount: recStats.$1,
      recordingBytes: recStats.$2,
    );
  }

  /// 扫描任意目录的文件数与总字节数
  Future<(int count, int bytes)> _scanDirectory(Directory dir) async {
    if (!dir.existsSync()) return (0, 0);
    int count = 0;
    int bytes = 0;
    try {
      final list = dir.listSync(recursive: true, followLinks: false);
      for (final entity in list) {
        if (entity is File) {
          count++;
          bytes += entity.lengthSync();
        }
      }
    } catch (e) {
      debugPrint('[AppStorageService] 扫描目录异常: $e');
    }
    return (count, bytes);
  }

  /// 将已下载的模型、转入的音频和现场录音安全迁移至指定的外部目录
  /// 
  /// [targetDirPath]: 目标外部物理目录
  /// [deleteSourceFiles]: 迁移成功且校验完整后，是否清理原目录下的物理文件以释放空间
  /// [onProgress]: 迁移进度回调 (0.0 ~ 1.0, 状态提示文本)
  Future<bool> migrateAssetsTo({
    required String targetDirPath,
    bool deleteSourceFiles = false,
    void Function(double progress, String status)? onProgress,
  }) async {
    final targetDir = Directory(targetDirPath);
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }

    final currentBase = await getActiveBaseDirectory();
    if (p.canonicalize(currentBase.path) == p.canonicalize(targetDir.path)) {
      onProgress?.call(1.0, '目标目录与当前目录相同，无需迁移');
      return true;
    }

    final oldModelDir = Directory(p.join(currentBase.path, 'models'));
    final oldAudioDir = Directory(p.join(currentBase.path, 'imported_audios'));
    final oldRecDir = Directory(p.join(currentBase.path, 'recordings'));

    final newModelDir = Directory(p.join(targetDir.path, 'models'));
    final newAudioDir = Directory(p.join(targetDir.path, 'imported_audios'));
    final newRecDir = Directory(p.join(targetDir.path, 'recordings'));

    await newModelDir.create(recursive: true);
    await newAudioDir.create(recursive: true);
    await newRecDir.create(recursive: true);

    // 1. 迁移 AI 模型资产
    onProgress?.call(0.1, '正在迁移 AI 模型资产...');
    await _copyDirectoryContents(oldModelDir, newModelDir, deleteSource: deleteSourceFiles);

    // 2. 迁移导入音频资产
    onProgress?.call(0.4, '正在迁移转入音频文件...');
    await _copyDirectoryContents(oldAudioDir, newAudioDir, deleteSource: deleteSourceFiles);

    // 3. 迁移现场会议录音
    onProgress?.call(0.7, '正在迁移录音母带与分片...');
    await _copyDirectoryContents(oldRecDir, newRecDir, deleteSource: deleteSourceFiles);

    // 4. 重建数据库中的音频绝对路径映射 (将旧路径前缀无缝修正为新路径前缀)
    onProgress?.call(0.85, '正在更新纪要库音频索引映射...');
    await _relinkDatabaseAudioPaths(
      oldPrefix: currentBase.path,
      newPrefix: targetDir.path,
    );

    // 5. 持久化新目录配置到 SQLite 设置表
    await AppDatabase.instance.saveSetting(_prefCustomDirKey, targetDir.path);
    _customStoragePath = targetDir.path;

    onProgress?.call(1.0, '外部存储设定成功，资产全量迁移完毕');
    return true;
  }

  /// 恢复使用系统默认存储目录 (可选择是否把文件迁回)
  Future<bool> resetToDefaultDirectory({
    bool migrateBack = true,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (!isCustomDirActive) return true;

    final defaultBase = await getDefaultBaseDirectory();
    if (migrateBack) {
      await migrateAssetsTo(
        targetDirPath: defaultBase.path,
        deleteSourceFiles: true,
        onProgress: onProgress,
      );
    }

    await AppDatabase.instance.saveSetting(_prefCustomDirKey, '');
    _customStoragePath = null;
    return true;
  }

  /// 递归复制目录内容，并支持原子替换校验
  Future<void> _copyDirectoryContents(Directory src, Directory dst, {bool deleteSource = false}) async {
    if (!src.existsSync()) return;

    final entities = src.listSync(recursive: true, followLinks: false);
    for (final entity in entities) {
      final relative = p.relative(entity.path, from: src.path);
      final destPath = p.join(dst.path, relative);

      if (entity is Directory) {
        final d = Directory(destPath);
        if (!d.existsSync()) d.createSync(recursive: true);
      } else if (entity is File) {
        final destFile = File(destPath);
        if (!destFile.parent.existsSync()) {
          destFile.parent.createSync(recursive: true);
        }
        // 若目标文件不存在或大小不一致，则进行复制
        if (!destFile.existsSync() || destFile.lengthSync() != entity.lengthSync()) {
          await entity.copy(destPath);
        }
        if (deleteSource) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  /// 更新数据库中存储的已转入音频绝对路径
  Future<void> _relinkDatabaseAudioPaths({required String oldPrefix, required String newPrefix}) async {
    try {
      final tasks = await AppDatabase.instance.getAllTasks();
      for (final t in tasks) {
        if (t.audioPath.isNotEmpty) {
          final pathStr = t.audioPath;
          if (p.isWithin(oldPrefix, pathStr) || pathStr.startsWith(oldPrefix)) {
            final rel = p.relative(pathStr, from: oldPrefix);
            final updatedPath = p.join(newPrefix, rel);
            final updatedTask = t.copyWith(audioPath: updatedPath);
            await AppDatabase.instance.saveTask(updatedTask);
          }
        }
      }
    } catch (e) {
      debugPrint('[AppStorageService] 更新数据库音频路径映射异常: $e');
    }
  }
}
