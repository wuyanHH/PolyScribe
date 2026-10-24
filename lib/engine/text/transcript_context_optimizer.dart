import '../../data/models/transcript_segment.dart';

/// 上下文整合优化结果汇总
class ContextOptimizeResult {
  final List<TranscriptSegment> segments;
  final int originalCount;
  final int optimizedCount;
  final int mergedCount;

  const ContextOptimizeResult({
    required this.segments,
    required this.originalCount,
    required this.optimizedCount,
    required this.mergedCount,
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

  /// 对段落列表执行智能上下文整合与断句归并
  ///
  /// [maxMergeGapMs]: 同一发言人允许合并的最大发音间隔，默认 1500 毫秒 (1.5秒)
  /// [forceMergeShortFragments]: 当片段极短 (<=4 个字符) 时，允许更宽松的间隔 (最大 2500 毫秒)
  static ContextOptimizeResult optimize(
    List<TranscriptSegment> source, {
    int maxMergeGapMs = 1500,
    bool forceMergeShortFragments = true,
  }) {
    if (source.length <= 1) {
      return ContextOptimizeResult(
        segments: List.of(source),
        originalCount: source.length,
        optimizedCount: source.length,
        mergedCount: 0,
      );
    }

    final List<TranscriptSegment> result = [];
    int mergedCounter = 0;

    TranscriptSegment current = source.first;

    for (int i = 1; i < source.length; i++) {
      final next = source[i];

      if (_shouldMerge(current, next, maxMergeGapMs, forceMergeShortFragments)) {
        // 执行合并
        current = _mergeTwoSegments(current, next);
        mergedCounter++;
      } else {
        result.add(current);
        current = next;
      }
    }
    result.add(current);

    return ContextOptimizeResult(
      segments: result,
      originalCount: source.length,
      optimizedCount: result.length,
      mergedCount: mergedCounter,
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

  /// 合并两条段落并智能重构标点与时间区间
  static TranscriptSegment _mergeTwoSegments(TranscriptSegment a, TranscriptSegment b) {
    final textA = a.text.trim();
    final textB = b.text.trim();

    String mergedText = textA;
    if (textA.isNotEmpty && textB.isNotEmpty) {
      final lastCharA = textA.substring(textA.length - 1);
      final firstCharB = textB.substring(0, 1);

      final hasEndingA = _terminatingPunctuation.contains(lastCharA) ||
          _continuationPunctuation.contains(lastCharA);

      // 若两端均为英文字母或数字，需补空格
      final isAsciiA = RegExp(r'[a-zA-Z0-9]').hasMatch(lastCharA);
      final isAsciiB = RegExp(r'[a-zA-Z0-9]').hasMatch(firstCharB);

      if (!hasEndingA) {
        if (isAsciiA && isAsciiB) {
          mergedText = '$textA $textB';
        } else {
          // 中文在语流未完结时，如后文非连词且前文有一定长度，可平滑连接
          mergedText = '$textA$textB';
        }
      } else {
        if (isAsciiA && isAsciiB) {
          mergedText = '$textA $textB';
        } else {
          mergedText = '$textA$textB';
        }
      }
    } else {
      mergedText = '$textA$textB';
    }

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
