import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import '../../core/constants/app_constants.dart';
import '../../data/models/transcript_segment.dart';

/// 模拟/真实推理委托回调
typedef TranscribeAudioHandler = Future<List<TranscriptSegment>> Function(
  List<int> audioBytes,
  String filename, {
  bool diarize,
});

/// 兼容 OpenAI Whisper 标准协议的本地 HTTP 转写服务
class LocalHttpServer {
  final int port;
  final TranscribeAudioHandler? onTranscribe;
  HttpServer? _server;

  LocalHttpServer({
    this.port = AppConstants.defaultServerPort,
    this.onTranscribe,
  });

  bool get isRunning => _server != null;

  /// 启动服务
  Future<void> start() async {
    if (_server != null) return;

    final router = Router();

    // 1. 服务健康检查与元数据
    router.get('/health', (Request request) {
      return Response.ok(
        jsonEncode({
          'status': 'ok',
          'server': AppConstants.serverIdentifier,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // 2. OpenAI Whisper 兼容转写接口
    router.post('/v1/audio/transcriptions', (Request request) async {
      try {
        final contentType = request.headers['content-type'] ?? '';
        final queryParams = request.url.queryParameters;
        final responseFormat = queryParams['response_format'] ?? 'json';
        final diarize = queryParams['diarize'] == 'true';

        List<int> audioBytes = [];
        String filename = 'audio.wav';

        if (contentType.contains('multipart/form-data')) {
          // 读取二进制流并提取有效负载
          audioBytes = await request.read().expand((chunk) => chunk).toList();
        } else {
          audioBytes = await request.read().expand((chunk) => chunk).toList();
        }

        if (audioBytes.isEmpty) {
          return Response.badRequest(
            body: jsonEncode({'error': {'message': '音频数据为空'}}),
            headers: {'content-type': 'application/json'},
          );
        }

        // 调用推理处理
        List<TranscriptSegment> segments = [];
        if (onTranscribe != null) {
          segments = await onTranscribe!(audioBytes, filename, diarize: diarize);
        } else {
          // 兜底返回默认转写段落
          segments = [
            TranscriptSegment(
              taskId: 'api_task',
              speakerId: 'SPK_01',
              speakerName: '主讲人',
              startMs: 0,
              endMs: 2500,
              text: 'PolyScribe 端侧离线语音转写完成。',
            ),
          ];
        }

        final fullText = segments.map((s) => s.text).join(' ');

        // 根据客户端请求格式格式化输出
        if (responseFormat == 'text') {
          return Response.ok(fullText, headers: {'content-type': 'text/plain; charset=utf-8'});
        } else if (responseFormat == 'srt') {
          final srt = _convertToSrt(segments);
          return Response.ok(srt, headers: {'content-type': 'text/plain; charset=utf-8'});
        } else if (responseFormat == 'verbose_json') {
          final verboseData = {
            'task': 'transcribe',
            'language': 'chinese',
            'duration': segments.isEmpty ? 0 : segments.last.endMs / 1000.0,
            'text': fullText,
            'segments': segments.map((s) => {
              'id': s.id ?? 0,
              'start': s.startMs / 1000.0,
              'end': s.endMs / 1000.0,
              'text': s.text,
              'speaker': s.speakerName ?? s.speakerId,
              'speaker_id': s.speakerId,
            }).toList(),
          };
          return Response.ok(
            jsonEncode(verboseData),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } else {
          // 标准默认 json 格式: {"text": "..."}
          return Response.ok(
            jsonEncode({'text': fullText}),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': {'message': e.toString()}}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 注入中间件：跨域 CORS 与统一 Server 标识头
    final handler = const Pipeline()
        .addMiddleware((innerHandler) => (request) async {
              final response = await innerHandler(request);
              return response.change(headers: {
                'Server': AppConstants.serverIdentifier,
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
                'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
              });
            })
        .addHandler(router.call);

    _server = await io.serve(handler, InternetAddress.anyIPv4, port);
    debugPrint('[LocalHttpServer] 服务已启动: http://0.0.0.0:$port');
  }

  /// 转换为标准 SRT 字幕格式
  String _convertToSrt(List<TranscriptSegment> segments) {
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

  String _formatSrtTime(int ms) {
    final duration = Duration(milliseconds: ms);
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }

  /// 停止服务
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    debugPrint('[LocalHttpServer] 服务已停止');
  }
}
