import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
      connectTimeout: const Duration(seconds: 40),
      receiveTimeout: const Duration(minutes: 25),
      sendTimeout: const Duration(seconds: 40),
      followRedirects: true,
      maxRedirects: 10,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ));

    // 配置原生 HTTP 适配器，处理移动端 VPN/代理环境下的自签证书与握手中断 (Handshake terminated)
    final adapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 允许任何证书，防止在 Android 开启代理/VPN 工具或中间人探测时握手直接被 Reset
        client.badCertificateCallback = (cert, host, port) => true;
        client.connectionTimeout = const Duration(seconds: 40);
        client.idleTimeout = const Duration(seconds: 40);
        return client;
      },
    );
    _dio.httpClientAdapter = adapter;
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

  /// 彻底干净卸载指定模型资产 (沙盒化目录一键完整清理，绝不残留孤儿权重)
  Future<bool> deleteModel(ModelPackageInfo model) async {
    try {
      cancel(model.id);
      final modelDir = await ModelManager.instance.getModelDirectory();
      final sandbox = Directory(model.getSandboxPath(modelDir.path));
      if (sandbox.existsSync()) {
        await sandbox.delete(recursive: true);
        debugPrint('[ModelDownload] 模型沙盒目录已删除: ${sandbox.path}');
      }
      // 顺带清理可能存在于根目录下的老版本平铺孤儿文件
      for (final fn in model.targetFileNames) {
        final oldFile = File(p.join(modelDir.path, fn));
        if (oldFile.existsSync()) {
          await oldFile.delete();
        }
      }
      await ModelManager.instance.resolveModels();
      _updateState(model.id, (_) => ModelDownloadProgress(modelId: model.id));
      return true;
    } catch (e) {
      debugPrint('[ModelDownload] 清理模型目录失败: $e');
      return false;
    }
  }

  /// 执行单个模型的下载与自动解压部署 (支持子目录沙盒隔离、自动多源故障回退与网络自愈)
  Future<bool> downloadModel(
    ModelPackageInfo model, {
    ModelDownloadSource source = ModelDownloadSource.modelScope,
    bool allowFallback = true,
  }) async {
    final modelDir = await ModelManager.instance.getModelDirectory();
    final targetDirPath = modelDir.path;
    final sandboxDirPath = model.getSandboxPath(targetDirPath);
    final sandboxDir = Directory(sandboxDirPath);
    if (!sandboxDir.existsSync()) {
      await sandboxDir.create(recursive: true);
    }

    final cancelToken = CancelToken();
    _cancelTokens[model.id] = cancelToken;

    _updateState(model.id, (s) => s.copyWith(
      status: ModelTaskStatus.downloading,
      progress: 0.0,
      receivedBytes: 0,
      totalBytes: model.estimatedSizeBytes,
      speed: '准备连接 [${source.badge}]...',
      errorMessage: null,
    ));

    final items = model.getItems(source);
    final totalModelBytes = model.estimatedSizeBytes;
    int completedBaseBytes = 0;

    try {
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        debugPrint('[ModelDownload] [${i + 1}/${items.length}] 开始下载 ($source): ${item.url}');

        final tempFile = File(p.join(
          sandboxDirPath,
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

        // 处理该下载项：解压或就地重命名至沙盒目录
        if (item.isArchive) {
          _updateState(model.id, (s) => s.copyWith(
            status: ModelTaskStatus.extracting,
            speed: '正在解压并校验权重...',
          ));

          await compute(_extractAndAlignArchive, {
            'archivePath': tempFile.path,
            'targetDirPath': targetDirPath,
            'sandboxDirPath': sandboxDirPath,
            'modelId': model.id,
          });

          if (tempFile.existsSync()) {
            await tempFile.delete();
          }
        } else {
          final destPath = p.join(sandboxDirPath, item.destinationFileName);
          final destFile = File(destPath);
          if (destFile.existsSync()) {
            await destFile.delete();
          }
          await tempFile.rename(destPath);

          // 保持老路径平滑兼容（若需要在根目录下建立软引用/拷贝）
          final rootDest = p.join(targetDirPath, item.destinationFileName);
          if (!File(rootDest).existsSync()) {
            try {
              await File(destPath).copy(rootDest);
            } catch (_) {}
          }
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

      final errorStr = e.toString();
      debugPrint('[ModelDownload] 下载失败: $errorStr');

      // 自动故障转移：若当前源发生网络/握手阻断，且允许回退，自动换源重试
      if (allowFallback) {
        final fallbackSource = source == ModelDownloadSource.official
            ? ModelDownloadSource.modelScope
            : ModelDownloadSource.official;

        debugPrint('[ModelDownload] 触发自动换源回退机制 -> 正在尝试使用备用源: $fallbackSource');
        _updateState(model.id, (s) => s.copyWith(
          speed: '网络握手受阻，自动切换至备用高速源...',
        ));

        // 延迟 800ms 后自动执行备用源下载
        await Future.delayed(const Duration(milliseconds: 800));
        return downloadModel(model, source: fallbackSource, allowFallback: false);
      }

      String friendlyMsg = errorStr.replaceAll('Exception:', '').trim();
      if (errorStr.contains('Handshake') || errorStr.contains('handshake')) {
        friendlyMsg = 'TLS握手中断 (可能受VPN或网络代理拦截)，建议切换高速镜像源重试';
      } else if (errorStr.contains('timed out') || errorStr.contains('Timeout')) {
        friendlyMsg = '网络连接超时，请检查手机网络或切换下载加速源';
      }

      _updateState(model.id, (s) => s.copyWith(
        status: ModelTaskStatus.failed,
        errorMessage: '下载失败: $friendlyMsg',
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
  final sandboxDirPath = (params['sandboxDirPath'] as String?) ?? targetDirPath;
  final modelId = params['modelId'] as String;

  final archiveFile = File(archivePath);
  final bytes = archiveFile.readAsBytesSync();

  // 解压 .tar.bz2
  final tarBytes = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tarBytes);

  void saveBoth(String relativeName, List<int> content) {
    // 写入专属沙盒子目录
    File(p.join(sandboxDirPath, relativeName))
      ..createSync(recursive: true)
      ..writeAsBytesSync(content);
    // 写入根目录平铺位置 (兼容老版本)
    if (sandboxDirPath != targetDirPath) {
      File(p.join(targetDirPath, relativeName))
        ..createSync(recursive: true)
        ..writeAsBytesSync(content);
    }
  }

  for (final file in archive) {
    if (!file.isFile) continue;
    final filename = file.name;
    final fileContent = file.content as List<int>;

    if (modelId == PredefinedModels.senseVoiceSmall.id) {
      if (filename.endsWith('model.int8.onnx') || filename.endsWith('model.onnx')) {
        saveBoth('sensevoice_small_int8.onnx', fileContent);
      } else if (filename.endsWith('tokens.txt')) {
        saveBoth('tokens.txt', fileContent);
      }
    } else if (modelId == PredefinedModels.paraformerZh.id) {
      if (filename.endsWith('model.int8.onnx') || filename.endsWith('model.onnx')) {
        saveBoth('paraformer_model.int8.onnx', fileContent);
      } else if (filename.endsWith('tokens.txt')) {
        saveBoth('paraformer_tokens.txt', fileContent);
      }
    } else if (modelId == PredefinedModels.qwen3Asr.id) {
      if (filename.contains('conv_frontend') && filename.endsWith('.onnx')) {
        saveBoth('qwen3_conv_frontend.int8.onnx', fileContent);
      } else if (filename.contains('encoder') && filename.endsWith('.onnx')) {
        saveBoth('qwen3_encoder.int8.onnx', fileContent);
      } else if (filename.contains('decoder') && filename.endsWith('.onnx')) {
        saveBoth('qwen3_decoder.int8.onnx', fileContent);
      } else if (filename.endsWith('tokenizer.json') || filename.endsWith('tokens.txt')) {
        saveBoth('qwen3_tokenizer.json', fileContent);
      }
    } else if (modelId == PredefinedModels.parakeetTdt.id) {
      if (filename.contains('encoder') && filename.endsWith('.onnx')) {
        saveBoth('parakeet_encoder.int8.onnx', fileContent);
      } else if (filename.contains('decoder') && filename.endsWith('.onnx')) {
        saveBoth('parakeet_decoder.int8.onnx', fileContent);
      } else if (filename.contains('joiner') && filename.endsWith('.onnx')) {
        saveBoth('parakeet_joiner.int8.onnx', fileContent);
      } else if (filename.endsWith('tokens.txt')) {
        saveBoth('parakeet_tokens.txt', fileContent);
      }
    } else if (modelId == PredefinedModels.pyannote.id) {
      if (filename.endsWith('.onnx')) {
        saveBoth('pyannote_segmentation.onnx', fileContent);
      }
    }
  }
}
