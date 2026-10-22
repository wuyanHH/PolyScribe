import 'dart:io';
import 'package:path/path.dart' as p;

/// 模型下载网络源类型
enum ModelDownloadSource {
  modelScope(
    label: '国内高速源 (ModelScope)',
    badge: '推荐',
    description: '阿里云魔搭社区国内高速镜像，下载体验流畅稳定',
  ),
  github(
    label: '全球官方源 (GitHub)',
    badge: '官方',
    description: 'k2-fsa / sherpa-onnx 官方 Releases 直链',
  ),
  huggingFace(
    label: '海外镜像源 (HuggingFace)',
    badge: '备用',
    description: 'HuggingFace 社区开源模型镜像',
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

/// 模型包元数据定义
class ModelPackageInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final int estimatedSizeBytes;
  final String sizeDisplay;
  final List<String> targetFileNames;
  final bool isArchive;
  final Map<ModelDownloadSource, String> downloadUrls;

  const ModelPackageInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.estimatedSizeBytes,
    required this.sizeDisplay,
    required this.targetFileNames,
    required this.isArchive,
    required this.downloadUrls,
  });

  /// 检查该模型在目标目录下是否已经完整就绪
  bool isInstalled(String targetDirectory) {
    for (final fileName in targetFileNames) {
      final file = File(p.join(targetDirectory, fileName));
      if (!file.existsSync() || file.lengthSync() == 0) {
        return false;
      }
    }
    return true;
  }

  /// 获取指定网络源的下载直链
  String getUrl(ModelDownloadSource source) {
    return downloadUrls[source] ?? downloadUrls[ModelDownloadSource.modelScope]!;
  }
}

/// 内置的预定义模型资产清单
class PredefinedModels {
  /// 主 STT 语音识别模型: SenseVoice-Small (Int8)
  static const ModelPackageInfo senseVoiceSmall = ModelPackageInfo(
    id: 'sensevoice_small',
    name: 'SenseVoice-Small 离线语音识别',
    version: '2024-07-17 (Int8)',
    description: '高精度中/粤/英/日/韩五语种自动识别，RTF ≈ 0.05 极速端侧推理',
    estimatedSizeBytes: 228 * 1024 * 1024,
    sizeDisplay: '228 MB',
    targetFileNames: ['sensevoice_small_int8.onnx', 'tokens.txt'],
    isArchive: true,
    downloadUrls: {
      ModelDownloadSource.modelScope:
          'https://modelscope.cn/api/v1/models/adihzgnaz/sherpa-onnx-sensevoice-small/repo?Revision=master&FilePath=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
      ModelDownloadSource.github:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
      ModelDownloadSource.huggingFace:
          'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
    },
  );

  /// VAD 语音活动检测: Silero-VAD v5
  static const ModelPackageInfo sileroVad = ModelPackageInfo(
    id: 'silero_vad',
    name: 'Silero-VAD v5 语音活动检测',
    version: 'v5.0',
    description: '毫秒级精准检测人声起止，滤除背景杂音与静音无效片段',
    estimatedSizeBytes: 2 * 1024 * 1024 + 300 * 1024,
    sizeDisplay: '2.3 MB',
    targetFileNames: ['silero_vad.onnx'],
    isArchive: false,
    downloadUrls: {
      ModelDownloadSource.modelScope:
          'https://modelscope.cn/api/v1/models/csukuangfj/sherpa-onnx-vad/repo?Revision=master&FilePath=silero_vad.onnx',
      ModelDownloadSource.github:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
      ModelDownloadSource.huggingFace:
          'https://huggingface.co/csukuangfj/sherpa-onnx-vad/resolve/main/silero_vad.onnx',
    },
  );

  /// 换人切分边界检测: Pyannote 3.0
  static const ModelPackageInfo pyannote = ModelPackageInfo(
    id: 'pyannote_segmentation',
    name: 'Pyannote 3.0 角色切分边界检测',
    version: '3.0',
    description: '多人会议抢话与轮流发言边界侦测，自动分割不同说话人音频片断',
    estimatedSizeBytes: 6 * 1024 * 1024,
    sizeDisplay: '6.0 MB',
    targetFileNames: ['pyannote_segmentation.onnx'],
    isArchive: true,
    downloadUrls: {
      ModelDownloadSource.modelScope:
          'https://modelscope.cn/api/v1/models/csukuangfj/sherpa-onnx-speaker-diarization/repo?Revision=master&FilePath=sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
      ModelDownloadSource.github:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
      ModelDownloadSource.huggingFace:
          'https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
    },
  );

  /// 声纹特征提取: CAM++ / ERes2Net
  static const ModelPackageInfo campp = ModelPackageInfo(
    id: 'campp_plus',
    name: 'CAM++ / 3D-Speaker 声纹特征提取',
    version: '16k-zh-cn',
    description: '阿里开源高维声纹向量提取器，精准归集说话人身份聚类',
    estimatedSizeBytes: 25 * 1024 * 1024,
    sizeDisplay: '25.0 MB',
    targetFileNames: ['campp_plus.onnx'],
    isArchive: false,
    downloadUrls: {
      ModelDownloadSource.modelScope:
          'https://modelscope.cn/api/v1/models/csukuangfj/sherpa-onnx-speaker-diarization/repo?Revision=master&FilePath=3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
      ModelDownloadSource.github:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
      ModelDownloadSource.huggingFace:
          'https://huggingface.co/csukuangfj/sherpa-onnx-speaker-diarization/resolve/main/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
    },
  );

  /// 所有支持的标准核心模型列表
  static const List<ModelPackageInfo> all = [
    sileroVad,
    senseVoiceSmall,
    campp,
    pyannote,
  ];
}
