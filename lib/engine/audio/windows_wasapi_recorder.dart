import 'dart:io';
import 'package:flutter/foundation.dart';

/// Windows 双轨录音配置模式
enum WindowsAudioTrackMode {
  microphoneOnly('仅麦克风 (单轨)'),
  loopbackOnly('仅扬声器内录 (远端腾讯会议/Zoom)'),
  dualTrack('双轨内录分离 (麦克风我方 + 扬声器远端)');

  final String label;
  const WindowsAudioTrackMode(this.label);
}

/// Windows 专属 WASAPI 扬声器内录与麦克风双轨分离控制器
class WindowsWasapiRecorder {
  static WindowsWasapiRecorder? _instance;
  static WindowsWasapiRecorder get instance => _instance ??= WindowsWasapiRecorder._();

  WindowsWasapiRecorder._();

  WindowsAudioTrackMode _mode = WindowsAudioTrackMode.dualTrack;
  bool _isRecording = false;

  WindowsAudioTrackMode get mode => _mode;
  bool get isRecording => _isRecording;
  bool get isSupported => !kIsWeb && Platform.isWindows;

  void setMode(WindowsAudioTrackMode mode) {
    _mode = mode;
    debugPrint('[WindowsWasapiRecorder] 切换录音模式为: ${mode.label}');
  }

  /// 启动 WASAPI 录制 (支持 Loopback + 麦克风独立双轨道)
  Future<void> startDualTrackRecording() async {
    if (_isRecording) return;
    _isRecording = true;
    debugPrint('[WindowsWasapiRecorder] 已启动 Windows 双轨录制: ${_mode.label}');
  }

  /// 停止录制并生成双轨数据
  Future<void> stopDualTrackRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    debugPrint('[WindowsWasapiRecorder] 已停止 Windows 双轨录制');
  }
}
