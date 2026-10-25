import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/text/transcript_cleaner.dart';

void main() {
  group('TranscriptCleaner 单元测试', () {
    test('消除汉字间夹杂空格，但保留英文单词空格与中英混排间距', () {
      expect(
        TranscriptCleaner.cleanRawText('今 天 天 气 真 不 错'),
        equals('今天天气真不错'),
      );

      expect(
        TranscriptCleaner.cleanRawText('我 们 使 用 Flutter 进 行 开 发'),
        equals('我们使用 Flutter 进行开发'),
      );

      expect(
        TranscriptCleaner.cleanRawText('hello world'),
        equals('hello world'),
      );
    });

    test('口吃与连续叠字清洗', () {
      // 连续 3 次及以上单字
      expect(
        TranscriptCleaner.cleanRawText('对对对对对对对，是的。'),
        equals('对对，是的。'),
      );

      // 连续 2 次及以上常见叠词
      expect(
        TranscriptCleaner.cleanRawText('然后然后然后我们继续'),
        equals('然后我们继续'),
      );

      expect(
        TranscriptCleaner.cleanRawText('就是说就是说就是说这个方案'),
        equals('就是说这个方案'),
      );
    });

    test('特殊模型标签与残留控制符号清除', () {
      expect(
        TranscriptCleaner.cleanRawText('<|zh|><|Speech|>今天开会<|NEUTRAL|>'),
        equals('今天开会'),
      );

      expect(
        TranscriptCleaner.cleanRawText('[BLANK]测试内容<unk>'),
        equals('测试内容'),
      );
    });

    test('标点符号规范化与非法句首标点剔除', () {
      expect(
        TranscriptCleaner.cleanRawText('，，今天开会。。对吗？？'),
        equals('今天开会。对吗？'),
      );

      expect(
        TranscriptCleaner.cleanRawText('中文逗号测试,转为全角.'),
        equals('中文逗号测试，转为全角。'),
      );
    });

    test('跨切片首尾重叠消除 (removeOverlap)', () {
      final prev = '我们今天下午要讨论的是关于项目的进展';
      final curr = '关于项目的进展我们已经做好了准备';

      final dedup = TranscriptCleaner.removeOverlap(prev, curr);
      expect(dedup, equals('我们已经做好了准备'));
    });

    test('上下文平滑合并与智能标点补偿 (mergeWithContext)', () {
      // 消除重叠并在连词边界智能注入标点，杜绝焊死无标点长句
      final prev = '这个功能已经实现完成';
      final curr = '已经实现完成并且测试通过了。';

      final merged = TranscriptCleaner.mergeWithContext(prev, curr);
      expect(merged, equals('这个功能已经实现完成，并且测试通过了。'));
    });

    test('中文自然断句标点恢复器 (restoreChinesePunctuation)', () {
      // 1. 语气助词后注入逗号，句末补齐句号
      final text1 = '大家今天都在啊我们来讨论一下方案';
      expect(
        TranscriptCleaner.restoreChinesePunctuation(text1),
        equals('大家今天都在啊，我们来讨论一下方案。'),
      );

      // 2. 连词前置标点注入与疑问句标点智能识别
      final text2 = '原本计划下周上线但是现在需求变了是不是';
      expect(
        TranscriptCleaner.restoreChinesePunctuation(text2),
        equals('原本计划下周上线，但是现在需求变了是不是？'),
      );
    });
  });
}
