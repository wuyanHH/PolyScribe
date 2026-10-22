import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/meeting_task.dart';
import '../models/transcript_segment.dart';
import '../models/voice_print.dart';

/// SQLite + FTS5 全文检索数据库服务
class AppDatabase {
  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase._();

  Database? _db;

  AppDatabase._();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    // 桌面端 (Windows, Linux, macOS) 初始化 FFI 驱动
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dbDir.path, 'polyscribe.db');
    debugPrint('[AppDatabase] 数据库物理路径: $dbPath');

    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        // 1. 任务主表
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

        // 2. 转写段落明细表
        await db.execute('''
          CREATE TABLE segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            speaker_id TEXT NOT NULL,
            speaker_name TEXT,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            words_json TEXT,
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX idx_segments_task_time ON segments(task_id, start_ms)');

        // 3. FTS5 全文检索引擎虚拟表
        try {
          await db.execute('''
            CREATE VIRTUAL TABLE segments_fts USING fts5(
              text,
              task_id UNINDEXED,
              segment_id UNINDEXED
            )
          ''');
        } catch (e) {
          debugPrint('[AppDatabase] FTS5 初始化警告 (可能环境不支持 FTS5): $e');
        }

        // 4. 实名声纹库表
        await db.execute('''
          CREATE TABLE voice_prints (
            id TEXT PRIMARY KEY,
            person_name TEXT NOT NULL,
            embedding BLOB NOT NULL,
            sample_count INTEGER DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  /// 插入或更新任务
  Future<void> saveTask(MeetingTask task) async {
    final db = await database;
    await db.insert(
      'tasks',
      task.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 查询单个任务
  Future<MeetingTask?> getTask(String taskId) async {
    final db = await database;
    final results = await db.query(
      'tasks',
      where: 'id = ?',
      whereArgs: [taskId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return MeetingTask.fromMap(results.first);
  }

  /// 获取任务列表
  Future<List<MeetingTask>> getAllTasks() async {
    final db = await database;
    final results = await db.query('tasks', orderBy: 'created_at DESC');
    return results.map((e) => MeetingTask.fromMap(e)).toList();
  }

  /// 插入段落并同步写入全文索引
  Future<int> insertSegment(TranscriptSegment segment) async {
    final db = await database;
    final id = await db.insert('segments', segment.toMap());

    try {
      await db.insert('segments_fts', {
        'rowid': id,
        'text': segment.text,
        'task_id': segment.taskId,
        'segment_id': id,
      });
    } catch (_) {}

    return id;
  }

  /// 获取指定任务的所有段落 (按时间戳排序)
  Future<List<TranscriptSegment>> getSegmentsForTask(String taskId) async {
    final db = await database;
    final results = await db.query(
      'segments',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'start_ms ASC',
    );
    return results.map((e) => TranscriptSegment.fromMap(e)).toList();
  }

  /// 全文检索关键词
  Future<List<TranscriptSegment>> searchSegments(String query) async {
    final db = await database;
    try {
      final ftsResults = await db.rawQuery(
        'SELECT segment_id FROM segments_fts WHERE text MATCH ? LIMIT 50',
        ['*$query*'],
      );
      if (ftsResults.isEmpty) return [];

      final ids = ftsResults.map((r) => r['segment_id']).toList();
      final inClause = List.filled(ids.length, '?').join(',');
      final segmentResults = await db.query(
        'segments',
        where: 'id IN ($inClause)',
        whereArgs: ids,
        orderBy: 'start_ms ASC',
      );
      return segmentResults.map((e) => TranscriptSegment.fromMap(e)).toList();
    } catch (_) {
      // 降级为 LIKE 模糊搜索
      final likeResults = await db.query(
        'segments',
        where: 'text LIKE ?',
        whereArgs: ['%$query%'],
        orderBy: 'start_ms ASC',
        limit: 50,
      );
      return likeResults.map((e) => TranscriptSegment.fromMap(e)).toList();
    }
  }

  /// 保存声纹
  Future<void> saveVoicePrint(VoicePrint print) async {
    final db = await database;
    await db.insert(
      'voice_prints',
      print.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取所有实名声纹
  Future<List<VoicePrint>> getAllVoicePrints() async {
    final db = await database;
    final results = await db.query('voice_prints');
    return results.map((e) => VoicePrint.fromMap(e)).toList();
  }

  /// 关闭数据库
  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
      _db = null;
    }
  }
}
