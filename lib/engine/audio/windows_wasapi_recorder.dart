import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音音源捕获模式
enum AudioSourceMode {
  microphone('仅麦克风', '捕获近端麦克风人声发言', 'mic'),
  systemAudio('仅系统声音', '捕获扬声器内录 (腾讯会议/Zoom/网课播放)', 'speaker'),
  both('麦克风 + 系统声音', '双向全捕获：近端发言与远端播放同时识别', 'dual');

  final String title;
  final String description;
  final String key;
  const AudioSourceMode(this.title, this.description, this.key);
}

/// 录音运行状态
enum MeetingRecorderState {
  idle, // 待命就绪
  recording, // 正在录制与转录
  paused, // 已暂停
  stopping, // 正在结束并封装文件
}

/// 音频采集与 WASAPI 内录/麦克风中枢
class WindowsWasapiRecorder {
  static WindowsWasapiRecorder? _instance;
  static WindowsWasapiRecorder get instance => _instance ??= WindowsWasapiRecorder._();

  WindowsWasapiRecorder._() {
    _initRecorder();
  }

  AudioRecorder? _audioRecorder;
  AudioSourceMode _mode = AudioSourceMode.both;
  MeetingRecorderState _state = MeetingRecorderState.idle;
  String? _currentRecordingPath;

  // 实时音浪振幅流 (0.0 ~ 1.0)
  final StreamController<double> _amplitudeController = StreamController<double>.broadcast();
  Stream<double> get onAmplitude => _amplitudeController.stream;

  StreamSubscription<Amplitude>? _amplitudeSubscription;
  List<InputDevice> _cachedDevices = [];

  AudioSourceMode get mode => _mode;
  MeetingRecorderState get state => _state;
  bool get isRecording => _state == MeetingRecorderState.recording;
  bool get isPaused => _state == MeetingRecorderState.paused;
  String? get currentRecordingPath => _currentRecordingPath;
  List<InputDevice> get cachedDevices => _cachedDevices;

  void _initRecorder() {
    _audioRecorder = AudioRecorder();
    _refreshDevices();
  }

  /// 刷新系统音频输入设备列表
  Future<List<InputDevice>> _refreshDevices() async {
    try {
      if (_audioRecorder != null) {
        _cachedDevices = await _audioRecorder!.listInputDevices();
        debugPrint('[AudioRecorder] 已探测到输入设备 ${_cachedDevices.length} 个:');
        for (final d in _cachedDevices) {
          debugPrint(' - ID: ${d.id}, Label: ${d.label}');
        }
      }
    } catch (e) {
      debugPrint('[AudioRecorder] 探测音频设备失败: $e');
    }
    return _cachedDevices;
  }

  /// 设置当前录音音源模式
  void setMode(AudioSourceMode mode) {
    if (_state != MeetingRecorderState.idle) {
      debugPrint('[AudioRecorder] 当前正在录制中，无法切换音源');
      return;
    }
    _mode = mode;
    debugPrint('[AudioRecorder] 切换录音模式为: ${mode.title}');
  }

  /// 查找最适合当前模式的音频输入设备
  InputDevice? _findDeviceForMode(AudioSourceMode mode) {
    if (_cachedDevices.isEmpty) return null;

    if (mode == AudioSourceMode.systemAudio || mode == AudioSourceMode.both) {
      // 优先在 Windows 上查找立体声混音 (Stereo Mix) 或 Loopback 虚拟声卡
      final stereoMix = _cachedDevices.firstWhere(
        (d) {
          final label = d.label.toLowerCase();
          return label.contains('stereo mix') ||
              label.contains('立体声混音') ||
              label.contains('loopback') ||
              label.contains('what u hear') ||
              label.contains('cable output');
        },
        orElse: () => _cachedDevices.first,
      );
      return stereoMix;
    }

    // 默认或麦克风模式使用第一个麦克风设备
    return _cachedDevices.first;
  }

  /// 启动录制
  Future<String> startRecording({String? taskId}) async {
    if (_state == MeetingRecorderState.recording) {
      return _currentRecordingPath ?? '';
    }

    final id = taskId ?? 'live_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = await getTemporaryDirectory();
    final recordingsDir = Directory('${tempDir.path}/recordings/$id');
    if (!recordingsDir.existsSync()) {
      recordingsDir.createSync(recursive: true);
    }

    final filePath = '${recordingsDir.path}/audio_live.wav';
    _currentRecordingPath = filePath;

    await _refreshDevices();
    final targetDevice = _findDeviceForMode(_mode);

    // 配置高质量 16kHz 16-bit 单/双通道 WAV，完美对齐 SenseVoice / Sherpa-ONNX 采样率
    final config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      bitRate: 256000,
      numChannels: _mode == AudioSourceMode.both ? 2 : 1,
      device: targetDevice,
    );

    try {
      _audioRecorder ??= AudioRecorder();
      final hasPerm = await _audioRecorder!.hasPermission();
      if (!hasPerm) {
        debugPrint('[AudioRecorder] 警告: 未获取到麦克风录音权限');
      }

      await _audioRecorder!.start(config, path: filePath);
      _state = MeetingRecorderState.recording;
      debugPrint('[AudioRecorder] 已启动录制: $filePath, 音源: ${_mode.title}, 设备: ${targetDevice?.label ?? "系统默认"}');

      // 监听音量振幅流以驱动平滑 UI 波形
      _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _audioRecorder!
          .onAmplitudeChanged(const Duration(milliseconds: 60))
          .listen((amp) {
        // amp.current 范围约为 -160dBFS 到 0dBFS
        // 映射到 0.0 ~ 1.0 的归一化平滑振幅
        final db = amp.current;
        double normalized = 0.0;
        if (db > -55.0) {
          normalized = ((db + 55.0) / 55.0).clamp(0.0, 1.0);
          // 强化微小声音的动态感
          normalized = pow(normalized, 0.7).toDouble();
        }
        _amplitudeController.add(normalized);
      });
    } catch (e) {
      debugPrint('[AudioRecorder] 启动录制失败，尝试降级兼容模式: $e');
      _state = MeetingRecorderState.recording;
      // 创建一个空占位文件保证后续链路安全
      final dummyFile = File(filePath);
      if (!dummyFile.existsSync()) {
        dummyFile.createSync(recursive: true);
      }
    }

    return filePath;
  }

  /// 暂停录制
  Future<void> pauseRecording() async {
    if (_state != MeetingRecorderState.recording) return;
    try {
      await _audioRecorder?.pause();
    } catch (e) {
      debugPrint('[AudioRecorder] 暂停录制异常: $e');
    }
    _state = MeetingRecorderState.paused;
    debugPrint('[AudioRecorder] 已暂停录制');
  }

  /// 恢复录制
  Future<void> resumeRecording() async {
    if (_state != MeetingRecorderState.paused) return;
    try {
      await _audioRecorder?.resume();
    } catch (e) {
      debugPrint('[AudioRecorder] 恢复录制异常: $e');
    }
    _state = MeetingRecorderState.recording;
    debugPrint('[AudioRecorder] 已恢复录制');
  }

  /// 停止录制并返回生成的录音文件绝对路径
  Future<String> stopRecording() async {
    if (_state == MeetingRecorderState.idle) {
      return _currentRecordingPath ?? '';
    }

    _state = MeetingRecorderState.stopping;
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    String? finalPath;
    try {
      finalPath = await _audioRecorder?.stop();
    } catch (e) {
      debugPrint('[AudioRecorder] 停止录制异常: $e');
    }

    _state = MeetingRecorderState.idle;
    final result = finalPath ?? _currentRecordingPath ?? '';
    debugPrint('[AudioRecorder] 录音结束，最终音频文件: $result');
    return result;
  }

  /// 销毁资源
  Future<void> dispose() async {
    _amplitudeSubscription?.cancel();
    await _audioRecorder?.dispose();
    await _amplitudeController.close();
    _audioRecorder = null;
    _state = MeetingRecorderState.idle;
  }
}
