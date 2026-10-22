import 'dart:async';
import 'package:flutter/foundation.dart';

/// API 调用日志条目
class ApiCallLog {
  final String id;
  final DateTime timestamp;
  final String clientIp;
  final String endpoint;
  final int audioBytesLength;
  final int latencyMs;
  final String resultPreview;
  final int statusCode;

  const ApiCallLog({
    required this.id,
    required this.timestamp,
    required this.clientIp,
    required this.endpoint,
    required this.audioBytesLength,
    required this.latencyMs,
    required this.resultPreview,
    required this.statusCode,
  });
}

/// 推理并发锁与 API 调用审计中枢 (防 GPU/CPU 内存超载)
class InferenceLockManager {
  static InferenceLockManager? _instance;
  static InferenceLockManager get instance => _instance ??= InferenceLockManager._();

  InferenceLockManager._();

  Completer<void>? _currentLock;
  final List<ApiCallLog> _logs = [];

  final StreamController<ApiCallLog> _logStreamController =
      StreamController<ApiCallLog>.broadcast();

  Stream<ApiCallLog> get onLogAdded => _logStreamController.stream;
  List<ApiCallLog> get recentLogs => List.unmodifiable(_logs);

  int _totalRequests = 0;
  int _successRequests = 0;
  int get totalRequests => _totalRequests;
  int get successRequests => _successRequests;

  /// 安全加锁执行端侧推理任务
  Future<T> runWithLock<T>(Future<T> Function() task) async {
    while (_currentLock != null) {
      await _currentLock!.future;
    }

    _currentLock = Completer<void>();
    try {
      return await task();
    } finally {
      final lock = _currentLock;
      _currentLock = null;
      lock?.complete();
    }
  }

  /// 记录 API 请求日志
  void recordLog(ApiCallLog log) {
    _totalRequests++;
    if (log.statusCode == 200) {
      _successRequests++;
    }

    _logs.insert(0, log);
    if (_logs.length > 100) {
      _logs.removeLast();
    }
    _logStreamController.add(log);
    debugPrint('[InferenceLockManager] API 请求完成: ${log.endpoint} 耗时: ${log.latencyMs}ms 状态: ${log.statusCode}');
  }
}
