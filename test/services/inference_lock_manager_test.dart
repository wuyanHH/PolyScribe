import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/services/server/inference_lock_manager.dart';

void main() {
  group('InferenceLockManager 并发排队锁与审计日志测试', () {
    test('runWithLock 互斥排队执行验证', () async {
      final lock = InferenceLockManager.instance;
      final executionOrder = <int>[];

      // 启动 3 个并发任务
      final future1 = lock.runWithLock(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        executionOrder.add(1);
        return 1;
      });

      final future2 = lock.runWithLock(() async {
        await Future.delayed(const Duration(milliseconds: 50));
        executionOrder.add(2);
        return 2;
      });

      final future3 = lock.runWithLock(() async {
        executionOrder.add(3);
        return 3;
      });

      await Future.wait([future1, future2, future3]);

      // 验证执行顺序必须为严格串行 1 -> 2 -> 3
      expect(executionOrder, [1, 2, 3]);
    });

    test('recordLog 请求审计记录', () {
      final lock = InferenceLockManager.instance;
      final initialTotal = lock.totalRequests;

      lock.recordLog(ApiCallLog(
        id: 'test_call_1',
        timestamp: DateTime.now(),
        clientIp: '192.168.1.10',
        endpoint: '/v1/audio/transcriptions',
        audioBytesLength: 32000,
        latencyMs: 120,
        resultPreview: '离线语音识别正常完成',
        statusCode: 200,
      ));

      expect(lock.totalRequests, initialTotal + 1);
      expect(lock.recentLogs.first.id, 'test_call_1');
    });
  });
}
