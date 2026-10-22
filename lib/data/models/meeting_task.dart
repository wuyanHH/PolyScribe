/// 会议任务来源类型
enum TaskSourceType {
  liveMeeting('live_meeting'),
  importedAudio('imported_audio');

  final String value;
  const TaskSourceType(this.value);

  static TaskSourceType fromString(String val) {
    return TaskSourceType.values.firstWhere(
      (e) => e.value == val,
      orElse: () => TaskSourceType.importedAudio,
    );
  }
}

/// 会议任务状态
enum TaskStatus {
  recording('recording'),
  queued('queued'),
  processing('processing'),
  completed('completed'),
  error('error');

  final String value;
  const TaskStatus(this.value);

  static TaskStatus fromString(String val) {
    return TaskStatus.values.firstWhere(
      (e) => e.value == val,
      orElse: () => TaskStatus.error,
    );
  }
}

/// 任务与会议主表实体 (对应 SQLite tasks 表)
class MeetingTask {
  final String id;
  final String title;
  final TaskSourceType sourceType;
  final String audioPath;
  final int durationMs;
  final int createdAt;
  final TaskStatus status;

  const MeetingTask({
    required this.id,
    required this.title,
    required this.sourceType,
    required this.audioPath,
    this.durationMs = 0,
    required this.createdAt,
    this.status = TaskStatus.queued,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'source_type': sourceType.value,
    'audio_path': audioPath,
    'duration_ms': durationMs,
    'created_at': createdAt,
    'status': status.value,
  };

  factory MeetingTask.fromMap(Map<String, dynamic> map) => MeetingTask(
    id: map['id'] as String,
    title: map['title'] as String,
    sourceType: TaskSourceType.fromString(map['source_type'] as String),
    audioPath: map['audio_path'] as String,
    durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
    createdAt: (map['created_at'] as num).toInt(),
    status: TaskStatus.fromString(map['status'] as String),
  );

  MeetingTask copyWith({
    String? id,
    String? title,
    TaskSourceType? sourceType,
    String? audioPath,
    int? durationMs,
    int? createdAt,
    TaskStatus? status,
  }) {
    return MeetingTask(
      id: id ?? this.id,
      title: title ?? this.title,
      sourceType: sourceType ?? this.sourceType,
      audioPath: audioPath ?? this.audioPath,
      durationMs: durationMs ?? this.durationMs,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
    );
  }
}
