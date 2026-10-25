import '../../data/models/transcript_segment.dart';
import 'transcript_cleaner.dart';

/// 上下文整合优化结果汇总
class ContextOptimizeResult {
  final List<TranscriptSegment> segments;
  final int originalCount;
  final int optimizedCount;
  final int mergedCount;
  final int smoothedSpeakerCount;

  const ContextOptimizeResult({
    required this.segments,
    required this.originalCount,
    required this.optimizedCount,
    required this.mergedCount,
    this.smoothedSpeakerCount = 0,
  });
}

/// 转写上下文与断句智能优化引擎
///
/// 针对语音识别 (VAD 切音/停顿) 造成的同一发言人连续断句过碎、一句话被拆成两半等现象，
/// 进行上下文语义粘连度审查、标点连缀与时间戳精准平滑重构。
class TranscriptContextOptimizer {
  /// 终结性句尾标点集合 (表示完整句子终结)
  static final Set<String> _terminatingPunctuation = {
    '。',
    '！',
    '？',
    '.',
    '!',
    '?',
  };

  /// 连缀/非终结性标点集合
  static final Set<String> _continuationPunctuation = {
    '，',
    '、',
    '；',
    '：',
    '—',
    '-',
    ',',
    ';',
    ':',
    '…',
  };

  /// 常见承接连词与副词 (后句以这些词开头时，极大概率是前句未说完的延伸)
  static final List<String> _continuationPrefixes = [
    '而且',
    '并且',
    '然后',
    '但是',
    '不过',
    '因而',
    '所以',
    '那么',
    '另外',
    '此外',
    '其实',
    '也就是说',
    '就是说',
    '对吧',
    '以及',
    '包括',
  ];

  /// 常见对话换人与交接提示短语 (表明正在向他人提问或交接话语权，不予平滑)
  static final List<RegExp> _turnTakingPatterns = [
    RegExp(r'(你|您)觉得呢'),
    RegExp(r'(你|您)怎么看'),
    RegExp(r'我想补充一点'),
    RegExp(r'我不同意'),
  ];

  /// 双向三元组说话人平滑过滤 (Tri-gram Speaker Smoothing)
  ///
  /// 消除经典的 A -> B -> A 假阳性声学漂移夹心短片：
  /// 当发言人 A 正在说话，中间仅 1~2 秒由于身体移动或声调起伏被声学模型误判为 B，
  /// 但紧接着又继续是 A，且中间段时间短、间隔紧凑、语义无转折冲突时，
  /// 自动将 B 纠正归属于 A，消解碎片化打断与时间错位。
  static List<TranscriptSegment> smoothTrigramSpeakerDrift(List<TranscriptSegment> list) {
    if (list.length < 3) return List.of(list);

    final result = List<TranscriptSegment>.of(list);

    for (int i = 1; i < result.length - 1; i++) {
      final prev = result[i - 1];
      final curr = result[i];
      final next = result[i + 1];

      // 前后必须是同一个说话人，且中间段不同
      if (prev.speakerId == next.speakerId && curr.speakerId != prev.speakerId) {
        final durationMs = curr.endMs - curr.startMs;
        final gapBefore = curr.startMs - prev.endMs;
        final gapAfter = next.startMs - curr.endMs;

        // 紧凑性检查：前后停顿均在 2.0 秒以内，且中间段短于 2.5 秒 (或字数 <= 12)
        final isShortDuration = durationMs <= 2500 || curr.text.trim().length <= 12;
        final isCompactGap = gapBefore <= 2000 && gapAfter <= 2000;

        if (isShortDuration && isCompactGap) {
          // 语义冲突保护：若中间段明显是对话反驳或换人交接，不予平滑
          final text = curr.text.trim();
          final hasTurnTaking = _turnTakingPatterns.any((p) => p.hasMatch(text));

          if (!hasTurnTaking) {
            // 执行双向说话人归属修正
            result[i] = curr.copyWith(
              speakerId: prev.speakerId,
              speakerName: prev.speakerName,
            );
          }
        }
      }
    }

    return result;
  }

  /// 对段落列表执行智能上下文整合与断句归并 (融合双向三元组平滑与连贯断句重构)
  ///
  /// [maxMergeGapMs]: 同一发言人允许合并的最大发音间隔，默认 1500 毫秒 (1.5秒)
  /// [forceMergeShortFragments]: 当片段极短 (<=4 个字符) 时，允许更宽松的间隔 (最大 2500 毫秒)
  /// [enableSpeakerSmoothing]: 是否启用双向三元组说话人平滑，默认 true
  static ContextOptimizeResult optimize(
    List<TranscriptSegment> source, {
    int maxMergeGapMs = 1500,
    bool forceMergeShortFragments = true,
    bool enableSpeakerSmoothing = true,
  }) {
    if (source.length <= 1) {
      return ContextOptimizeResult(
        segments: List.of(source),
        originalCount: source.length,
        optimizedCount: source.length,
        mergedCount: 0,
        smoothedSpeakerCount: 0,
      );
    }

    // 阶段一：双向三元组说话人平滑修正 (消解 A-B-A 孤立夹心短片)
    int smoothedCounter = 0;
    List<TranscriptSegment> workingList = source;
    if (enableSpeakerSmoothing && source.length >= 3) {
      final smoothed = smoothTrigramSpeakerDrift(source);
      for (int i = 0; i < source.length; i++) {
        if (source[i].speakerId != smoothed[i].speakerId) {
          smoothedCounter++;
        }
      }
      workingList = smoothed;
    }

    // 阶段二：智能上下文与连贯断句归并
    final List<TranscriptSegment> result = [];
    int mergedCounter = 0;

    TranscriptSegment current = workingList.first;

    for (int i = 1; i < workingList.length; i++) {
      final next = workingList[i];

      if (_shouldMerge(current, next, maxMergeGapMs, forceMergeShortFragments)) {
        // 执行合并
        current = _mergeTwoSegments(current, next);
        mergedCounter++;
      } else {
        result.add(current.copyWith(
          text: TranscriptCleaner.restoreChinesePunctuation(current.text),
        ));
        current = next;
      }
    }
    result.add(current.copyWith(
      text: TranscriptCleaner.restoreChinesePunctuation(current.text),
    ));

    return ContextOptimizeResult(
      segments: result,
      originalCount: source.length,
      optimizedCount: result.length,
      mergedCount: mergedCounter,
      smoothedSpeakerCount: smoothedCounter,
    );
  }

  /// 审查两句相邻发言是否应当在上下文中合并为一句
  static bool _shouldMerge(
    TranscriptSegment a,
    TranscriptSegment b,
    int maxGapMs,
    bool forceMergeShort,
  ) {
    // 1. 说话人必须一致
    if (a.speakerId != b.speakerId) return false;

    // 2. 时间有效性 (后句不能在前句之前)
    final gapMs = b.startMs - a.endMs;
    if (gapMs < -500) return false; // 异常乱序不合并

    final textA = a.text.trim();
    final textB = b.text.trim();
    if (textA.isEmpty || textB.isEmpty) return true;

    final lastCharA = textA.substring(textA.length - 1);
    final hasTerminatingA = _terminatingPunctuation.contains(lastCharA);
    final hasContinuationA = _continuationPunctuation.contains(lastCharA);

    // 3. 极短语音碎片判断 (例如 "然后"、"就是"、"对" 等被 VAD 切散)
    final isShortFragment = textA.length <= 4 || textB.length <= 4;
    if (forceMergeShort && isShortFragment && gapMs <= 2500) {
      return true;
    }

    // 4. 前句未完结 (无终结标点) 或以逗号/顿号结尾，属于典型一句话被切成两段
    if (!hasTerminatingA || hasContinuationA) {
      if (gapMs <= 2200) {
        return true;
      }
    }

    // 5. 后句包含典型的上下文承接连词
    final hasContinuationPrefix = _continuationPrefixes.any((prefix) => textB.startsWith(prefix));
    if (hasContinuationPrefix && gapMs <= 2000) {
      return true;
    }

    // 6. 正常呼吸停顿范围内的连续紧凑短句 (间隔 <= maxGapMs)
    if (gapMs <= maxGapMs) {
      // 若合并后总长度不过长 (<= 120 字)，合并为同一个自然语流
      final combinedLength = textA.length + textB.length;
      if (combinedLength <= 120) {
        return true;
      }
    }

    return false;
  }

  /// 合并两条段落并智能重构标点与时间区间 (基于 TranscriptCleaner 消除首尾重叠与平滑拼接)
  static TranscriptSegment _mergeTwoSegments(TranscriptSegment a, TranscriptSegment b) {
    final gapMs = b.startMs - a.endMs;
    final mergedText = TranscriptCleaner.mergeWithContext(
      a.text,
      b.text,
      gapMs: gapMs > 0 ? gapMs : 0,
    );

    // 合并字词级时间戳 (如果有)
    final List<WordTimestamp> mergedWords = [...a.words, ...b.words];

    return TranscriptSegment(
      id: a.id, // 保留第一段的 id 作为锚点
      taskId: a.taskId,
      speakerId: a.speakerId,
      speakerName: a.speakerName ?? b.speakerName,
      startMs: a.startMs,
      endMs: b.endMs > a.endMs ? b.endMs : a.endMs,
      text: mergedText,
      words: mergedWords,
    );
  }
}
