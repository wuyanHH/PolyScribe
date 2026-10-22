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
}
