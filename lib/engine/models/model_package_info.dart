import 'dart:io';
import 'package:path/path.dart' as p;

/// 模型下载网络源类型
enum ModelDownloadSource {
  official(
    label: '官方直连源 (GitHub Releases)',
    badge: '推荐',
    description: 'k2-fsa / sherpa-onnx 官方完整构建包，全球 CDN 加速',
  ),
  modelScope(
    label: '国内高速源 (ModelScope)',
    badge: '国内高速',
    description: '阿里魔搭社区国内高速镜像，下载体积精简',
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

/// 模型包元数据定义
class ModelPackageInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final int estimatedSizeBytes;
  final String sizeDisplay;
  final List<String> targetFileNames;
  final Map<ModelDownloadSource, List<DownloadItem>> downloadItems;

  const ModelPackageInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.estimatedSizeBytes,
    required this.sizeDisplay,
    required this.targetFileNames,
    required this.downloadItems,
  });

  /// 检查该模型在目标目录下是否已经完整就绪 (校验最小有效字节数，防止残损文件被误判为已安装)
  bool isInstalled(String targetDirectory) {
    for (final fileName in targetFileNames) {
      final file = File(p.join(targetDirectory, fileName));
      if (!file.existsSync()) {
        return false;
      }
      final len = file.lengthSync();
      final minRequired = fileName.endsWith('.onnx') ? 100 * 1024 : 1024;
      if (len < minRequired) {
        return false;
      }
    }
    return true;
  }

  /// 获取指定网络源的下载项列表 (若未配置则回退到官方源)
  List<DownloadItem> getItems(ModelDownloadSource source) {
    return downloadItems[source] ?? downloadItems[ModelDownloadSource.official]!;
  }
}

/// 内置的预定义模型资产清单 (链接经亲测 200 OK 验证)
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
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
          destinationFileName: 'sense_voice.tar.bz2',
          isArchive: true,
          estimatedSizeBytes: 228 * 1024 * 1024,
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

  /// VAD 语音活动检测: Silero-VAD v5
  static const ModelPackageInfo sileroVad = ModelPackageInfo(
    id: 'silero_vad',
    name: 'Silero-VAD v5 语音活动检测',
    version: 'v5.0',
    description: '毫秒级精准检测人声起止，滤除背景杂音与静音无效片段',
    estimatedSizeBytes: 2 * 1024 * 1024,
    sizeDisplay: '1.8 MB',
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
    estimatedSizeBytes: 6 * 1024 * 1024,
    sizeDisplay: '6.0 MB',
    targetFileNames: ['pyannote_segmentation.onnx'],
    downloadItems: {
      ModelDownloadSource.official: [
        DownloadItem(
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
          destinationFileName: 'pyannote.tar.bz2',
          isArchive: true,
          estimatedSizeBytes: 6 * 1024 * 1024,
        ),
      ],
      ModelDownloadSource.modelScope: [
        DownloadItem(
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
          destinationFileName: 'pyannote.tar.bz2',
          isArchive: true,
          estimatedSizeBytes: 6 * 1024 * 1024,
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
    estimatedSizeBytes: 28 * 1024 * 1024,
    sizeDisplay: '28.0 MB',
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
          url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
          destinationFileName: 'campp_plus.onnx',
          isArchive: false,
          estimatedSizeBytes: 28 * 1024 * 1024,
        ),
      ],
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
