import 'dart:async';
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

  /// 数据库变更全局广播流 (驱动各页面响应式无感刷新)
  final StreamController<void> _changeController = StreamController<void>.broadcast();
  Stream<void> get onDatabaseChanged => _changeController.stream;

  void notifyDatabaseChanged() {
    if (!_changeController.isClosed) {
      _changeController.add(null);
    }
  }

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

  /// 读取系统通用键值设置
  Future<String?> getSetting(String key) async {
    final db = await database;
    await db.execute('CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    final rows = await db.query('app_settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isNotEmpty) {
      return rows.first['value'] as String?;
    }
    return null;
  }

  /// 写入系统通用键值设置
  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.execute('CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
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
    notifyDatabaseChanged();
  }

  /// 更新任务标题
  Future<void> updateTaskTitle(String taskId, String newTitle) async {
    final db = await database;
    await db.update(
      'tasks',
      {'title': newTitle},
      where: 'id = ?',
      whereArgs: [taskId],
    );
    notifyDatabaseChanged();
  }

  /// 批量更新指定任务下某角色 (speakerId) 的显示姓名
  Future<void> updateSpeakerNameForTask(
    String taskId,
    String speakerId,
    String newSpeakerName,
  ) async {
    final db = await database;
    await db.update(
      'segments',
      {'speaker_name': newSpeakerName},
      where: 'task_id = ? AND speaker_id = ?',
      whereArgs: [taskId, speakerId],
    );
    notifyDatabaseChanged();
  }

  /// 更新单条转写段落文本并同步 FTS5 索引
  Future<void> updateSegmentText(int segmentId, String taskId, String newText) async {
    final db = await database;
    await db.update(
      'segments',
      {'text': newText},
      where: 'id = ?',
      whereArgs: [segmentId],
    );
    try {
      await db.update(
        'segments_fts',
        {'text': newText},
        where: 'segment_id = ?',
        whereArgs: [segmentId],
      );
    } catch (_) {}
    notifyDatabaseChanged();
  }

  /// 清除指定任务关联的所有旧转写段落与 FTS5 索引 (用于重新转写任务)
  Future<void> clearSegmentsForTask(String taskId) async {
    final db = await database;
    try {
      await db.delete(
        'segments_fts',
        where: 'task_id = ?',
        whereArgs: [taskId],
      );
    } catch (_) {}

    await db.delete(
      'segments',
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
    notifyDatabaseChanged();
  }

  /// 事务内原子性替换指定任务的所有段落 (用于上下文智能优化整合或全文批量清洗)
  Future<List<TranscriptSegment>> replaceSegmentsForTask(
    String taskId,
    List<TranscriptSegment> newSegments,
  ) async {
    final db = await database;
    final List<TranscriptSegment> savedList = [];

    await db.transaction((txn) async {
      // 1. 清理旧数据与 FTS5 索引
      try {
        await txn.delete(
          'segments_fts',
          where: 'task_id = ?',
          whereArgs: [taskId],
        );
      } catch (_) {}

      await txn.delete(
        'segments',
        where: 'task_id = ?',
        whereArgs: [taskId],
      );

      // 2. 批量写入新段落
      for (final segment in newSegments) {
        final map = segment.toMap();
        map.remove('id'); // 重设自增主键
        final id = await txn.insert('segments', map);
        try {
          await txn.insert('segments_fts', {
            'rowid': id,
            'text': segment.text,
            'task_id': taskId,
            'segment_id': id,
          });
        } catch (_) {}

        savedList.add(segment.copyWith(id: id));
      }
    });

    notifyDatabaseChanged();
    return savedList;
  }

  /// 彻底删除任务及其关联的所有段落与全文索引
  Future<void> deleteTask(String taskId, {bool deleteAudioFile = false}) async {
    final db = await database;
    final task = await getTask(taskId);

    // 1. 删除 FTS5 虚拟索引
    try {
      await db.delete(
        'segments_fts',
        where: 'task_id = ?',
        whereArgs: [taskId],
      );
    } catch (e) {
      debugPrint('[AppDatabase] 清除 FTS5 索引警告: $e');
    }

    // 2. 删除段落记录
    await db.delete(
      'segments',
      where: 'task_id = ?',
      whereArgs: [taskId],
    );

    // 3. 删除任务主表
    await db.delete(
      'tasks',
      where: 'id = ?',
      whereArgs: [taskId],
    );

    // 4. 可选删除物理音频文件
    if (deleteAudioFile && task != null && task.audioPath.isNotEmpty) {
      try {
        final file = File(task.audioPath);
        if (file.existsSync()) {
          await file.delete();
          debugPrint('[AppDatabase] 物理音频文件已随纪要清理: ${task.audioPath}');
        }
      } catch (e) {
        debugPrint('[AppDatabase] 删除物理音频文件失败: $e');
      }
    }
    notifyDatabaseChanged();
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

    notifyDatabaseChanged();
    return id;
  }

  /// 事务级批量插入段落并同步写入全文索引 (仅触发一次全局通知，杜绝高频刷新卡顿)
  Future<void> insertSegmentsBatch(List<TranscriptSegment> segments) async {
    if (segments.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final segment in segments) {
        final id = await txn.insert('segments', segment.toMap());
        try {
          await txn.insert('segments_fts', {
            'rowid': id,
            'text': segment.text,
            'task_id': segment.taskId,
            'segment_id': id,
          });
        } catch (_) {}
      }
    });
    notifyDatabaseChanged();
  }

  /// 全文检索关键词并返回命中的 taskId 集合
  Future<Set<String>> searchTaskIdsByKeyword(String query) async {
    final q = query.trim();
    if (q.isEmpty) return {};
    final segs = await searchSegments(q);
    return segs.map((s) => s.taskId).toSet();
  }

  /// 批量高性能获取任务统计信息 (单次 SQL 聚合，消除 N+1 慢查询)
  Future<Map<String, TaskSummaryInfo>> getBatchTasksSummaryMap(List<MeetingTask> tasks) async {
    if (tasks.isEmpty) return {};

    final db = await database;
    final summaries = <String, TaskSummaryInfo>{};

    // 1. 批量聚合查询：段落数、总字数、发言人集合
    final aggResults = await db.rawQuery('''
      SELECT 
        task_id, 
        COUNT(*) as seg_count, 
        COALESCE(SUM(LENGTH(text)), 0) as total_words,
        GROUP_CONCAT(DISTINCT COALESCE(NULLIF(TRIM(speaker_name), ''), speaker_id)) as speakers_str
      FROM segments
      GROUP BY task_id
    ''');

    final aggMap = <String, Map<String, dynamic>>{};
    for (final row in aggResults) {
      final taskId = row['task_id'] as String?;
      if (taskId != null) {
        aggMap[taskId] = row;
      }
    }

    // 2. 批量查询每个任务的首句摘要 (取每个 task_id 最小 start_ms 的段落)
    final snippetResults = await db.rawQuery('''
      SELECT s.task_id, s.speaker_name, s.speaker_id, s.text
      FROM segments s
      INNER JOIN (
        SELECT task_id, MIN(start_ms) as min_start
        FROM segments
        GROUP BY task_id
      ) m ON s.task_id = m.task_id AND s.start_ms = m.min_start
      GROUP BY s.task_id
    ''');

    final snippetMap = <String, String>{};
    for (final row in snippetResults) {
      final taskId = row['task_id'] as String?;
      if (taskId != null) {
        final spkName = (row['speaker_name'] as String?)?.trim();
        final spkId = row['speaker_id'] as String? ?? 'SPK_01';
        final name = (spkName != null && spkName.isNotEmpty) ? spkName : spkId;
        final text = (row['text'] as String? ?? '').trim();
        snippetMap[taskId] = '$name: $text';
      }
    }

    // 3. 组装结果映射
    for (final task in tasks) {
      final agg = aggMap[task.id];
      final segCount = (agg?['seg_count'] as int?) ?? 0;
      final totalWords = (agg?['total_words'] as int?) ?? 0;
      final speakersStr = (agg?['speakers_str'] as String?) ?? '';
      final speakers = speakersStr.isNotEmpty
          ? speakersStr.split(',').map((s) => s.trim()).toSet().toList()
          : <String>[];
      final snippet = snippetMap[task.id] ?? '';
      final hasAudio = task.audioPath.isNotEmpty && File(task.audioPath).existsSync();

      summaries[task.id] = TaskSummaryInfo(
        segmentCount: segCount,
        totalWordCount: totalWords,
        speakers: speakers,
        firstSnippet: snippet,
        isAudioFileExists: hasAudio,
      );
    }

    return summaries;
  }

  /// 获取单个任务的真实统计信息
  Future<TaskSummaryInfo> getTaskSummaryInfo(MeetingTask task) async {
    final map = await getBatchTasksSummaryMap([task]);
    return map[task.id] ?? TaskSummaryInfo(
      segmentCount: 0,
      totalWordCount: 0,
      speakers: const [],
      firstSnippet: '',
      isAudioFileExists: task.audioPath.isNotEmpty && File(task.audioPath).existsSync(),
    );
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

  /// 全文检索关键词 (优先使用 FTS5 倒排索引毫秒级命中，异常或特殊字符安全降级为参数化 LIKE 模糊搜索)
  Future<List<TranscriptSegment>> searchSegments(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    final db = await database;
    try {
      // 1. 规范化清洗 FTS5 特殊语法控制符 (双引号、星号、括号等)，防注入与语法解析中断
      final sanitized = cleanQuery.replaceAll(RegExp(r'["\*\(\)\{\}\[\]\:\^\+\-\~]'), ' ').trim();
      if (sanitized.isNotEmpty) {
        // 构建标准 FTS5 前缀短语表达式: "keyword"*
        final ftsExpr = '"$sanitized"*';
        final ftsResults = await db.rawQuery(
          'SELECT segment_id FROM segments_fts WHERE text MATCH ? LIMIT 50',
          [ftsExpr],
        );

        if (ftsResults.isNotEmpty) {
          final ids = ftsResults.map((r) => r['segment_id']).toList();
          final inClause = List.filled(ids.length, '?').join(',');
          final segmentResults = await db.query(
            'segments',
            where: 'id IN ($inClause)',
            whereArgs: ids,
            orderBy: 'start_ms ASC',
          );
          if (segmentResults.isNotEmpty) {
            return segmentResults.map((e) => TranscriptSegment.fromMap(e)).toList();
          }
        }
      }
    } catch (e) {
      debugPrint('[AppDatabase] FTS5 检索降级至 LIKE: $e');
    }

    // 2. 降级安全保障：使用标准参数化 LIKE 模糊搜索 (对中文任意子串匹配最友好)
    final likeResults = await db.query(
      'segments',
      where: 'text LIKE ?',
      whereArgs: ['%$cleanQuery%'],
      orderBy: 'start_ms ASC',
      limit: 50,
    );
    return likeResults.map((e) => TranscriptSegment.fromMap(e)).toList();
  }

  /// 保存声纹
  Future<void> saveVoicePrint(VoicePrint print) async {
    final db = await database;
    await db.insert(
      'voice_prints',
      print.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyDatabaseChanged();
  }

  /// 更新声纹档案姓名
  Future<void> updateVoicePrintName(String id, String newName) async {
    final db = await database;
    await db.update(
      'voice_prints',
      {
        'person_name': newName,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyDatabaseChanged();
  }

  /// 删除声纹档案
  Future<void> deleteVoicePrint(String id) async {
    final db = await database;
    await db.delete(
      'voice_prints',
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyDatabaseChanged();
  }

  /// 获取所有实名声纹
  Future<List<VoicePrint>> getAllVoicePrints() async {
    final db = await database;
    final results = await db.query('voice_prints', orderBy: 'updated_at DESC');
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
