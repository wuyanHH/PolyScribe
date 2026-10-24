import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'native_audio_bridge.dart';
import 'wav_codec.dart';

/// 录音音源捕获模式
enum AudioSourceMode {
  microphone('仅麦克风', '捕获近端麦克风人声发言', 'mic'),
  systemAudio('仅系统声音', '捕获扬声器/耳机内录 (外放/耳机/静音均支持)', 'speaker'),
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

/// 音频采集中枢 (Windows 原生 WASAPI Process/Endpoint Loopback + 移动端流式 PCM 引擎)
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
  bool _usingWindowsNativeEngine = false;

  // 实时音浪振幅流 (0.0 ~ 1.0)
  final StreamController<double> _amplitudeController = StreamController<double>.broadcast();
  Stream<double> get onAmplitude => _amplitudeController.stream;

  Timer? _nativePollTimer;
  bool _isPollingNative = false;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Uint8List>? _pcmStreamSubscription;
  List<InputDevice> _cachedDevices = [];

  // 实时待转写的 16kHz 单声道浮点样本队列 (由原生引擎或 PCM 流直接推入，零磁盘锁竞争)
  final List<Float32List> _pendingSampleChunks = [];
  int _pendingSampleCount = 0;

  // 移动端流式录音磁盘直写句柄与字节计数 (彻底消除内存中堆积全量录音样本导致的手机端 OOM)
  RandomAccessFile? _mobileWavRaf;
  int _mobileRecordedDataBytes = 0;
  int? _oddByteRemainder;

  AudioSourceMode get mode => _mode;
  MeetingRecorderState get state => _state;
  bool get isRecording => _state == MeetingRecorderState.recording;
  bool get isPaused => _state == MeetingRecorderState.paused;
  String? get currentRecordingPath => _currentRecordingPath;
  List<InputDevice> get cachedDevices => _cachedDevices;
  int get availableRealtimeSamples => _pendingSampleCount;

  void _initRecorder() {
    if (!NativeAudioBridge.isWindowsNativeSupported) {
      _audioRecorder = AudioRecorder();
      _refreshDevices();
    }
  }

  /// 刷新系统音频输入设备列表
  Future<List<InputDevice>> _refreshDevices() async {
    if (NativeAudioBridge.isWindowsNativeSupported) {
      return _cachedDevices;
    }
    try {
      if (_audioRecorder != null) {
        _cachedDevices = await _audioRecorder!.listInputDevices();
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

  /// 取出当前已累积的 16kHz 单声道 Float32 音频样本并清空待处理队列
  Float32List consumePendingSamples16k() {
    if (_pendingSampleChunks.isEmpty || _pendingSampleCount == 0) {
      return Float32List(0);
    }
    final result = Float32List(_pendingSampleCount);
    int offset = 0;
    for (final chunk in _pendingSampleChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _pendingSampleChunks.clear();
    _pendingSampleCount = 0;
    return result;
  }

  void _appendPcm16BytesToPending(Uint8List rawBytes, {bool recordForMobileFile = false}) {
    if (rawBytes.isEmpty) return;

    Uint8List alignedBytes = rawBytes;
    if (recordForMobileFile) {
      if (_oddByteRemainder != null) {
        final merged = Uint8List(rawBytes.length + 1);
        merged[0] = _oddByteRemainder!;
        merged.setRange(1, merged.length, rawBytes);
        alignedBytes = merged;
        _oddByteRemainder = null;
      }
      if (alignedBytes.length.isOdd) {
        _oddByteRemainder = alignedBytes.last;
        alignedBytes = Uint8List.sublistView(alignedBytes, 0, alignedBytes.length - 1);
      }
    }

    if (alignedBytes.length < 2) return;
    final sampleCount = alignedBytes.length ~/ 2;
    final floats = Float32List(sampleCount);
    final bd = ByteData.sublistView(alignedBytes);
    for (int i = 0; i < sampleCount; i++) {
      floats[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _pendingSampleChunks.add(floats);
    _pendingSampleCount += floats.length;

    // 防止极端情况下未消费导致内存无限累积 (最多保留最近 45 秒样本)
    while (_pendingSampleCount > 16000 * 45 && _pendingSampleChunks.isNotEmpty) {
      final removed = _pendingSampleChunks.removeAt(0);
      _pendingSampleCount -= removed.length;
    }

    // 移动端实时流式直写磁盘，不在内存中驻留整场会议的音频数据
    if (recordForMobileFile && _mobileWavRaf != null) {
      try {
        _mobileWavRaf!.writeFromSync(alignedBytes);
        _mobileRecordedDataBytes += alignedBytes.length;
      } catch (e) {
        debugPrint('[AudioRecorder] 移动端流式写入 WAV 块异常: $e');
      }
    }
  }

  /// 构建标准 16kHz 16-bit 单声道 WAV 44 字节文件头
  Uint8List _buildWavHeader16kMono(int dataByteCount) {
    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + dataByteCount, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6d); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM = 1
    header.setUint16(22, 1, Endian.little); // 1 channel
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little); // byteRate = 16000 * 2
    header.setUint16(32, 2, Endian.little); // blockAlign = 2
    header.setUint16(34, 16, Endian.little); // bitsPerSample = 16
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataByteCount, Endian.little);
    return header.buffer.asUint8List();
  }

  /// 关闭并回填移动端流式 WAV 头部
  Future<void> _finalizeMobileWavFile() async {
    final raf = _mobileWavRaf;
    _mobileWavRaf = null;
    if (raf == null) return;
    try {
      await raf.setPosition(0);
      await raf.writeFrom(_buildWavHeader16kMono(_mobileRecordedDataBytes));
      await raf.flush();
    } catch (e) {
      debugPrint('[AudioRecorder] 回填移动端 WAV 头部异常: $e');
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// 启动录制
  Future<String> startRecording({String? taskId}) async {
    if (_state == MeetingRecorderState.recording) {
      return _currentRecordingPath ?? '';
    }

    _pendingSampleChunks.clear();
    _pendingSampleCount = 0;
    _mobileRecordedDataBytes = 0;
    _oddByteRemainder = null;
    await _finalizeMobileWavFile();

    final id = taskId ?? 'live_${DateTime.now().millisecondsSinceEpoch}';
    Directory baseDir;
    try {
      baseDir = await getApplicationSupportDirectory();
    } catch (_) {
      baseDir = await getTemporaryDirectory();
    }

    final recordingsDir = Directory(p.join(baseDir.path, 'recordings', id));
    if (!recordingsDir.existsSync()) {
      recordingsDir.createSync(recursive: true);
    }

    final filePath = p.join(recordingsDir.path, 'audio_live.wav');
    _currentRecordingPath = filePath;

    // 1. Windows 桌面端：直接启用 C++ 原生 WASAPI 双保险内录 (Process Loopback + Endpoint Loopback) 与麦克风引擎
    if (NativeAudioBridge.isWindowsNativeSupported) {
      final started = await NativeAudioBridge.startRecording(
        filePath: filePath,
        mode: _mode.key,
      );
      if (started) {
        _usingWindowsNativeEngine = true;
        _state = MeetingRecorderState.recording;
        debugPrint('[AudioRecorder] Windows 原生 WASAPI 引擎已启动: $filePath, 模式: ${_mode.title}');

        _nativePollTimer?.cancel();
        _nativePollTimer = Timer.periodic(const Duration(milliseconds: 60), (_) async {
          if (_isPollingNative || _state != MeetingRecorderState.recording) return;
          _isPollingNative = true;
          try {
            final pollData = await NativeAudioBridge.pollRealtimeAudio();
            if (pollData != null) {
              _amplitudeController.add(pollData.amplitude);
              if (pollData.pcm16kMonoBytes.isNotEmpty) {
                _appendPcm16BytesToPending(pollData.pcm16kMonoBytes);
              }
            }
          } finally {
            _isPollingNative = false;
          }
        });
        return filePath;
      }
    }

    // 2. 移动端 (Android / iOS) 或回退模式：采用 PCM 16kHz 流式采集并实时直写磁盘 WAV
    _usingWindowsNativeEngine = false;
    try {
      _audioRecorder ??= AudioRecorder();
      final hasPerm = await _audioRecorder!.hasPermission();
      if (!hasPerm) {
        debugPrint('[AudioRecorder] 警告: 未获取到麦克风录音权限，拒绝启动录音');
        _state = MeetingRecorderState.idle;
        return '';
      }

      // 预先打开目标 WAV 文件并写入 44 字节占位头
      final wavFile = File(filePath);
      if (wavFile.existsSync()) {
        await wavFile.delete();
      }
      _mobileWavRaf = await wavFile.open(mode: FileMode.write);
      await _mobileWavRaf!.writeFrom(_buildWavHeader16kMono(0));

      const streamConfig = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      );

      final pcmStream = await _audioRecorder!.startStream(streamConfig);
      _state = MeetingRecorderState.recording;
      debugPrint('[AudioRecorder] 已启动流式 PCM 录制并直写磁盘: $filePath');

      _pcmStreamSubscription?.cancel();
      _pcmStreamSubscription = pcmStream.listen((chunkBytes) {
        if (_state == MeetingRecorderState.recording && chunkBytes.isNotEmpty) {
          _appendPcm16BytesToPending(chunkBytes, recordForMobileFile: true);
        }
      });

      _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _audioRecorder!
          .onAmplitudeChanged(const Duration(milliseconds: 60))
          .listen((amp) {
        final db = amp.current;
        double normalized = 0.0;
        if (db > -55.0) {
          normalized = ((db + 55.0) / 55.0).clamp(0.0, 1.0);
          normalized = pow(normalized, 0.7).toDouble();
        }
        _amplitudeController.add(normalized);
      });
    } catch (e) {
      debugPrint('[AudioRecorder] 启动录制失败，启用安全兜底占位: $e');
      await _finalizeMobileWavFile();
      _state = MeetingRecorderState.recording;
      await WavCodec.writeMono16kWavFile(filePath, Float32List(0));
    }

    return filePath;
  }

  /// 暂停录制
  Future<void> pauseRecording() async {
    if (_state != MeetingRecorderState.recording) return;
    if (_usingWindowsNativeEngine) {
      await NativeAudioBridge.pauseRecording();
    } else {
      try {
        await _audioRecorder?.pause();
      } catch (e) {
        debugPrint('[AudioRecorder] 暂停录制异常: $e');
      }
    }
    _state = MeetingRecorderState.paused;
    debugPrint('[AudioRecorder] 已暂停录制');
  }

  /// 恢复录制
  Future<void> resumeRecording() async {
    if (_state != MeetingRecorderState.paused) return;
    if (_usingWindowsNativeEngine) {
      await NativeAudioBridge.resumeRecording();
    } else {
      try {
        await _audioRecorder?.resume();
      } catch (e) {
        debugPrint('[AudioRecorder] 恢复录制异常: $e');
      }
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
    _nativePollTimer?.cancel();
    _nativePollTimer = null;
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _pcmStreamSubscription?.cancel();
    _pcmStreamSubscription = null;

    String? finalPath;
    if (_usingWindowsNativeEngine) {
      // 拉取最后一次残余缓冲样本
      final lastPoll = await NativeAudioBridge.pollRealtimeAudio();
      if (lastPoll != null && lastPoll.pcm16kMonoBytes.isNotEmpty) {
        _appendPcm16BytesToPending(lastPoll.pcm16kMonoBytes);
      }
      finalPath = await NativeAudioBridge.stopRecording();
    } else {
      try {
        await _audioRecorder?.stop();
      } catch (e) {
        debugPrint('[AudioRecorder] 停止录制异常: $e');
      }

      // 回填移动端流式直写的 WAV 文件头部并关闭句柄
      await _finalizeMobileWavFile();
      if (_currentRecordingPath != null) {
        finalPath = _currentRecordingPath;
      }
    }

    _state = MeetingRecorderState.idle;
    final result = (finalPath != null && finalPath.isNotEmpty)
        ? finalPath
        : (_currentRecordingPath ?? '');
    debugPrint('[AudioRecorder] 录音结束，最终音频文件: $result');
    return result;
  }

  /// 销毁资源
  Future<void> dispose() async {
    _nativePollTimer?.cancel();
    _amplitudeSubscription?.cancel();
    await _pcmStreamSubscription?.cancel();
    await _finalizeMobileWavFile();
    if (_usingWindowsNativeEngine) {
      await NativeAudioBridge.stopRecording();
    }
    await _audioRecorder?.dispose();
    await _amplitudeController.close();
    _audioRecorder = null;
    _state = MeetingRecorderState.idle;
  }
}
