/// 语音识别文本与上下文智能清洗重构引擎
///
/// 解决 ASR 模型常见的：
/// 1. 汉字间夹杂空格 (如 "今 天 天 气" -> "今天天气")
/// 2. 连续 3 次及以上复读机叠字/口吃 (如 "对对对对对" -> "对对")
/// 3. 切片重叠拼接 (前句末尾与后句开头的重复重叠消除)
/// 4. 异常首尾标点、重复标点与特殊标签清理
class TranscriptCleaner {
  /// 中文终结性标点
  static final Set<String> terminatingPunctuations = {'。', '！', '？', '.', '!', '?'};

  /// 中文停顿/非终结性标点
  static final Set<String> pausePunctuations = {'，', '、', '；', '：', ',', ';', ':'};

  /// 单句原始文本规范清洗
  static String cleanRawText(String raw) {
    if (raw.trim().isEmpty) return '';

    String text = raw;

    // 1. 剥离模型底层可能泄漏的特殊控制标记 (保留已友好化的 [笑声] [掌声] 等有价值标签)
    text = text.replaceAll(RegExp(r'<\|[^|]*\|>'), '');
    text = text.replaceAll(RegExp(r'\[(BLANK|blank|UNK|unk|PAD|pad|SEP|sep)\]'), '');
    text = text.replaceAll(RegExp(r'<unk>|<pad>|<s>|</s>', caseSensitive: false), '');

    // 2. 消除汉字与汉字之间的无意义空格 (部分 CTC/Transducer 模型会将汉字分词并以空格隔开)
    // 循环消除：匹配 "中文 + 空格 + 中文" 并去除中间空格
    text = _removeChineseInterCharSpaces(text);

    // 3. 口吃与连续叠字清洗 (对对对对对 -> 对对, 那个那个那个 -> 那个)
    text = _cleanStutterAndRepetition(text);

    // 4. 标点符号规范化
    text = _normalizePunctuations(text);

    // 5. 中英文之间混排微空格规范化 (如 "学习Flutter开发" -> "学习 Flutter 开发")
    text = _formatMixedChineseAndEnglish(text);

    return text.trim();
  }

  /// 消除汉字与汉字之间的无意义空格，同时保留英文单词之间和中英之间的自然空格
  static String _removeChineseInterCharSpaces(String text) {
    String current = text;
    // 匹配: 汉字/全角标点 + 空格 + 汉字/全角标点
    final cnSpaceCn = RegExp(r'([\u4e00-\u9fa5，。！？；：、“”‘’（）《》])\s+([\u4e00-\u9fa5，。！？；：、“”‘’（）《》])');
    while (cnSpaceCn.hasMatch(current)) {
      current = current.replaceAllMapped(cnSpaceCn, (m) => '${m[1]}${m[2]}');
    }
    return current;
  }

  /// 常见承接连词与前缀
  static final List<String> continuationPrefixes = [
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

  /// 口吃与冗余叠词平滑清洗
  static String _cleanStutterAndRepetition(String text) {
    String res = text;

    // 单字叠字限制：如 "对对对对对对" 保留为 "对对"，"嗯嗯嗯嗯" 保留为 "嗯嗯"
    res = res.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])\1{2,}'), (m) {
      final ch = m[1]!;
      // 常见拟声词或肯定义保留两字，如 "对对"、"嗯嗯"、"好好"
      return '$ch$ch';
    });

    // 2~4 字口头语叠词 (优先由长到短匹配)：如 "也就是说"、"就是说"、"然后"
    res = res.replaceAllMapped(
      RegExp(r'(也就是说|就是说|然后|就是|那个|其实|那么|因而)\1+'),
      (m) => m[1]!,
    );

    return res;
  }

  /// 标点符号规范化与冗余去除
  static String _normalizePunctuations(String text) {
    String s = text;

    // 合并连续相同的标点 (如 "，，" -> "，", "。。" -> "。")
    s = s.replaceAll(RegExp(r'([，,、]){2,}'), '，');
    s = s.replaceAll(RegExp(r'([。.]){2,}'), '。');
    s = s.replaceAll(RegExp(r'([！!]){2,}'), '！');
    s = s.replaceAll(RegExp(r'([？?]){2,}'), '？');
    s = s.replaceAll(RegExp(r'([；;]){2,}'), '；');

    // 清理句首非法的孤立标点 (如以 "，"、"。"、"、" 开头)
    s = s.replaceAll(RegExp(r'^[，。！？；：、,.\?!;:\s]+'), '');

    // 中文环境下的英文逗号与句号转为全角
    s = s.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5]),'), (m) => '${m[1]}，');
    s = s.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])\.(?!\d)'), (m) => '${m[1]}。');
    s = s.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])\?'), (m) => '${m[1]}？');
    s = s.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])!'), (m) => '${m[1]}！');

    // 规范连续空白
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ');

    return s;
  }

  /// 中英混排格式化：在中英文边界适当增加空格，保证视觉排版舒适
  static String _formatMixedChineseAndEnglish(String text) {
    String s = text;
    // 中文后接英文字母/数字
    s = s.replaceAllMapped(
      RegExp(r'([\u4e00-\u9fa5])([a-zA-Z0-9])'),
      (m) => '${m[1]} ${m[2]}',
    );
    // 英文字母/数字后接中文
    s = s.replaceAllMapped(
      RegExp(r'([a-zA-Z0-9])([\u4e00-\u9fa5])'),
      (m) => '${m[1]} ${m[2]}',
    );
    return s;
  }

  /// 消除跨切片首尾重叠词 (Overlap Deduplication)
  ///
  /// [previousText]: 前一句已识别文本
  /// [currentText]: 当前刚识别出的文本
  /// 返回清洗并去除了开头重叠内容后的 [currentText]
  static String removeOverlap(
    String previousText,
    String currentText, {
    int minOverlapChars = 2,
    int maxOverlapChars = 12,
  }) {
    final prev = previousText.trim();
    final curr = currentText.trim();

    if (prev.isEmpty || curr.isEmpty) return curr;

    // 去除末尾标点进行纯文字对齐比较
    final cleanPrev = prev.replaceAll(RegExp(r'[，。！？；：、,\.!\?;:\s]+$'), '');
    final cleanCurr = curr.replaceAll(RegExp(r'^[，。！？；：、,\.!\?;:\s]+'), '');

    if (cleanPrev.isEmpty || cleanCurr.isEmpty) return curr;

    final checkLen = cleanPrev.length < maxOverlapChars ? cleanPrev.length : maxOverlapChars;

    // 从最长可能重叠开始向下比对
    for (int len = checkLen; len >= minOverlapChars; len--) {
      final suffix = cleanPrev.substring(cleanPrev.length - len);
      if (cleanCurr.startsWith(suffix)) {
        // 发现重叠！截掉当前句开头的重叠文本
        final deduplicated = cleanCurr.substring(suffix.length).trim();
        // 清理截断后句首可能暴露的标点
        return deduplicated.replaceAll(RegExp(r'^[，。！？；：、,\.!\?;:\s]+'), '');
      }
    }

    return curr;
  }

  /// 在上下文中平滑合并两段文本（包含重叠消除、标点承接与中英文间隔处理）
  static String mergeWithContext(String previousText, String currentText) {
    final cleanedCurrent = cleanRawText(currentText);
    final prev = cleanRawText(previousText);

    if (prev.isEmpty) return cleanedCurrent;
    if (cleanedCurrent.isEmpty) return prev;

    // 1. 去除首尾重叠
    final dedupCurrent = removeOverlap(prev, cleanedCurrent);
    if (dedupCurrent.isEmpty) return prev;

    final lastCharPrev = prev.substring(prev.length - 1);
    final firstCharCurr = dedupCurrent.substring(0, 1);

    final hasTerminating = terminatingPunctuations.contains(lastCharPrev);
    final hasPause = pausePunctuations.contains(lastCharPrev);

    final isPrevAscii = RegExp(r'[a-zA-Z0-9]').hasMatch(lastCharPrev);
    final isCurrAscii = RegExp(r'[a-zA-Z0-9]').hasMatch(firstCharCurr);

    if (hasTerminating) {
      // 前句已终结，中英文之间留自然空格，中文直接紧跟
      if (isPrevAscii && isCurrAscii) {
        return '$prev $dedupCurrent';
      }
      return '$prev$dedupCurrent';
    } else if (hasPause) {
      // 前句以停顿标点 (如逗号) 结尾
      if (isPrevAscii && isCurrAscii) {
        return '$prev $dedupCurrent';
      }
      return '$prev$dedupCurrent';
    } else {
      // 前句未打标点，两句属于同一个被切断的连续语流，平滑连接
      if (isPrevAscii && isCurrAscii) {
        return '$prev $dedupCurrent';
      }
      return '$prev$dedupCurrent';
    }
  }
}
