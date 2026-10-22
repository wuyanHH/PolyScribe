/// 具备起止时间戳区间的协议接口
abstract class TimeRanged {
  int get startMs;
  int get endMs;
}

/// 音字同步专用二分查找算法工具
class BinarySearchUtil {
  BinarySearchUtil._();

  /// 在已按 [startMs] 递增排序的列表中二分查找命中 [targetMs] 的元素索引
  ///
  /// 若目标时间落入区间 [startMs, endMs]，返回精确命中索引；
  /// 若位于两段停顿空白区间，则返回最临近的前一段落索引；
  /// 若不在任何有效范围内或列表为空，返回 -1。
  static int findActiveIndex<T extends TimeRanged>(List<T> items, int targetMs) {
    if (items.isEmpty) return -1;
    if (targetMs < items.first.startMs) return 0;
    if (targetMs >= items.last.endMs) return items.length - 1;

    int low = 0;
    int high = items.length - 1;

    while (low <= high) {
      final mid = (low + high) >> 1;
      final item = items[mid];

      if (targetMs >= item.startMs && targetMs <= item.endMs) {
        return mid; // 精确命中当前语音段
      } else if (targetMs < item.startMs) {
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    // 未精确命中区间（处于说话人间隙/静音期），退回前一个最近的已发音段落
    final candidate = high.clamp(0, items.length - 1);
    return candidate;
  }
}
