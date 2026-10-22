import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/core/utils/binary_search_util.dart';

class MockTimeRange implements TimeRanged {
  @override
  final int startMs;
  @override
  final int endMs;
  final String text;

  MockTimeRange(this.startMs, this.endMs, this.text);
}

void main() {
  group('BinarySearchUtil 音字同步二分查找测试', () {
    final segments = [
      MockTimeRange(100, 1500, '第一段发言'),
      MockTimeRange(1800, 3200, '第二段发言'),
      MockTimeRange(4000, 6500, '第三段发言'),
      MockTimeRange(7000, 9500, '第四段发言'),
    ];

    test('空列表测试', () {
      expect(BinarySearchUtil.findActiveIndex(<MockTimeRange>[], 500), -1);
    });

    test('精确命中某段发音区间', () {
      expect(BinarySearchUtil.findActiveIndex(segments, 500), 0);
      expect(BinarySearchUtil.findActiveIndex(segments, 2500), 1);
      expect(BinarySearchUtil.findActiveIndex(segments, 5000), 2);
      expect(BinarySearchUtil.findActiveIndex(segments, 8000), 3);
    });

    test('落入静音空白停顿期应回退临近上一段', () {
      // 1600ms 处于第一段(1500)与第二段(1800)之间
      expect(BinarySearchUtil.findActiveIndex(segments, 1600), 0);
      // 3500ms 处于第二段(3200)与第三段(4000)之间
      expect(BinarySearchUtil.findActiveIndex(segments, 3500), 1);
    });

    test('边界测试: 小于起始时间与大于结束时间', () {
      expect(BinarySearchUtil.findActiveIndex(segments, 50), 0);
      expect(BinarySearchUtil.findActiveIndex(segments, 12000), 3);
    });
  });
}
