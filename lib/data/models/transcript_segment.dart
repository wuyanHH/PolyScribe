import 'dart:convert';
import '../../core/utils/binary_search_util.dart';

/// 单个词/字级别的时间戳单元
class WordTimestamp implements TimeRanged {
  final String word;
  @override
  final int startMs;
  @override
  final int endMs;

  const WordTimestamp({
    required this.word,
    required this.startMs,
    required this.endMs,
  });

  Map<String, dynamic> toMap() => {
    'w': word,
    's': startMs,
    'e': endMs,
  };

  factory WordTimestamp.fromMap(Map<String, dynamic> map) => WordTimestamp(
    word: map['w'] as String? ?? '',
    startMs: (map['s'] as num?)?.toInt() ?? 0,
    endMs: (map['e'] as num?)?.toInt() ?? 0,
  );
}

/// 转写段落实体 (对应 SQLite segments 表)
class TranscriptSegment implements TimeRanged {
  final int? id;
  final String taskId;
  final String speakerId;
  final String? speakerName;
  @override
  final int startMs;
  @override
  final int endMs;
  final String text;
  final List<WordTimestamp> words;

  const TranscriptSegment({
    this.id,
    required this.taskId,
    required this.speakerId,
    this.speakerName,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'task_id': taskId,
    'speaker_id': speakerId,
    'speaker_name': speakerName,
    'start_ms': startMs,
    'end_ms': endMs,
    'text': text,
    'words_json': jsonEncode(words.map((w) => w.toMap()).toList()),
  };

  factory TranscriptSegment.fromMap(Map<String, dynamic> map) {
    List<WordTimestamp> parsedWords = [];
    final wordsJsonStr = map['words_json'] as String?;
    if (wordsJsonStr != null && wordsJsonStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(wordsJsonStr) as List<dynamic>;
        parsedWords = decoded
            .map((e) => WordTimestamp.fromMap(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    return TranscriptSegment(
      id: map['id'] as int?,
      taskId: map['task_id'] as String,
      speakerId: map['speaker_id'] as String,
      speakerName: map['speaker_name'] as String?,
      startMs: (map['start_ms'] as num).toInt(),
      endMs: (map['end_ms'] as num).toInt(),
      text: map['text'] as String,
      words: parsedWords,
    );
  }

  TranscriptSegment copyWith({
    int? id,
    String? taskId,
    String? speakerId,
    String? speakerName,
    int? startMs,
    int? endMs,
    String? text,
    List<WordTimestamp>? words,
  }) {
    return TranscriptSegment(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      speakerId: speakerId ?? this.speakerId,
      speakerName: speakerName ?? this.speakerName,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      text: text ?? this.text,
      words: words ?? this.words,
    );
  }
}
