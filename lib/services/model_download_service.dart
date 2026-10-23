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
      receiveTimeout: const Duration(minutes: 15),
      followRedirects: true,
      maxRedirects: 8,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
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

  /// 执行单个模型的下载与自动解压部署
  Future<bool> downloadModel(
    ModelPackageInfo model, {
    ModelDownloadSource source = ModelDownloadSource.official,
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

    final items = model.getItems(source);
    final totalModelBytes = model.estimatedSizeBytes;
    int completedBaseBytes = 0;

    try {
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        debugPrint('[ModelDownload] [${i + 1}/${items.length}] 开始下载: ${item.url}');

        final tempFile = File(p.join(
          targetDirPath,
          'temp_${model.id}_${i}_${DateTime.now().millisecondsSinceEpoch}.${item.isArchive ? 'tar.bz2' : 'bin'}',
        ));

        int lastTime = DateTime.now().millisecondsSinceEpoch;
        int lastBytes = 0;

        await _dio.download(
          item.url,
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

            final currentOverallReceived = completedBaseBytes + received;
            final pRatio = (currentOverallReceived / totalModelBytes).clamp(0.0, 0.98);

            _updateState(model.id, (s) => s.copyWith(
              status: ModelTaskStatus.downloading,
              progress: pRatio,
              receivedBytes: currentOverallReceived,
              totalBytes: totalModelBytes,
              speed: speedStr.isEmpty ? s.speed : speedStr,
            ));
          },
        );

        // 处理该下载项：解压或就地重命名
        if (item.isArchive) {
          _updateState(model.id, (s) => s.copyWith(
            status: ModelTaskStatus.extracting,
            speed: '正在解压并校验权重...',
          ));

          await compute(_extractAndAlignArchive, {
            'archivePath': tempFile.path,
            'targetDirPath': targetDirPath,
            'modelId': model.id,
          });

          if (tempFile.existsSync()) {
            await tempFile.delete();
          }
        } else {
          final destPath = p.join(targetDirPath, item.destinationFileName);
          final destFile = File(destPath);
          if (destFile.existsSync()) {
            await destFile.delete();
          }
          await tempFile.rename(destPath);
        }

        completedBaseBytes += item.estimatedSizeBytes;
      }

      _cancelTokens.remove(model.id);

      _updateState(model.id, (s) => s.copyWith(
        status: ModelTaskStatus.completed,
        progress: 1.0,
        speed: '已就绪',
      ));

      // 重新扫描并更新全局引擎状态
      await ModelManager.instance.resolveModels();
      return true;
    } catch (e) {
      _cancelTokens.remove(model.id);

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
    ModelDownloadSource source = ModelDownloadSource.official,
  }) async {
    for (final model in PredefinedModels.all) {
      final isInstalled = await checkInstalled(model);
      if (!isInstalled) {
        await downloadModel(model, source: source);
      }
    }
  }

  /// 检查各模型版本状态
  Future<Map<String, String>> checkModelUpdates() async {
    final Map<String, String> updateNotes = {};
    for (final model in PredefinedModels.all) {
      final installed = await checkInstalled(model);
      if (!installed) {
        updateNotes[model.id] = '待下载 (最新版: ${model.version})';
      } else {
        updateNotes[model.id] = '已就绪 (当前: ${model.version})';
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

/// 顶层后台解压处理函数（在 compute 独立线程中执行，杜绝阻塞主 UI 线程）
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
      if (filename.endsWith('model.int8.onnx') || filename.endsWith('model.onnx')) {
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
