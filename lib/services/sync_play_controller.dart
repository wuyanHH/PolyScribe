import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import '../core/utils/binary_search_util.dart';
import '../data/models/transcript_segment.dart';

/// 音字同步播放控制器状态
class SyncPlayerState {
  final PlayerState playerState;
  final int positionMs;
  final int durationMs;
  final int activeSegmentIndex;
  final double playbackRate;
  final bool isUserTouching;

  const SyncPlayerState({
    required this.playerState,
    required this.positionMs,
    required this.durationMs,
    required this.activeSegmentIndex,
    this.playbackRate = 1.0,
    this.isUserTouching = false,
  });

  bool get isPlaying => playerState == PlayerState.playing;

  SyncPlayerState copyWith({
    PlayerState? playerState,
    int? positionMs,
    int? durationMs,
    int? activeSegmentIndex,
    double? playbackRate,
    bool? isUserTouching,
  }) {
    return SyncPlayerState(
      playerState: playerState ?? this.playerState,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      activeSegmentIndex: activeSegmentIndex ?? this.activeSegmentIndex,
      playbackRate: playbackRate ?? this.playbackRate,
      isUserTouching: isUserTouching ?? this.isUserTouching,
    );
  }
}

/// 音字同步播放调度控制器
class SyncPlayController extends ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final List<TranscriptSegment> _segments = [];
  bool _isAudioAvailable = false;

  bool get isAudioAvailable => _isAudioAvailable;

  SyncPlayerState _state = const SyncPlayerState(
    playerState: PlayerState.stopped,
    positionMs: 0,
    durationMs: 0,
    activeSegmentIndex: -1,
  );

  SyncPlayerState get state => _state;
  List<TranscriptSegment> get segments => List.unmodifiable(_segments);

  StreamSubscription? _posSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _stateSub;

  SyncPlayController() {
    _initSubscriptions();
  }

  void _initSubscriptions() {
    _stateSub = _audioPlayer.onPlayerStateChanged.listen((pState) {
      _state = _state.copyWith(playerState: pState);
      notifyListeners();
    });

    _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
      _state = _state.copyWith(durationMs: dur.inMilliseconds);
      notifyListeners();
    });

    _posSub = _audioPlayer.onPositionChanged.listen((pos) {
      final posMs = pos.inMilliseconds;
      final activeIndex = BinarySearchUtil.findActiveIndex(_segments, posMs);

      if (_state.positionMs != posMs || _state.activeSegmentIndex != activeIndex) {
        _state = _state.copyWith(
          positionMs: posMs,
          activeSegmentIndex: activeIndex,
        );
        notifyListeners();
      }
    });
  }

  /// 加载任务与其分段
  void loadTask({
    required String audioPath,
    required List<TranscriptSegment> segments,
  }) {
    _segments.clear();
    _segments.addAll(segments);
    // 按起始时间排序
    _segments.sort((a, b) => a.startMs.compareTo(b.startMs));

    final totalDuration = segments.isNotEmpty ? segments.last.endMs : 0;
    _state = _state.copyWith(
      durationMs: totalDuration,
      positionMs: 0,
      activeSegmentIndex: _segments.isNotEmpty ? 0 : -1,
    );

    // 检查本地物理音频是否存在 (若已删除则进入离线纯纪要模式)
    final file = File(audioPath);
    if (audioPath.isNotEmpty && file.existsSync()) {
      try {
        _isAudioAvailable = true;
        _audioPlayer.setSource(DeviceFileSource(audioPath));
      } catch (e) {
        debugPrint('[SyncPlayController] 设置音频源失败: $e');
        _isAudioAvailable = false;
      }
    } else {
      _isAudioAvailable = false;
      debugPrint('[SyncPlayController] 音频源文件不存在，启动纯纪要阅读降级模式: $audioPath');
    }

    notifyListeners();
  }

  /// 纯内存无感更新指定角色的显示姓名 (绝不重置音频源与播放器，零延迟即时响应)
  void updateSpeakerName(String speakerId, String newSpeakerName) {
    bool hasChanged = false;
    for (int i = 0; i < _segments.length; i++) {
      if (_segments[i].speakerId == speakerId) {
        _segments[i] = _segments[i].copyWith(speakerName: newSpeakerName);
        hasChanged = true;
      }
    }
    if (hasChanged) {
      notifyListeners();
    }
  }

  /// 纯内存更新段落列表 (用于上下文整合优化或校对，保留当前音频播放状态与位置)
  void updateSegments(List<TranscriptSegment> newSegments) {
    _segments.clear();
    _segments.addAll(newSegments);
    _segments.sort((a, b) => a.startMs.compareTo(b.startMs));

    final totalDuration = _segments.isNotEmpty ? _segments.last.endMs : 0;
    final activeIndex = BinarySearchUtil.findActiveIndex(_segments, _state.positionMs);

    _state = _state.copyWith(
      durationMs: totalDuration > _state.durationMs ? totalDuration : _state.durationMs,
      activeSegmentIndex: activeIndex,
    );
    notifyListeners();
  }

  /// 纯内存更新单条段落文本
  void updateSegmentText(int segmentId, String newText) {
    final idx = _segments.indexWhere((s) => s.id == segmentId);
    if (idx >= 0) {
      _segments[idx] = _segments[idx].copyWith(text: newText);
      notifyListeners();
    }
  }

  /// 播放/暂停切换
  Future<void> togglePlay() async {
    if (!_isAudioAvailable) return;
    if (_state.isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
  }

  /// 明确暂停播放
  Future<void> pause() async {
    if (!_isAudioAvailable) return;
    if (_state.isPlaying) {
      await _audioPlayer.pause();
    }
  }

  /// 停止播放并复位
  Future<void> stop() async {
    if (!_isAudioAvailable) return;
    await _audioPlayer.stop();
  }

  /// 跳转至指定毫秒时间戳 (Seek)
  Future<void> seek(int targetMs) async {
    final clamped = targetMs.clamp(0, _state.durationMs > 0 ? _state.durationMs : targetMs);
    if (_isAudioAvailable) {
      try {
        await _audioPlayer.seek(Duration(milliseconds: clamped));
      } catch (e) {
        debugPrint('[SyncPlayController] Seek 异常: $e');
      }
    }
    final activeIndex = BinarySearchUtil.findActiveIndex(_segments, clamped);
    _state = _state.copyWith(
      positionMs: clamped,
      activeSegmentIndex: activeIndex,
    );
    notifyListeners();
  }

  /// 跳转到特定段落发音起点
  Future<void> seekToSegment(int segmentIndex) async {
    if (segmentIndex < 0 || segmentIndex >= _segments.length) return;
    await seek(_segments[segmentIndex].startMs);
  }

  /// 调整播放倍速
  Future<void> setPlaybackRate(double rate) async {
    await _audioPlayer.setPlaybackRate(rate);
    _state = _state.copyWith(playbackRate: rate);
    notifyListeners();
  }

  /// 用户开始/结束手动滚动 (防止播放滚动动画抢占)
  void setUserTouching(bool isTouching) {
    if (_state.isUserTouching != isTouching) {
      _state = _state.copyWith(isUserTouching: isTouching);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}
