import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/isolate/inference_worker.dart';

void main() {
  group('formatSenseVoiceText 富文本声音事件与语言标记测试', () {
    test('标准中文纯文本应正常保留，语言与普通控制符安全剔除', () {
      const input = '<|zh|><|NEUTRAL|><|Speech|>今天下午举行项目进度评审会议。';
      final output = formatSenseVoiceText(input);
      expect(output, '今天下午举行项目进度评审会议。');
    });

    test('中英混杂 (Code-Switching) 与纯英文应完整保留', () {
      const input = '<|zh|><|NEUTRAL|><|Speech|>我们正在使用 Flutter 与 ONNX Runtime 进行端侧 AI 部署。';
      final output = formatSenseVoiceText(input);
      expect(output, '我们正在使用 Flutter 与 ONNX Runtime 进行端侧 AI 部署。');
    });

    test('富文本声音事件 (笑声/掌声/音乐/咳嗽等) 应被友好转译为中文括号标记', () {
      const input = '<|zh|><|HAPPY|><|Laughter|>哈哈太好笑了！<|Applause|>大家纷纷鼓掌。<|Cough|>';
      final output = formatSenseVoiceText(input);
      expect(output, contains('[笑声]'));
      expect(output, contains('[掌声]'));
      expect(output, contains('[咳嗽]'));
      expect(output, contains('哈哈太好笑了！'));
      expect(output, contains('大家纷纷鼓掌。'));
    });

    test('纯背景音乐 (BGM) 或音效音频不应被删空，而应清晰提示', () {
      const input = '<|zh|><|NEUTRAL|><|BGM|>';
      final output = formatSenseVoiceText(input);
      expect(output, '[音乐]');
    });

    test('连续控制标签与多余空格应规范压缩', () {
      const input = '<|zh|>  <|NEUTRAL|>   <|Speech|>  测试内容   ';
      final output = formatSenseVoiceText(input);
      expect(output, '测试内容');
    });
  });
}
