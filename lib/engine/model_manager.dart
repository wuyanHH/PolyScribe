import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 模型配置信息
class ModelConfig {
  final String vadModelPath;
  final String senseVoiceModelPath;
  final String senseVoiceTokensPath;
  final String? pyannoteModelPath;
  final String? camppModelPath;

  const ModelConfig({
    required this.vadModelPath,
    required this.senseVoiceModelPath,
    required this.senseVoiceTokensPath,
    this.pyannoteModelPath,
    this.camppModelPath,
  });

  bool get isSenseVoiceReady =>
      File(senseVoiceModelPath).existsSync() &&
      File(senseVoiceTokensPath).existsSync();

  bool get isVadReady => File(vadModelPath).existsSync();

  bool get isDiarizationReady =>
      pyannoteModelPath != null &&
      File(pyannoteModelPath!).existsSync() &&
      camppModelPath != null &&
      File(camppModelPath!).existsSync();
}

/// 本地 AI 模型资产管理器
class ModelManager {
  static ModelManager? _instance;
  static ModelManager get instance => _instance ??= ModelManager._();

  ModelManager._();

  ModelConfig? _config;
  ModelConfig? get config => _config;

  /// 获取模型存储目录
  Future<Directory> getModelDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final appSupport = await getApplicationSupportDirectory();
      final modelDir = Directory(p.join(appSupport.path, 'models'));
      if (!modelDir.existsSync()) {
        await modelDir.create(recursive: true);
      }
      return modelDir;
    } else {
      // 桌面端多候选路径探测 (涵盖打包目录、Debug/Release 构建目录与用户数据目录)
      final exeDir = File(Platform.resolvedExecutable).parent;
      final curDir = Directory.current.path;
      final candidates = <Directory>[
        Directory(p.join(exeDir.path, 'models')),
        Directory(p.join(exeDir.parent.path, 'Release', 'models')),
        Directory(p.join(exeDir.parent.path, 'Debug', 'models')),
        Directory(p.join(curDir, 'build', 'windows', 'x64', 'runner', 'Release', 'models')),
        Directory(p.join(curDir, 'build', 'windows', 'x64', 'runner', 'Debug', 'models')),
        Directory(p.join(curDir, 'assets', 'models')),
        Directory(p.join(curDir, 'models')),
      ];

      try {
        final appSupport = await getApplicationSupportDirectory();
        candidates.add(Directory(p.join(appSupport.path, 'models')));
      } catch (_) {}

      for (final cand in candidates) {
        if (cand.existsSync() &&
            File(p.join(cand.path, 'sensevoice_small_int8.onnx')).existsSync() &&
            File(p.join(cand.path, 'tokens.txt')).existsSync()) {
          return cand;
        }
      }

      final desktopDir = Directory(p.join(exeDir.path, 'models'));
      if (!desktopDir.existsSync()) {
        await desktopDir.create(recursive: true);
      }
      return desktopDir;
    }
  }

  /// 扫描并定位已就绪的模型路径
  Future<ModelConfig> resolveModels() async {
    final dir = await getModelDirectory();
    final modelDirPath = dir.path;

    final config = ModelConfig(
      vadModelPath: p.join(modelDirPath, 'silero_vad.onnx'),
      senseVoiceModelPath: p.join(modelDirPath, 'sensevoice_small_int8.onnx'),
      senseVoiceTokensPath: p.join(modelDirPath, 'tokens.txt'),
      pyannoteModelPath: p.join(modelDirPath, 'pyannote_segmentation.onnx'),
      camppModelPath: p.join(modelDirPath, 'campp_plus.onnx'),
    );

    _config = config;
    debugPrint('[ModelManager] 模型探测路径: $modelDirPath');
    debugPrint('[ModelManager] VAD 就绪: ${config.isVadReady}');
    debugPrint('[ModelManager] SenseVoice 就绪: ${config.isSenseVoiceReady}');
    debugPrint('[ModelManager] 声纹分离就绪: ${config.isDiarizationReady}');

    return config;
  }
}
