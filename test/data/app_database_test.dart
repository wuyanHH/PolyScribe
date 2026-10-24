import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SQLite 内存数据库表与段落读写测试', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              source_type TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              duration_ms INTEGER DEFAULT 0,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE segments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              speaker_id TEXT NOT NULL,
              speaker_name TEXT,
              start_ms INTEGER NOT NULL,
              end_ms INTEGER NOT NULL,
              text TEXT NOT NULL,
              words_json TEXT
            )
          ''');
        },
      ),
    );

    // 插入任务
    final task = MeetingTask(
      id: 'task_001',
      title: '季度战略复盘会议',
      sourceType: TaskSourceType.liveMeeting,
      audioPath: '/recordings/001.wav',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert('tasks', task.toMap());

    // 插入段落
    final seg = TranscriptSegment(
      taskId: 'task_001',
      speakerId: 'SPK_01',
      speakerName: '张总',
      startMs: 1200,
      endMs: 3800,
      text: '我们必须在本季度实现端侧模型的离线全闭环。',
    );
    final segId = await db.insert('segments', seg.toMap());
    expect(segId, greaterThan(0));

    // 读取验证
    final queryTasks = await db.query('tasks', where: 'id = ?', whereArgs: ['task_001']);
    expect(queryTasks.length, 1);
    expect(queryTasks.first['title'], '季度战略复盘会议');

    final querySegs = await db.query('segments', where: 'task_id = ?', whereArgs: ['task_001']);
    expect(querySegs.length, 1);
    expect(querySegs.first['speaker_name'], '张总');

    await db.close();
  });

  test('FTS5 全文索引与参数清洗容错测试', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              source_type TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              duration_ms INTEGER DEFAULT 0,
              created_at INTEGER NOT NULL,
              status TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE segments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              speaker_id TEXT NOT NULL,
              speaker_name TEXT,
              start_ms INTEGER NOT NULL,
              end_ms INTEGER NOT NULL,
              text TEXT NOT NULL,
              words_json TEXT
            )
          ''');
          await db.execute('''
            CREATE VIRTUAL TABLE segments_fts USING fts5(
              text,
              task_id UNINDEXED,
              segment_id UNINDEXED
            )
          ''');
        },
      ),
    );

    // 插入测试段落
    final s1 = TranscriptSegment(
      taskId: 't_fts_1',
      speakerId: 'SPK_01',
      speakerName: '李架构师',
      startMs: 0,
      endMs: 3000,
      text: 'SenseVoice 离线语音识别在本地流畅运行。',
    );
    final id1 = await db.insert('segments', s1.toMap());
    await db.insert('segments_fts', {
      'rowid': id1,
      'text': s1.text,
      'task_id': s1.taskId,
      'segment_id': id1,
    });

    // 1. 验证带特殊字符 (如 * 号、双引号、括号) 不导致崩溃
    final dirtyQuery = '*"SenseVoice"*';
    final sanitized = dirtyQuery.replaceAll(RegExp(r'["\*\(\)\{\}\[\]\:\^\+\-\~]'), ' ').trim();
    expect(sanitized, 'SenseVoice');

    final ftsExpr = '"$sanitized"*';
    final ftsHits = await db.rawQuery(
      'SELECT segment_id FROM segments_fts WHERE text MATCH ? LIMIT 50',
      [ftsExpr],
    );
    expect(ftsHits, isNotEmpty);
    expect(ftsHits.first['segment_id'], id1);

    await db.close();
  });
}
