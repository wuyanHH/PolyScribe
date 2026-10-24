import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/database/app_database.dart';

/// 模型配置信息
class ModelConfig {
  final String vadModelPath;
  final String senseVoiceModelPath;
  final String senseVoiceTokensPath;
  final String? pyannoteModelPath;
  final String? camppModelPath;
  final String preferredLanguage;

  const ModelConfig({
    required this.vadModelPath,
    required this.senseVoiceModelPath,
    required this.senseVoiceTokensPath,
    this.pyannoteModelPath,
    this.camppModelPath,
    this.preferredLanguage = 'zh',
  });

  static bool _isValidFile(String? path, int minBytes) {
    if (path == null || path.isEmpty) return false;
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  /// SenseVoice-Small INT8 权重需 >= 50MB 且 tokens.txt >= 1KB，防止不完整文件导致底层 C++ ORT_ABORT 闪退
  bool get isSenseVoiceReady =>
      _isValidFile(senseVoiceModelPath, 50 * 1024 * 1024) &&
      _isValidFile(senseVoiceTokensPath, 1024);

  /// Silero-VAD 权重需 >= 100KB
  bool get isVadReady => _isValidFile(vadModelPath, 100 * 1024);

  /// 声纹特征提取模型需 >= 5MB
  bool get isCamppReady => _isValidFile(camppModelPath, 5 * 1024 * 1024);

  bool get isDiarizationReady =>
      _isValidFile(pyannoteModelPath, 500 * 1024) &&
      isCamppReady;
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

    String savedLang = 'zh';
    try {
      final dbLang = await AppDatabase.instance.getSetting('preferred_language');
      if (dbLang != null && dbLang.isNotEmpty) {
        savedLang = dbLang;
      }
    } catch (_) {}

    final config = ModelConfig(
      vadModelPath: p.join(modelDirPath, 'silero_vad.onnx'),
      senseVoiceModelPath: p.join(modelDirPath, 'sensevoice_small_int8.onnx'),
      senseVoiceTokensPath: p.join(modelDirPath, 'tokens.txt'),
      pyannoteModelPath: p.join(modelDirPath, 'pyannote_segmentation.onnx'),
      camppModelPath: p.join(modelDirPath, 'campp_plus.onnx'),
      preferredLanguage: savedLang,
    );

    _config = config;
    debugPrint('[ModelManager] 模型探测路径: $modelDirPath');
    debugPrint('[ModelManager] VAD 就绪: ${config.isVadReady}');
    debugPrint('[ModelManager] SenseVoice 就绪: ${config.isSenseVoiceReady}');
    debugPrint('[ModelManager] 声纹分离就绪: ${config.isDiarizationReady}');

    return config;
  }
}
