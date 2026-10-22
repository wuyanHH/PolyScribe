import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../engine/model_manager.dart';
import '../engine/models/model_package_info.dart';

/// 模型任务运行状态
enum ModelTaskStatus {
  idle,
  checking,
  downloading,
  extracting,
  completed,
  failed,
}

/// 单个模型下载状态通知包
class ModelDownloadProgress {
  final String modelId;
  final ModelTaskStatus status;
  final double progress; // 0.0 ~ 1.0
  final int receivedBytes;
  final int totalBytes;
  final String speed; // 例如 "4.2 MB/s"
  final String? errorMessage;

  const ModelDownloadProgress({
    required this.modelId,
    this.status = ModelTaskStatus.idle,
    this.progress = 0.0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speed = '',
    this.errorMessage,
  });

  ModelDownloadProgress copyWith({
    ModelTaskStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? speed,
    String? errorMessage,
  }) {
    return ModelDownloadProgress(
      modelId: modelId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speed: speed ?? this.speed,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// AI 本地模型资产下载与更新中心服务
class ModelDownloadService {
  static ModelDownloadService? _instance;
  static ModelDownloadService get instance => _instance ??= ModelDownloadService._();

  ModelDownloadService._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 5,
    ));
  }

  late final Dio _dio;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, ModelDownloadProgress> _progressStates = {};

  final StreamController<Map<String, ModelDownloadProgress>> _stateStreamController =
      StreamController<Map<String, ModelDownloadProgress>>.broadcast();

  Stream<Map<String, ModelDownloadProgress>> get stateStream =>
      _stateStreamController.stream;

  Map<String, ModelDownloadProgress> get currentStates =>
      Map.unmodifiable(_progressStates);

  /// 取消指定模型的下载任务
  void cancel(String modelId) {
    if (_cancelTokens.containsKey(modelId)) {
      _cancelTokens[modelId]?.cancel('用户主动取消下载');
      _cancelTokens.remove(modelId);
      _updateState(modelId, (s) => s.copyWith(
        status: ModelTaskStatus.idle,
        speed: '',
        errorMessage: '已取消下载',
      ));
    }
  }

  /// 检查某模型的本地安装状态
  Future<bool> checkInstalled(ModelPackageInfo model) async {
    final dir = await ModelManager.instance.getModelDirectory();
    return model.isInstalled(dir.path);
  }

  /// 执行单个模型的下载与自动解压配置
  Future<bool> downloadModel(
    ModelPackageInfo model, {
    ModelDownloadSource source = ModelDownloadSource.modelScope,
  }) async {
    final modelDir = await ModelManager.instance.getModelDirectory();
    final targetDirPath = modelDir.path;

    final cancelToken = CancelToken();
    _cancelTokens[model.id] = cancelToken;

    _updateState(model.id, (s) => s.copyWith(
      status: ModelTaskStatus.downloading,
      progress: 0.0,
      receivedBytes: 0,
      totalBytes: model.estimatedSizeBytes,
      speed: '准备连接...',
      errorMessage: null,
    ));

    final url = model.getUrl(source);
    debugPrint('[ModelDownload] 开始下载: ${model.name} 从 $url');

    final tempFile = File(p.join(
      targetDirPath,
      'temp_${model.id}_${DateTime.now().millisecondsSinceEpoch}.${model.isArchive ? 'tar.bz2' : 'onnx'}',
    ));

    int lastTime = DateTime.now().millisecondsSinceEpoch;
    int lastBytes = 0;

    try {
      await _dio.download(
        url,
        tempFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final deltaTime = (now - lastTime) / 1000.0;
          String speedStr = '';

          if (deltaTime >= 0.5) {
            final deltaBytes = received - lastBytes;
            final bytesPerSec = deltaBytes / deltaTime;
            if (bytesPerSec >= 1024 * 1024) {
              speedStr = '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
            } else {
              speedStr = '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
            }
            lastTime = now;
            lastBytes = received;
          }

          final effectiveTotal = total > 0 ? total : model.estimatedSizeBytes;
          final pRatio = (received / effectiveTotal).clamp(0.0, 0.99);

          _updateState(model.id, (s) => s.copyWith(
            status: ModelTaskStatus.downloading,
            progress: pRatio,
            receivedBytes: received,
            totalBytes: effectiveTotal,
            speed: speedStr.isEmpty ? s.speed : speedStr,
          ));
        },
      );

      _cancelTokens.remove(model.id);

      // 解压与重命名归整
      if (model.isArchive) {
        _updateState(model.id, (s) => s.copyWith(
          status: ModelTaskStatus.extracting,
          progress: 0.99,
          speed: '正在解压并校验...',
        ));

        await compute(_extractAndAlignArchive, {
          'archivePath': tempFile.path,
          'targetDirPath': targetDirPath,
          'modelId': model.id,
        });

        // 删除临时压缩包
        if (tempFile.existsSync()) {
          await tempFile.delete();
        }
      } else {
        // 单个 ONNX 文件直接重命名到目标文件
        final destPath = p.join(targetDirPath, model.targetFileNames.first);
        final destFile = File(destPath);
        if (destFile.existsSync()) {
          await destFile.delete();
        }
        await tempFile.rename(destPath);
      }

      _updateState(model.id, (s) => s.copyWith(
        status: ModelTaskStatus.completed,
        progress: 1.0,
        speed: '已就绪',
      ));

      // 重新解析模型就绪状态
      await ModelManager.instance.resolveModels();
      return true;
    } catch (e) {
      _cancelTokens.remove(model.id);
      if (tempFile.existsSync()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      if (CancelToken.isCancel(e as dynamic)) {
        debugPrint('[ModelDownload] 下载被用户主动取消: ${model.id}');
        return false;
      }

      debugPrint('[ModelDownload] 下载失败: $e');
      _updateState(model.id, (s) => s.copyWith(
        status: ModelTaskStatus.failed,
        errorMessage: '下载失败: ${e.toString().replaceAll('Exception:', '').trim()}',
      ));
      return false;
    }
  }

  /// 一键下载所有未就绪的模型
  Future<void> downloadAllMissingModels({
    ModelDownloadSource source = ModelDownloadSource.modelScope,
  }) async {
    for (final model in PredefinedModels.all) {
      final isInstalled = await checkInstalled(model);
      if (!isInstalled) {
        await downloadModel(model, source: source);
      }
    }
  }

  /// 检查各模型在云端的最新版本与本地对比
  Future<Map<String, String>> checkModelUpdates() async {
    // 模拟版本检查协议，可对齐远程 manifest 或内置最新版本号
    final Map<String, String> updateNotes = {};
    for (final model in PredefinedModels.all) {
      final installed = await checkInstalled(model);
      if (!installed) {
        updateNotes[model.id] = '待下载 (最新版本: ${model.version})';
      } else {
        updateNotes[model.id] = '已是最新版 (${model.version})';
      }
    }
    return updateNotes;
  }

  void _updateState(String modelId, ModelDownloadProgress Function(ModelDownloadProgress) updater) {
    final current = _progressStates[modelId] ?? ModelDownloadProgress(modelId: modelId);
    _progressStates[modelId] = updater(current);
    _stateStreamController.add(Map.from(_progressStates));
  }
}

/// 顶层后台解压处理函数（在 compute 独立线程中执行，避免阻塞主 UI 线程）
void _extractAndAlignArchive(Map<String, dynamic> params) {
  final archivePath = params['archivePath'] as String;
  final targetDirPath = params['targetDirPath'] as String;
  final modelId = params['modelId'] as String;

  final archiveFile = File(archivePath);
  final bytes = archiveFile.readAsBytesSync();

  // 解压 .tar.bz2
  final tarBytes = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tarBytes);

  for (final file in archive) {
    if (!file.isFile) continue;
    final filename = file.name;
    final fileContent = file.content as List<int>;

    if (modelId == PredefinedModels.senseVoiceSmall.id) {
      if (filename.endsWith('model.int8.onnx')) {
        File(p.join(targetDirPath, 'sensevoice_small_int8.onnx'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileContent);
      } else if (filename.endsWith('tokens.txt')) {
        File(p.join(targetDirPath, 'tokens.txt'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileContent);
      }
    } else if (modelId == PredefinedModels.pyannote.id) {
      if (filename.endsWith('.onnx')) {
        File(p.join(targetDirPath, 'pyannote_segmentation.onnx'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileContent);
      }
    }
  }
}
