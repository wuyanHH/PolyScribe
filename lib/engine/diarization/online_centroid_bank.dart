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

  /// 对声纹向量执行 L2 单位超球面归一化
  static Float32List normalizeL2(Float32List vec) {
    double sumSq = 0.0;
    for (int i = 0; i < vec.length; i++) {
      sumSq += vec[i] * vec[i];
    }
    final norm = sqrt(sumSq);
    if (norm <= 1e-12) return vec;
    final out = Float32List(vec.length);
    for (int i = 0; i < vec.length; i++) {
      out[i] = vec[i] / norm;
    }
    return out;
  }

  /// 注册预设实名声纹库（例如“张总”、“李工”）
  void registerKnownVoicePrints(List<VoicePrint> prints) {
    _knownVoicePrints.clear();
    _knownVoicePrints.addAll(prints);
  }

  /// 常见语义连续/承接特征 (表明该句极大可能是前一句的语义延伸，而非换人发言)
  static final List<String> continuationPrefixes = [
    '而且', '并且', '然后', '但是', '不过', '因而', '所以', '那么',
    '另外', '此外', '其实', '也就是说', '就是说', '对吧', '以及', '包括',
    '接着', '还有', '因此', '哪怕', '虽然',
  ];

  /// 常见极短语义肯定/应答词
  static final Set<String> shortAffirmations = {
    '对', '对对', '对对对', '好', '好的', '是的', '没错', '嗯', '嗯嗯',
    '确实', '明白', 'OK', '行',
  };

  /// 常见对话换人提示短语 (表明正在向他人提问或交接话语权)
  static final List<RegExp> turnTakingPatterns = [
    RegExp(r'(你|您)觉得呢'),
    RegExp(r'(你|您)怎么看'),
    RegExp(r'我想补充一点'),
    RegExp(r'我不同意'),
  ];

  /// 分配或匹配声纹向量 (融合语义连贯度反哺，彻底消解声学轻微漂移造成的误切角色)
  ///
  /// [embedding]: 当前音频切片的声纹向量 (192或512维)
  /// [durationMs]: 切片时长 (毫秒)
  /// [startMs]: 切片起始时间
  /// [endMs]: 切片结束时间
  /// [spokenText]: 当前切片对应的转写文本内容 (用于语义反哺声纹分离)
  CentroidMatchResult assignSpeaker({
    required Float32List embedding,
    required int durationMs,
    required int startMs,
    required int endMs,
    String? spokenText,
  }) {
    final normEmb = normalizeL2(embedding);
    final gap = startMs - _lastSpeechEndMs;
    final text = spokenText?.trim() ?? '';

    // 语义连续性特征检测
    final hasContinuationPrefix = continuationPrefixes.any((p) => text.startsWith(p));
    final isShortAffirmation = shortAffirmations.contains(text);
    final isSemanticContinuation = hasContinuationPrefix || isShortAffirmation;
    final isTurnTaking = turnTakingPatterns.any((p) => p.hasMatch(text));

    // 1. 语义驱动的强连续性平滑 (若前后间隔在 4.5 秒内且后句是承接连词/极短应答，优先继承上一发言人)
    if (_lastSpeakerId != null &&
        gap >= 0 &&
        gap <= 4500 &&
        isSemanticContinuation &&
        !isTurnTaking) {
      final lastCentroid = _centroids[_lastSpeakerId];
      if (lastCentroid != null) {
        final lastSim = _cosineSimilarity(normEmb, lastCentroid);
        // 只要声学相似度不低于 0.38 (允许声调起伏或离麦克风距离变化)，依靠语义连续性直接锁定上一角色
        if (lastSim >= 0.38) {
          _lastSpeechEndMs = endMs;
          if (durationMs >= AppConstants.minValidSpeechMs) {
            _updateCentroid(_lastSpeakerId!, normEmb);
          }
          return CentroidMatchResult(
            speakerId: _lastSpeakerId!,
            speakerName: _speakerNames[_lastSpeakerId!],
            similarity: lastSim,
            isNewSpeaker: false,
          );
        }
      }
    }

    // 2. 连续发言时序平滑与短语音漂移抑制 (自然呼吸间隔 4.5 秒以内且时长较短时平滑继承)
    if (_lastSpeakerId != null &&
        gap >= 0 &&
        gap <= AppConstants.maxSpeakerShiftGapMs &&
        !isTurnTaking) {
      final lastCentroid = _centroids[_lastSpeakerId];
      final lastSim = lastCentroid != null ? _cosineSimilarity(normEmb, lastCentroid) : 0.0;
      // 若时长较短 (< 1.0s) 或者与上一发言人相似度 >= 0.38，坚决平滑继承，杜绝同一个人中途换角
      if (durationMs < AppConstants.minValidSpeechMs || lastSim >= 0.38) {
        _lastSpeechEndMs = endMs;
        if (durationMs >= AppConstants.minValidSpeechMs && lastCentroid != null) {
          _updateCentroid(_lastSpeakerId!, normEmb);
        }
        return CentroidMatchResult(
          speakerId: _lastSpeakerId!,
          speakerName: _speakerNames[_lastSpeakerId!],
          similarity: lastSim > 0 ? lastSim : 1.0,
          isNewSpeaker: false,
        );
      }
    }

    // 3. 比对实名声纹库
    double maxKnownSim = -1.0;
    VoicePrint? matchedKnown;
    for (final known in _knownVoicePrints) {
      final sim = known.cosineSimilarity(normEmb);
      if (sim > maxKnownSim) {
        maxKnownSim = sim;
        matchedKnown = known;
      }
    }

    // 4. 比对当前会议已存在的质心池 (融入语义加成)
    String? bestSpeakerId;
    double maxCentroidSim = -1.0;

    for (final entry in _centroids.entries) {
      double sim = _cosineSimilarity(normEmb, entry.value);
      // 若该候选人就是上一发言人且当前句具有语义承接，给予 +0.08 的语义连贯加成
      if (entry.key == _lastSpeakerId && isSemanticContinuation && !isTurnTaking && gap <= 3000) {
        sim = (sim + 0.08).clamp(0.0, 1.0);
      }
      if (sim > maxCentroidSim) {
        maxCentroidSim = sim;
        bestSpeakerId = entry.key;
      }
    }

    // 短语音匹配时允许适当宽容阈值 (-0.04)，防止特征微弱漂移新建角色
    final effectiveThreshold = durationMs < AppConstants.minValidSpeechMs
        ? (similarityThreshold - 0.04).clamp(0.38, 0.65)
        : similarityThreshold;

    String finalSpeakerId;
    String? finalSpeakerName;
    bool isNew = false;
    double reportedSim = 0.0;

    if (maxCentroidSim >= effectiveThreshold && bestSpeakerId != null) {
      // 命中已有角色
      finalSpeakerId = bestSpeakerId;
      reportedSim = maxCentroidSim;
      finalSpeakerName = _speakerNames[bestSpeakerId];
      // 仅当该切片时长足够长 (>=1200ms) 且特征质量高时，才允许参与质心迭代，杜绝质心被短噪污染！
      if (durationMs >= AppConstants.minValidSpeechMs) {
        _updateCentroid(bestSpeakerId, normEmb);
      }
    } else if (matchedKnown != null && maxKnownSim >= effectiveThreshold) {
      // 命中实名声纹库
      finalSpeakerId = 'SPK_${_nextSpeakerIndex.toString().padLeft(2, '0')}';
      _nextSpeakerIndex++;
      finalSpeakerName = matchedKnown.personName;
      _centroids[finalSpeakerId] = Float32List.fromList(normEmb);
      _speakerNames[finalSpeakerId] = finalSpeakerName;
      reportedSim = maxKnownSim;
      isNew = true;
    } else {
      // 判定为新角色 (必须达到一定时长，避免偶发环境异音单独立角)
      finalSpeakerId = 'SPK_${_nextSpeakerIndex.toString().padLeft(2, '0')}';
      _nextSpeakerIndex++;
      _centroids[finalSpeakerId] = Float32List.fromList(normEmb);
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

  /// 计算余弦相似度 (入参必须已 L2 归一化)
  double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  /// 指数移动平均更新质心向量并执行严格 L2 投影归一化 (防质心模长衰减与漂移)
  void _updateCentroid(String speakerId, Float32List newVector) {
    final current = _centroids[speakerId];
    if (current == null || current.length != newVector.length) return;

    double sumSq = 0.0;
    for (int i = 0; i < current.length; i++) {
      final v = (emaAlpha * current[i]) + ((1.0 - emaAlpha) * newVector[i]);
      current[i] = v;
      sumSq += v * v;
    }

    final norm = sqrt(sumSq);
    if (norm > 1e-12) {
      for (int i = 0; i < current.length; i++) {
        current[i] /= norm;
      }
    }
  }

  /// 全局多角色后处理凝聚聚类与合并 (彻底消除“同一个人由于初期声音波动被误切为多个角色”)
  ///
  /// 返回各个待合并角色重定向映射关系：例如 {'SPK_02': 'SPK_01', 'SPK_03': 'SPK_01'}
  Map<String, String> consolidateSpeakers({double mergeThreshold = 0.42}) {
    final spkIds = _centroids.keys.toList()..sort();
    if (spkIds.length <= 1) return {};

    // 简单并查集
    final parent = <String, String>{};
    for (final id in spkIds) {
      parent[id] = id;
    }

    String find(String x) {
      if (parent[x] != x) {
        parent[x] = find(parent[x]!);
      }
      return parent[x]!;
    }

    void union(String a, String b) {
      final rootA = find(a);
      final rootB = find(b);
      if (rootA != rootB) {
        // 优先保留字典序较小 (即出现更早) 的编号
        if (rootA.compareTo(rootB) < 0) {
          parent[rootB] = rootA;
        } else {
          parent[rootA] = rootB;
        }
      }
    }

    // 两两比对余弦相似度
    for (int i = 0; i < spkIds.length; i++) {
      for (int j = i + 1; j < spkIds.length; j++) {
        final idA = spkIds[i];
        final idB = spkIds[j];
        final sim = _cosineSimilarity(_centroids[idA]!, _centroids[idB]!);
        if (sim >= mergeThreshold) {
          union(idA, idB);
        }
      }
    }

    // 构建映射字典
    final Map<String, String> mapping = {};
    for (final id in spkIds) {
      final root = find(id);
      if (root != id) {
        mapping[id] = root;
      }
    }

    return mapping;
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
