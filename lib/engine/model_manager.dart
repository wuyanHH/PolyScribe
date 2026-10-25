import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../data/database/app_database.dart';
import '../services/app_storage_service.dart';
import 'models/model_package_info.dart';

/// 模型配置信息
class ModelConfig {
  /// 当前激活的语音识别 (ASR) 模型 ID (例如 'sensevoice_small', 'paraformer_zh', 'qwen3_asr', 'parakeet_tdt')
  final String activeAsrModelId;

  final String vadModelPath;
  final String? pyannoteModelPath;
  final String? camppModelPath;
  final String preferredLanguage;
  final String hotwords;

  // SenseVoice
  final String senseVoiceModelPath;
  final String senseVoiceTokensPath;

  // Paraformer
  final String paraformerModelPath;
  final String paraformerTokensPath;

  // Qwen3-ASR
  final String qwen3ConvFrontendPath;
  final String qwen3EncoderPath;
  final String qwen3DecoderPath;
  final String qwen3TokenizerPath;

  // Parakeet-TDT
  final String parakeetEncoderPath;
  final String parakeetDecoderPath;
  final String parakeetJoinerPath;
  final String parakeetTokensPath;

  const ModelConfig({
    this.activeAsrModelId = 'sensevoice_small',
    required this.vadModelPath,
    this.pyannoteModelPath,
    this.camppModelPath,
    this.preferredLanguage = 'zh',
    this.hotwords = '',
    required this.senseVoiceModelPath,
    required this.senseVoiceTokensPath,
    required this.paraformerModelPath,
    required this.paraformerTokensPath,
    required this.qwen3ConvFrontendPath,
    required this.qwen3EncoderPath,
    required this.qwen3DecoderPath,
    required this.qwen3TokenizerPath,
    required this.parakeetEncoderPath,
    required this.parakeetDecoderPath,
    required this.parakeetJoinerPath,
    required this.parakeetTokensPath,
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

  /// SenseVoice-Small INT8 权重需 >= 50MB 且 tokens.txt >= 1KB
  bool get isSenseVoiceReady =>
      _isValidFile(senseVoiceModelPath, 50 * 1024 * 1024) &&
      _isValidFile(senseVoiceTokensPath, 1024);

  /// Paraformer-zh INT8 权重需 >= 50MB 且 tokens.txt >= 1KB
  bool get isParaformerReady =>
      _isValidFile(paraformerModelPath, 50 * 1024 * 1024) &&
      _isValidFile(paraformerTokensPath, 1024);

  /// Qwen3-ASR 0.6B INT8
  bool get isQwen3Ready =>
      _isValidFile(qwen3ConvFrontendPath, 500 * 1024) &&
      _isValidFile(qwen3EncoderPath, 30 * 1024 * 1024) &&
      _isValidFile(qwen3DecoderPath, 50 * 1024 * 1024) &&
      _isValidFile(qwen3TokenizerPath, 100);

  /// Parakeet-TDT 0.6B INT8
  bool get isParakeetReady =>
      _isValidFile(parakeetEncoderPath, 50 * 1024 * 1024) &&
      _isValidFile(parakeetDecoderPath, 5 * 1024 * 1024) &&
      _isValidFile(parakeetJoinerPath, 500 * 1024) &&
      _isValidFile(parakeetTokensPath, 100);

  /// Silero-VAD 权重需 >= 100KB
  bool get isVadReady => _isValidFile(vadModelPath, 100 * 1024);

  /// 声纹特征提取模型需 >= 5MB
  bool get isCamppReady => _isValidFile(camppModelPath, 5 * 1024 * 1024);

  bool get isDiarizationReady =>
      _isValidFile(pyannoteModelPath, 500 * 1024) && isCamppReady;

  /// 判断当前激活的主 ASR 模型是否就绪
  bool get isCurrentAsrReady {
    switch (activeAsrModelId) {
      case 'paraformer_zh':
        return isParaformerReady;
      case 'qwen3_asr':
        return isQwen3Ready;
      case 'parakeet_tdt':
        return isParakeetReady;
      case 'sensevoice_small':
      default:
        return isSenseVoiceReady;
    }
  }

  /// 获取当前生效的识别模型名称
  String get currentAsrName {
    switch (activeAsrModelId) {
      case 'paraformer_zh':
        return 'Paraformer-zh 工业级中文';
      case 'qwen3_asr':
        return 'Qwen3-ASR 大模型语义';
      case 'parakeet_tdt':
        return 'Parakeet-TDT 英文与多语种';
      case 'sensevoice_small':
      default:
        return 'SenseVoice-Small';
    }
  }

  /// 是否有任何一个 ASR 模型已安装并就绪
  bool get isAnyAsrReady =>
      isSenseVoiceReady || isParaformerReady || isQwen3Ready || isParakeetReady;
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
    // 1. 若用户设定了外部自定义存储目录，优先直接返回外部模型的专属目录
    if (AppStorageService.instance.isCustomDirActive) {
      final customModelDir = await AppStorageService.instance.getModelsDirectory();
      return customModelDir;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      return await AppStorageService.instance.getModelsDirectory();
    } else {
      // 桌面端多候选路径探测
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
        final customOrAppSupport = await AppStorageService.instance.getModelsDirectory();
        candidates.add(customOrAppSupport);
      } catch (_) {}

      for (final cand in candidates) {
        if (cand.existsSync()) {
          // 只要存在任一支持的 ASR 模型文件，即为有效候选目录
          if (File(p.join(cand.path, 'sensevoice_small_int8.onnx')).existsSync() ||
              File(p.join(cand.path, 'paraformer_model.int8.onnx')).existsSync() ||
              File(p.join(cand.path, 'qwen3_encoder.int8.onnx')).existsSync() ||
              File(p.join(cand.path, 'parakeet_encoder.int8.onnx')).existsSync()) {
            return cand;
          }
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
    String activeAsr = PredefinedModels.senseVoiceSmall.id;
    String savedHotwords = '';

    try {
      final dbLang = await AppDatabase.instance.getSetting('preferred_language');
      if (dbLang != null && dbLang.isNotEmpty) {
        savedLang = dbLang;
      }
    } catch (_) {}

    try {
      final dbAsr = await AppDatabase.instance.getSetting('active_asr_model');
      if (dbAsr != null && dbAsr.isNotEmpty) {
        activeAsr = dbAsr;
      }
    } catch (_) {}

    try {
      final dbHotwords = await AppDatabase.instance.getSetting('custom_hotwords');
      if (dbHotwords != null && dbHotwords.isNotEmpty) {
        savedHotwords = dbHotwords;
      }
    } catch (_) {}

    final config = ModelConfig(
      activeAsrModelId: activeAsr,
      vadModelPath: p.join(modelDirPath, 'silero_vad.onnx'),
      pyannoteModelPath: p.join(modelDirPath, 'pyannote_segmentation.onnx'),
      camppModelPath: p.join(modelDirPath, 'campp_plus.onnx'),
      preferredLanguage: savedLang,
      hotwords: savedHotwords,
      // SenseVoice
      senseVoiceModelPath: p.join(modelDirPath, 'sensevoice_small_int8.onnx'),
      senseVoiceTokensPath: p.join(modelDirPath, 'tokens.txt'),
      // Paraformer
      paraformerModelPath: p.join(modelDirPath, 'paraformer_model.int8.onnx'),
      paraformerTokensPath: p.join(modelDirPath, 'paraformer_tokens.txt'),
      // Qwen3-ASR
      qwen3ConvFrontendPath: p.join(modelDirPath, 'qwen3_conv_frontend.int8.onnx'),
      qwen3EncoderPath: p.join(modelDirPath, 'qwen3_encoder.int8.onnx'),
      qwen3DecoderPath: p.join(modelDirPath, 'qwen3_decoder.int8.onnx'),
      qwen3TokenizerPath: p.join(modelDirPath, 'qwen3_tokenizer.json'),
      // Parakeet-TDT
      parakeetEncoderPath: p.join(modelDirPath, 'parakeet_encoder.int8.onnx'),
      parakeetDecoderPath: p.join(modelDirPath, 'parakeet_decoder.int8.onnx'),
      parakeetJoinerPath: p.join(modelDirPath, 'parakeet_joiner.int8.onnx'),
      parakeetTokensPath: p.join(modelDirPath, 'parakeet_tokens.txt'),
    );

    // 如果选中的主模型尚未就绪，但有其他模型已就绪，则智能自动回退就绪模型
    String finalActiveAsr = activeAsr;
    if (!config.isCurrentAsrReady) {
      if (config.isSenseVoiceReady) {
        finalActiveAsr = PredefinedModels.senseVoiceSmall.id;
      } else if (config.isParaformerReady) {
        finalActiveAsr = PredefinedModels.paraformerZh.id;
      } else if (config.isQwen3Ready) {
        finalActiveAsr = PredefinedModels.qwen3Asr.id;
      } else if (config.isParakeetReady) {
        finalActiveAsr = PredefinedModels.parakeetTdt.id;
      }
    }

    final effectiveConfig = (finalActiveAsr != activeAsr)
        ? ModelConfig(
            activeAsrModelId: finalActiveAsr,
            vadModelPath: config.vadModelPath,
            pyannoteModelPath: config.pyannoteModelPath,
            camppModelPath: config.camppModelPath,
            preferredLanguage: config.preferredLanguage,
            hotwords: config.hotwords,
            senseVoiceModelPath: config.senseVoiceModelPath,
            senseVoiceTokensPath: config.senseVoiceTokensPath,
            paraformerModelPath: config.paraformerModelPath,
            paraformerTokensPath: config.paraformerTokensPath,
            qwen3ConvFrontendPath: config.qwen3ConvFrontendPath,
            qwen3EncoderPath: config.qwen3EncoderPath,
            qwen3DecoderPath: config.qwen3DecoderPath,
            qwen3TokenizerPath: config.qwen3TokenizerPath,
            parakeetEncoderPath: config.parakeetEncoderPath,
            parakeetDecoderPath: config.parakeetDecoderPath,
            parakeetJoinerPath: config.parakeetJoinerPath,
            parakeetTokensPath: config.parakeetTokensPath,
          )
        : config;

    _config = effectiveConfig;
    debugPrint('[ModelManager] 模型探测路径: $modelDirPath');
    debugPrint('[ModelManager] 当前激活 ASR: ${effectiveConfig.currentAsrName} (就绪: ${effectiveConfig.isCurrentAsrReady})');
    debugPrint('[ModelManager] VAD 就绪: ${effectiveConfig.isVadReady}');
    debugPrint('[ModelManager] 声纹分离就绪: ${effectiveConfig.isDiarizationReady}');

    return effectiveConfig;
  }

  /// 切换并持久化激活的主语音识别 ASR 模型
  Future<void> setActiveAsrModel(String modelId) async {
    try {
      await AppDatabase.instance.saveSetting('active_asr_model', modelId);
    } catch (e) {
      debugPrint('[ModelManager] 保存 active_asr_model 设置失败: $e');
    }
    await resolveModels();
  }
}
