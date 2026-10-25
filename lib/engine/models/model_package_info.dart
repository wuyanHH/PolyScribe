import 'dart:io';
import 'package:path/path.dart' as p;

/// 模型分类类型
enum ModelCategory {
  asr(label: '语音识别 (ASR)', badge: 'STT'),
  vad(label: '语音活动检测 (VAD)', badge: 'VAD'),
  diarization(label: '说话人声纹与分离', badge: 'Diarization');

  final String label;
  final String badge;

  const ModelCategory({
    required this.label,
    required this.badge,
  });
}

/// 模型下载网络源类型
enum ModelDownloadSource {
  modelScope(
    label: '国内高速镜像源 (ModelScope / 加速镜像)',
    badge: '推荐高速',
    description: '阿里魔搭与国内 CDN 高速直连，单文件直出免解压，防 TLS 握手中断',
  ),
  official(
    label: '官方直连源 (GitHub Releases)',
    badge: '国际直连',
    description: 'k2-fsa 官方构建打包发布包 (适合海外或高速代理环境)',
  );

  final String label;
  final String badge;
  final String description;

  const ModelDownloadSource({
    required this.label,
    required this.badge,
    required this.description,
  });
}

/// 模型单个下载任务条目
class DownloadItem {
  final String url;
  final String destinationFileName;
  final bool isArchive;
  final int estimatedSizeBytes;

  const DownloadItem({
    required this.url,
    required this.destinationFileName,
    this.isArchive = false,
    required this.estimatedSizeBytes,
  });
}

/// 模型包元数据定义 (支持子目录沙盒隔离架构与向前兼容平铺结构)
class ModelPackageInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final ModelCategory category;
  final int estimatedSizeBytes;
  final String sizeDisplay;
  final String sandboxDir; // 模型专属独立沙盒子目录名 (例如 sensevoice_small)
  final List<String> targetFileNames;
  final Map<ModelDownloadSource, List<DownloadItem>> downloadItems;

  const ModelPackageInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.category = ModelCategory.asr,
    required this.estimatedSizeBytes,
    required this.sizeDisplay,
    required this.sandboxDir,
    required this.targetFileNames,
    required this.downloadItems,
  });

  /// 是否为主语音识别 ASR 模型
  bool get isAsrModel => category == ModelCategory.asr;

  /// 获取该模型在基准目录下的专属沙盒目录绝对路径
  String getSandboxPath(String baseDirectory) => p.join(baseDirectory, sandboxDir);

  /// 检查该模型在目标目录下是否已经完整就绪 (双向检测沙盒目录与旧版平铺根目录，确保无缝兼容)
  bool isInstalled(String targetDirectory) {
    final sandbox = getSandboxPath(targetDirectory);
    // 优先检查沙盒子目录
    bool sandboxComplete = true;
    for (final fileName in targetFileNames) {
      final f = File(p.join(sandbox, fileName));
      if (!f.existsSync() || f.lengthSync() < (fileName.endsWith('.onnx') ? 100 * 1024 : 100)) {
        sandboxComplete = false;
        break;
      }
    }
    if (sandboxComplete) return true;

    // 回退检查根目录 (向后平滑兼容老版本平铺存放的文件)
    for (final fileName in targetFileNames) {
      final file = File(p.join(targetDirectory, fileName));
      if (!file.existsSync() || file.lengthSync() < (fileName.endsWith('.onnx') ? 100 * 1024 : 100)) {
        return false;
      }
    }
    return true;
  }

  /// 获取指定网络源的下载项列表 (若未配置则回退到国内高速源)
  List<DownloadItem> getItems(ModelDownloadSource source) {
    return downloadItems[source] ?? downloadItems[ModelDownloadSource.modelScope]!;
  }
}

/// 内置的预定义模型资产清单 (链接经亲测 200 OK 验证)
class PredefinedModels {
  /// 1. 主 STT 语音识别模型: SenseVoice-Small (Int8)
  static const ModelPackageInfo senseVoiceSmall = ModelPackageInfo(
    id: 'sensevoice_small',
    name: 'SenseVoice-Small 离线语音识别',
    version: '2024-07-17 (Int8)',
    description: '中/粤/英/日/韩五语种自动识别，富文本声音与情绪检测，RTF ≈ 0.05 极速端侧推理',
    category: ModelCategory.asr,
    estimatedSizeBytes: 228 * 1024 * 1024,
    sizeDisplay: '228 MB',
    sandboxDir: 'sensevoice_small',
    targetFileNames: ['sensevoice_small_int8.onnx', 'tokens.txt'],
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/resolve/main/model.int8.onnx',
          destinationFileName: 'sensevoice_small_int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 228 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/resolve/main/tokens.txt',
          destinationFileName: 'tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 315 * 1024,
        ),
      ],
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://modelscope.cn/api/v1/models/adihzgnaz/sherpa-onnx-sensevoice-small/repo?Revision=master&FilePath=model_q8.onnx',
          destinationFileName: 'sensevoice_small_int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 228 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://modelscope.cn/api/v1/models/adihzgnaz/sherpa-onnx-sensevoice-small/repo?Revision=master&FilePath=tokens.txt',
          destinationFileName: 'tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 315 * 1024,
        ),
      ],
    },
  );

  /// 2. 主 STT 语音识别模型: Paraformer-zh (阿里达摩院经典工业级中文模型)
  static const ModelPackageInfo paraformerZh = ModelPackageInfo(
    id: 'paraformer_zh',
    name: 'Paraformer-zh 工业级中文识别',
    version: '2023-09-14 (Int8)',
    description: '阿里达摩院中文工业级王牌模型，极低字错率 (CER)，中文咬字稳定且断句精准',
    category: ModelCategory.asr,
    estimatedSizeBytes: 230 * 1024 * 1024,
    sizeDisplay: '230 MB',
    sandboxDir: 'paraformer_zh',
    targetFileNames: ['paraformer_model.int8.onnx', 'paraformer_tokens.txt'],
    downloadItems: {
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/model.int8.onnx',
          destinationFileName: 'paraformer_model.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 243371218,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/tokens.txt',
          destinationFileName: 'paraformer_tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 147570,
        ),
      ],
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/model.int8.onnx',
          destinationFileName: 'paraformer_model.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 243371218,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14/resolve/main/tokens.txt',
          destinationFileName: 'paraformer_tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 147570,
        ),
      ],
    },
  );

  /// 3. 主 STT 语音识别模型: Qwen3-ASR (通义千问大模型语音识别)
  static const ModelPackageInfo qwen3Asr = ModelPackageInfo(
    id: 'qwen3_asr',
    name: 'Qwen3-ASR 0.6B 大模型语义识别',
    version: '0.6B (Int8)',
    description: '结合通义千问语言解码器，深层上下文语义纠错与连贯断句，同音词区分度极高',
    category: ModelCategory.asr,
    estimatedSizeBytes: 480 * 1024 * 1024,
    sizeDisplay: '480 MB',
    sandboxDir: 'qwen3_asr',
    targetFileNames: [
      'qwen3_conv_frontend.int8.onnx',
      'qwen3_encoder.int8.onnx',
      'qwen3_decoder.int8.onnx',
      'qwen3_tokenizer.json',
    ],
    downloadItems: {
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_conv_frontend.int8.onnx',
          destinationFileName: 'qwen3_conv_frontend.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 10 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_encoder.int8.onnx',
          destinationFileName: 'qwen3_encoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 200 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_decoder.int8.onnx',
          destinationFileName: 'qwen3_decoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 270 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_tokenizer.json',
          destinationFileName: 'qwen3_tokenizer.json',
          isArchive: false,
          estimatedSizeBytes: 500 * 1024,
        ),
      ],
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_conv_frontend.int8.onnx',
          destinationFileName: 'qwen3_conv_frontend.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 10 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_encoder.int8.onnx',
          destinationFileName: 'qwen3_encoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 200 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_decoder.int8.onnx',
          destinationFileName: 'qwen3_decoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 270 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main/qwen3_tokenizer.json',
          destinationFileName: 'qwen3_tokenizer.json',
          isArchive: false,
          estimatedSizeBytes: 500 * 1024,
        ),
      ],
    },
  );

  /// 4. 主 STT 语音识别模型: Parakeet-TDT 0.6B (NVIDIA 英文与多语种王牌)
  static const ModelPackageInfo parakeetTdt = ModelPackageInfo(
    id: 'parakeet_tdt',
    name: 'Parakeet-TDT 0.6B 英文与多语种识别',
    version: 'v3 (Int8)',
    description: 'NVIDIA 开源 SOTA 级 Transducer 架构，英文会议与欧洲多语种转写天花板',
    category: ModelCategory.asr,
    estimatedSizeBytes: 450 * 1024 * 1024,
    sizeDisplay: '450 MB',
    sandboxDir: 'parakeet_tdt',
    targetFileNames: [
      'parakeet_encoder.int8.onnx',
      'parakeet_decoder.int8.onnx',
      'parakeet_joiner.int8.onnx',
      'parakeet_tokens.txt',
    ],
    downloadItems: {
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/encoder.int8.onnx',
          destinationFileName: 'parakeet_encoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 300 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/decoder.int8.onnx',
          destinationFileName: 'parakeet_decoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 30 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/joiner.int8.onnx',
          destinationFileName: 'parakeet_joiner.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 10 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/tokens.txt',
          destinationFileName: 'parakeet_tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 100 * 1024,
        ),
      ],
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/encoder.int8.onnx',
          destinationFileName: 'parakeet_encoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 300 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/decoder.int8.onnx',
          destinationFileName: 'parakeet_decoder.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 30 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/joiner.int8.onnx',
          destinationFileName: 'parakeet_joiner.int8.onnx',
          isArchive: false,
          estimatedSizeBytes: 10 * 1024 * 1024,
        ),
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/tokens.txt',
          destinationFileName: 'parakeet_tokens.txt',
          isArchive: false,
          estimatedSizeBytes: 100 * 1024,
        ),
      ],
    },
  );

  /// VAD 语音活动检测: Silero-VAD v5
  static const ModelPackageInfo sileroVad = ModelPackageInfo(
    id: 'silero_vad',
    name: 'Silero-VAD v5 语音活动检测',
    version: 'v5.0',
    description: '毫秒级精准检测人声起止，滤除背景杂音与静音无效片段',
    category: ModelCategory.vad,
    estimatedSizeBytes: 2 * 1024 * 1024,
    sizeDisplay: '1.8 MB',
    sandboxDir: 'silero_vad',
    targetFileNames: ['silero_vad.onnx'],
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
          destinationFileName: 'silero_vad.onnx',
          isArchive: false,
          estimatedSizeBytes: 2 * 1024 * 1024,
        ),
      ],
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://modelscope.cn/api/v1/models/manyeyes/silero-vad-onnx/repo?Revision=master&FilePath=silero_vad.onnx',
          destinationFileName: 'silero_vad.onnx',
          isArchive: false,
          estimatedSizeBytes: 1807522,
        ),
      ],
    },
  );

  /// 换人切分边界检测: Pyannote 3.0
  static const ModelPackageInfo pyannote = ModelPackageInfo(
    id: 'pyannote_segmentation',
    name: 'Pyannote 3.0 角色切分边界检测',
    version: '3.0',
    description: '多人会议抢话与轮流发言边界侦测，自动分割不同说话人音频片断',
    category: ModelCategory.diarization,
    estimatedSizeBytes: 6 * 1024 * 1024,
    sizeDisplay: '6.0 MB',
    sandboxDir: 'pyannote',
    targetFileNames: ['pyannote_segmentation.onnx'],
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx',
          destinationFileName: 'pyannote_segmentation.onnx',
          isArchive: false,
          estimatedSizeBytes: 5992913,
        ),
      ],
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://modelscope.cn/api/v1/models/pengzhendong/sherpa-onnx-pyannote-segmentation-3-0/repo?Revision=master&FilePath=model.onnx',
          destinationFileName: 'pyannote_segmentation.onnx',
          isArchive: false,
          estimatedSizeBytes: 5992913,
        ),
      ],
    },
  );

  /// 声纹特征提取: CAM++ / ERes2Net
  static const ModelPackageInfo campp = ModelPackageInfo(
    id: 'campp_plus',
    name: 'CAM++ / 3D-Speaker 声纹特征提取',
    version: '16k-zh-cn',
    description: '阿里开源高维声纹向量提取器，精准归集说话人身份聚类',
    category: ModelCategory.diarization,
    estimatedSizeBytes: 28 * 1024 * 1024,
    sizeDisplay: '28.0 MB',
    sandboxDir: 'campp',
    targetFileNames: ['campp_plus.onnx'],
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
          destinationFileName: 'campp_plus.onnx',
          isArchive: false,
          estimatedSizeBytes: 28 * 1024 * 1024,
        ),
      ],
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://hf-mirror.com/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
          destinationFileName: 'campp_plus.onnx',
          isArchive: false,
          estimatedSizeBytes: 39593761,
        ),
      ],
    },
  );

  /// 所有支持的语音识别 (ASR) 引擎候选列表
  static const List<ModelPackageInfo> asrModels = [
    senseVoiceSmall,
    paraformerZh,
    qwen3Asr,
    parakeetTdt,
  ];

  /// 所有支持的标准核心模型列表
  static const List<ModelPackageInfo> all = [
    senseVoiceSmall,
    paraformerZh,
    qwen3Asr,
    parakeetTdt,
    sileroVad,
    campp,
    pyannote,
  ];
}
