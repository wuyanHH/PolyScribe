import 'dart:convert';
import 'dart:io';
import '../data/models/meeting_task.dart';
import '../data/models/transcript_segment.dart';

/// 导出格式枚举
enum ExportFormat {
  srt('srt', 'SRT 字幕文件 (.srt)'),
  vtt('vtt', 'WebVTT 字幕文件 (.vtt)'),
  markdown('md', '结构化纪要 Markdown (.md)'),
  plainText('txt', '纯文本文件 (.txt)'),
  json('json', '结构化 JSON 数据 (.json)');

  final String extension;
  final String label;
  const ExportFormat(this.extension, this.label);
}

/// 生产力导出中心服务
class ExportCenterService {
  ExportCenterService._();

  /// 转换为指定格式的文本内容
  static String formatContent({
    required MeetingTask task,
    required List<TranscriptSegment> segments,
    required ExportFormat format,
  }) {
    switch (format) {
      case ExportFormat.srt:
        return _generateSrt(segments);
      case ExportFormat.vtt:
        return _generateVtt(segments);
      case ExportFormat.markdown:
        return _generateMarkdown(task, segments);
      case ExportFormat.plainText:
        return _generatePlainText(task, segments);
      case ExportFormat.json:
        return _generateJson(task, segments);
    }
  }

  /// 导出到本地物理文件
  static Future<File> exportToFile({
    required String outputDir,
    required MeetingTask task,
    required List<TranscriptSegment> segments,
    required ExportFormat format,
  }) async {
    final content = formatContent(task: task, segments: segments, format: format);
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filePath = '$outputDir/$sanitizedTitle.${format.extension}';
    final file = File(filePath);
    await file.writeAsString(content);
    return file;
  }

  static String _generateSrt(List<TranscriptSegment> segments) {
    final buffer = StringBuffer();
    for (int i = 0; i < segments.length; i++) {
      final s = segments[i];
      buffer.writeln('${i + 1}');
      buffer.writeln('${_formatSrtTime(s.startMs)} --> ${_formatSrtTime(s.endMs)}');
      buffer.writeln('[${s.speakerName ?? s.speakerId}]: ${s.text}');
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _generateVtt(List<TranscriptSegment> segments) {
    final buffer = StringBuffer();
    buffer.writeln('WEBVTT');
    buffer.writeln();
    for (int i = 0; i < segments.length; i++) {
      final s = segments[i];
      buffer.writeln('${i + 1}');
      buffer.writeln('${_formatVttTime(s.startMs)} --> ${_formatVttTime(s.endMs)}');
      buffer.writeln('<v ${s.speakerName ?? s.speakerId}>${s.text}');
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _generateMarkdown(MeetingTask task, List<TranscriptSegment> segments) {
    final buffer = StringBuffer();
    buffer.writeln('# ${task.title}');
    buffer.writeln();
    buffer.writeln('> **生成工具**：PolyScribe (声织纪要) 端侧离线语音中枢');
    buffer.writeln('> **会议时长**：${task.durationMs ~/ 1000} 秒');
    buffer.writeln('> **创建时间**：${DateTime.fromMillisecondsSinceEpoch(task.createdAt)}');
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln();
    buffer.writeln('## 会议逐字纪要');
    buffer.writeln();

    for (final s in segments) {
      final timeStr = _formatDisplayTime(s.startMs);
      buffer.writeln('### **[${s.speakerName ?? s.speakerId}]** `[$timeStr]`');
      buffer.writeln(s.text);
      buffer.writeln();
    }

    return buffer.toString();
  }

  static String _generatePlainText(MeetingTask task, List<TranscriptSegment> segments) {
    final buffer = StringBuffer();
    buffer.writeln('【${task.title}】');
    buffer.writeln();
    for (final s in segments) {
      buffer.writeln('[${s.speakerName ?? s.speakerId}] (${_formatDisplayTime(s.startMs)}): ${s.text}');
    }
    return buffer.toString();
  }

  static String _generateJson(MeetingTask task, List<TranscriptSegment> segments) {
    final map = {
      'task_id': task.id,
      'title': task.title,
      'duration_ms': task.durationMs,
      'created_at': task.createdAt,
      'segments': segments.map((s) => s.toMap()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static String _formatSrtTime(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$millis';
  }

  static String _formatVttTime(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$millis';
  }

  static String _formatDisplayTime(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
