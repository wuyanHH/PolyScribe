import 'dart:math';
import 'dart:typed_data';
import '../../core/constants/app_constants.dart';
import '../../data/models/voice_print.dart';

/// 动态聚类判定结果
class CentroidMatchResult {
  final String speakerId;
  final String? speakerName;
  final double similarity;
  final bool isNewSpeaker;

  const CentroidMatchResult({
    required this.speakerId,
    this.speakerName,
    required this.similarity,
    required this.isNewSpeaker,
  });
}

/// 实时动态声纹质心池管理器 (Dynamic Centroid Bank)
///
/// 用于在线实时长会议场景：
/// 1. 动态与已有声纹质心池计算余弦相似度；
/// 2. 相似度 >= 0.65 判定为同一发言人，并使用 EMA 指数移动平均平滑更新质心；
/// 3. 相似度 < 0.65 时，自动生成新的 speakerId (如 SPK_01, SPK_02...)；
/// 4. 支持短语音漂移抑制 (短于 800ms 且间隔在 400ms 以内时继承上一说话人，不更新质心)；
/// 5. 支持预置实名库 (VoicePrint) 自动比对匹配人名。
class OnlineCentroidBank {
  final double similarityThreshold;
  final double emaAlpha;
  final Map<String, Float32List> _centroids = {};
  final Map<String, String> _speakerNames = {};
  final List<VoicePrint> _knownVoicePrints = [];

  String? _lastSpeakerId;
  int _lastSpeechEndMs = 0;
  int _nextSpeakerIndex = 1;

  OnlineCentroidBank({
    this.similarityThreshold = AppConstants.speakerSimilarityThreshold,
    this.emaAlpha = AppConstants.emaAlpha,
    List<VoicePrint>? initialVoicePrints,
  }) {
    if (initialVoicePrints != null) {
      _knownVoicePrints.addAll(initialVoicePrints);
    }
  }

  /// 注册预设实名声纹库（例如“张总”、“李工”）
  void registerKnownVoicePrints(List<VoicePrint> prints) {
    _knownVoicePrints.clear();
    _knownVoicePrints.addAll(prints);
  }

  /// 分配或匹配声纹向量
  ///
  /// [embedding]: 当前音频切片的声纹向量 (192或512维)
  /// [durationMs]: 切片时长 (毫秒)
  /// [startMs]: 切片起始时间
  /// [endMs]: 切片结束时间
  CentroidMatchResult assignSpeaker({
    required Float32List embedding,
    required int durationMs,
    required int startMs,
    required int endMs,
  }) {
    // 1. 极短语音漂移抑制 (短于 800ms)
    final gap = startMs - _lastSpeechEndMs;
    if (durationMs < AppConstants.minValidSpeechMs &&
        _lastSpeakerId != null &&
        gap <= AppConstants.maxSpeakerShiftGapMs) {
      // 继承上一说话人，且该段离散特征不参与质心迭代
      _lastSpeechEndMs = endMs;
      return CentroidMatchResult(
        speakerId: _lastSpeakerId!,
        speakerName: _speakerNames[_lastSpeakerId!],
        similarity: 1.0,
        isNewSpeaker: false,
      );
    }

    // 2. 首先比对实名声纹库
    double maxKnownSim = -1.0;
    VoicePrint? matchedKnown;
    for (final known in _knownVoicePrints) {
      final sim = known.cosineSimilarity(embedding);
      if (sim > maxKnownSim) {
        maxKnownSim = sim;
        matchedKnown = known;
      }
    }

    // 3. 比对当前会议已存在的质心池
    String? bestSpeakerId;
    double maxCentroidSim = -1.0;

    for (final entry in _centroids.entries) {
      final sim = _cosineSimilarity(embedding, entry.value);
      if (sim > maxCentroidSim) {
        maxCentroidSim = sim;
        bestSpeakerId = entry.key;
      }
    }

    String finalSpeakerId;
    String? finalSpeakerName;
    bool isNew = false;
    double reportedSim = 0.0;

    if (maxCentroidSim >= similarityThreshold && bestSpeakerId != null) {
      // 命中已有角色，执行 EMA 质心平滑演进
      finalSpeakerId = bestSpeakerId;
      reportedSim = maxCentroidSim;
      finalSpeakerName = _speakerNames[bestSpeakerId];
      _updateCentroid(bestSpeakerId, embedding);
    } else if (matchedKnown != null && maxKnownSim >= similarityThreshold) {
      // 命中实名声纹库
      finalSpeakerId = 'SPK_${_nextSpeakerIndex.toString().padLeft(2, '0')}';
      _nextSpeakerIndex++;
      finalSpeakerName = matchedKnown.personName;
      _centroids[finalSpeakerId] = Float32List.fromList(embedding);
      _speakerNames[finalSpeakerId] = finalSpeakerName;
      reportedSim = maxKnownSim;
      isNew = true;
    } else {
      // 判定为新角色
      finalSpeakerId = 'SPK_${_nextSpeakerIndex.toString().padLeft(2, '0')}';
      _nextSpeakerIndex++;
      _centroids[finalSpeakerId] = Float32List.fromList(embedding);
      reportedSim = maxCentroidSim > 0 ? maxCentroidSim : 0.0;
      isNew = true;
    }

    _lastSpeakerId = finalSpeakerId;
    _lastSpeechEndMs = endMs;

    return CentroidMatchResult(
      speakerId: finalSpeakerId,
      speakerName: finalSpeakerName,
      similarity: reportedSim,
      isNewSpeaker: isNew,
    );
  }

  /// 计算余弦相似度
  double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      final va = a[i];
      final vb = b[i];
      dot += va * vb;
      normA += va * va;
      normB += vb * vb;
    }
    if (normA <= 0.0 || normB <= 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  /// 指数移动平均更新质心向量
  void _updateCentroid(String speakerId, Float32List newVector) {
    final current = _centroids[speakerId];
    if (current == null || current.length != newVector.length) return;

    for (int i = 0; i < current.length; i++) {
      current[i] = (emaAlpha * current[i]) + ((1.0 - emaAlpha) * newVector[i]);
    }
  }

  /// 重置当前会议质心状态
  void reset() {
    _centroids.clear();
    _speakerNames.clear();
    _lastSpeakerId = null;
    _lastSpeechEndMs = 0;
    _nextSpeakerIndex = 1;
  }
}
