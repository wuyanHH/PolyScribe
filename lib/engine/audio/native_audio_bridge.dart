import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 实时原生音频轮询状态数据包
class RealtimeAudioPollData {
  /// 最新采集到的 16kHz 单声道 Int16 PCM 字节数组
  final Uint8List pcm16kMonoBytes;

  /// 当前实时归一化振幅 (0.0 ~ 1.0)
  final double amplitude;

  /// 是否正在录制中
  final bool isRecording;

  const RealtimeAudioPollData({
    required this.pcm16kMonoBytes,
    required this.amplitude,
    required this.isRecording,
  });
}

/// 原生音频引擎跨平台桥接器
/// - Windows: 调用原生 Media Foundation 全格式解码器 + WASAPI Process/Endpoint Loopback 内录与麦克风双路采集
/// - Android: 调用原生 MediaExtractor + MediaCodec 硬件音频解码器
class NativeAudioBridge {
  static const MethodChannel _channel = MethodChannel('com.polyscribe.audio/native_audio');

  /// 是否支持原生 WASAPI 内录/混音采集
  static bool get isWindowsNativeSupported => !kIsWeb && Platform.isWindows;

  /// 调用系统原生媒体框架将任意外部音频 (m4a, mp3, aac, flac, ogg, wav, amr, opus...) 解码为标准 16kHz 单声道 WAV
  static Future<bool> decodeAudioToWav({
    required String inputPath,
    required String outputPath,
    int targetSampleRate = 16000,
    Duration timeout = const Duration(seconds: 180),
  }) async {
    if (kIsWeb) return false;
    try {
      final res = await _channel.invokeMethod<dynamic>('decodeAudioToWav', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'sampleRate': targetSampleRate,
      }).timeout(
        timeout,
        onTimeout: () {
          debugPrint('[NativeAudioBridge] 原生音频解码超时 (${timeout.inSeconds}s)，熔断降级');
          return {'success': false, 'error': 'decode timeout'};
        },
      );
      if (res is Map) {
        if (res['success'] != true && res.containsKey('error')) {
          debugPrint('[NativeAudioBridge] 原生音频解码失败，底层报告: ${res['error']}');
        }
        return res['success'] == true;
      }
      if (res is bool) {
        return res;
      }
      return false;
    } catch (e) {
      debugPrint('[NativeAudioBridge] 原生音频解码调用异常: $e');
      return false;
    }
  }

  /// 启动原生 WASAPI 录制 (支持 mic / speaker / dual 三种模式)
  static Future<bool> startRecording({
    required String filePath,
    required String mode,
  }) async {
    if (!isWindowsNativeSupported) return false;
    try {
      final res = await _channel.invokeMethod<dynamic>('startRecording', {
        'filePath': filePath,
        'mode': mode,
      });
      if (res is Map) {
        return res['success'] == true;
      }
      return res == true;
    } catch (e) {
      debugPrint('[NativeAudioBridge] 启动原生 WASAPI 录音异常: $e');
      return false;
    }
  }

  /// 暂停原生录制
  static Future<void> pauseRecording() async {
    if (!isWindowsNativeSupported) return;
    try {
      await _channel.invokeMethod<void>('pauseRecording');
    } catch (e) {
      debugPrint('[NativeAudioBridge] 暂停原生 WASAPI 录音异常: $e');
    }
  }

  /// 恢复原生录制
  static Future<void> resumeRecording() async {
    if (!isWindowsNativeSupported) return;
    try {
      await _channel.invokeMethod<void>('resumeRecording');
    } catch (e) {
      debugPrint('[NativeAudioBridge] 恢复原生 WASAPI 录音异常: $e');
    }
  }

  /// 停止原生录制并完成 WAV 头部封包
  static Future<String?> stopRecording() async {
    if (!isWindowsNativeSupported) return null;
    try {
      final res = await _channel.invokeMethod<dynamic>('stopRecording');
      if (res is Map) {
        return res['filePath'] as String?;
      }
      if (res is String) {
        return res;
      }
    } catch (e) {
      debugPrint('[NativeAudioBridge] 停止原生 WASAPI 录音异常: $e');
    }
    return null;
  }

  /// 拉取自上次调用以来新增的 16kHz 单声道 PCM 样本与实时音浪振幅
  static Future<RealtimeAudioPollData?> pollRealtimeAudio() async {
    if (!isWindowsNativeSupported) return null;
    try {
      final res = await _channel.invokeMethod<dynamic>('pollRealtimeAudio');
      if (res is Map) {
        final rawBytes = res['pcmBytes'];
        Uint8List bytes = Uint8List(0);
        if (rawBytes is Uint8List) {
          bytes = rawBytes;
        } else if (rawBytes is List<int>) {
          bytes = Uint8List.fromList(rawBytes);
        }
        final amp = (res['amplitude'] as num?)?.toDouble() ?? 0.0;
        final isRec = res['isRecording'] == true;
        return RealtimeAudioPollData(
          pcm16kMonoBytes: bytes,
          amplitude: amp,
          isRecording: isRec,
        );
      }
    } catch (e) {
      debugPrint('[NativeAudioBridge] 轮询实时音频流异常: $e');
    }
    return null;
  }
}
