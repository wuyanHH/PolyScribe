import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 移动端与桌面端统一后台保活管理器
class KeepAliveService {
  static KeepAliveService? _instance;
  static KeepAliveService get instance => _instance ??= KeepAliveService._();

  KeepAliveService._();

  static const MethodChannel _channel = MethodChannel('com.polyscribe.audio/keep_alive');
  bool _isWakeLockActive = false;

  bool get isWakeLockActive => _isWakeLockActive;

  /// 申请唤醒锁 (PARTIAL_WAKE_LOCK，录音时防止 CPU 息屏休眠)
  Future<void> acquireWakeLock({String reason = '会议录音保活'}) async {
    if (_isWakeLockActive) return;
    _isWakeLockActive = true;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('acquireWakeLock', {'reason': reason});
        debugPrint('[KeepAliveService] 已申请 Android WakeLock: $reason');
      } catch (e) {
        debugPrint('[KeepAliveService] 申请 WakeLock 失败: $e');
      }
    } else {
      debugPrint('[KeepAliveService] 当前平台已激活保活防休眠');
    }
  }

  /// 释放唤醒锁
  Future<void> releaseWakeLock() async {
    if (!_isWakeLockActive) return;
    _isWakeLockActive = false;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('releaseWakeLock');
        debugPrint('[KeepAliveService] 已释放 Android WakeLock');
      } catch (e) {
        debugPrint('[KeepAliveService] 释放 WakeLock 失败: $e');
      }
    }
  }

  /// 启动系统前台服务 (声明 microphone|mediaPlayback 双类型)
  Future<void> startForegroundService({
    required String title,
    required String content,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('startForegroundService', {
          'title': title,
          'content': content,
        });
      } catch (e) {
        debugPrint('[KeepAliveService] 启动前台服务失败: $e');
      }
    }
  }

  /// 停止前台服务
  Future<void> stopForegroundService() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopForegroundService');
      } catch (e) {
        debugPrint('[KeepAliveService] 停止前台服务失败: $e');
      }
    }
  }
}
