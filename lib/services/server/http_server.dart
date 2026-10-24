import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import '../../core/constants/app_constants.dart';
import '../../data/models/transcript_segment.dart';
import 'inference_lock_manager.dart';

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
      final startTime = DateTime.now();
      final clientIp = (request.context['shelf.io.connection_info'] as dynamic)?.remoteAddress?.address ?? '127.0.0.1';

      try {
        final contentType = request.headers['content-type'] ?? '';
        final queryParams = request.url.queryParameters;
        final responseFormat = queryParams['response_format'] ?? 'json';
        final diarize = queryParams['diarize'] == 'true';

        List<int> audioBytes = [];
        String filename = 'audio.wav';

        final rawBody = await request.read().expand((chunk) => chunk).toList();

        if (contentType.contains('multipart/form-data')) {
          // 深度解包 multipart/form-data 二进制报文，提取纯净音频二进制流与文件名
          final extracted = _extractAudioFromMultipart(rawBody, contentType);
          audioBytes = extracted.audioBytes;
          if (extracted.filename.isNotEmpty) {
            filename = extracted.filename;
          }
        } else {
          // application/octet-stream 或直接二进制音频推流
          audioBytes = rawBody;
        }

        if (audioBytes.isEmpty) {
          InferenceLockManager.instance.recordLog(ApiCallLog(
            id: 'call_${DateTime.now().millisecondsSinceEpoch}',
            timestamp: startTime,
            clientIp: clientIp,
            endpoint: '/v1/audio/transcriptions',
            audioBytesLength: 0,
            latencyMs: DateTime.now().difference(startTime).inMilliseconds,
            resultPreview: '音频数据为空',
            statusCode: 400,
          ));

          return Response.badRequest(
            body: jsonEncode({'error': {'message': '音频数据为空'}}),
            headers: {'content-type': 'application/json'},
          );
        }

        // 加锁单例推理，防止多客户端并发导致 OOM
        final segments = await InferenceLockManager.instance.runWithLock(() async {
          if (onTranscribe != null) {
            return await onTranscribe!(audioBytes, filename, diarize: diarize);
          } else {
            return [
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
        });

        final fullText = segments.map((s) => s.text).join(' ');
        final latency = DateTime.now().difference(startTime).inMilliseconds;

        InferenceLockManager.instance.recordLog(ApiCallLog(
          id: 'call_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: startTime,
          clientIp: clientIp,
          endpoint: '/v1/audio/transcriptions',
          audioBytesLength: audioBytes.length,
          latencyMs: latency,
          resultPreview: fullText.length > 50 ? '${fullText.substring(0, 50)}...' : fullText,
          statusCode: 200,
        ));

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
              // 拦截浏览器 CORS OPTIONS 预检请求直接放行
              if (request.method == 'OPTIONS') {
                return Response.ok('', headers: {
                  'Server': AppConstants.serverIdentifier,
                  'Access-Control-Allow-Origin': '*',
                  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
                  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
                });
              }

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

  /// 从 multipart/form-data 原始字节报文中提取纯净音频二进制流与文件名
  static ({List<int> audioBytes, String filename}) _extractAudioFromMultipart(
    List<int> bodyBytes,
    String contentType,
  ) {
    if (bodyBytes.isEmpty) {
      return (audioBytes: <int>[], filename: 'audio.wav');
    }

    // 1. 尝试从 Content-Type 头解析 boundary 字符串
    String? boundary;
    final boundaryMatch = RegExp(r'boundary=([^;]+)', caseSensitive: false).firstMatch(contentType);
    if (boundaryMatch != null) {
      boundary = boundaryMatch.group(1)?.trim();
      if (boundary != null && boundary.startsWith('"') && boundary.endsWith('"') && boundary.length > 2) {
        boundary = boundary.substring(1, boundary.length - 1);
      }
    }

    // 2. 如果未指定 boundary，尝试从报文首行自动探测 (首行通常形如 --boundary)
    if (boundary == null || boundary.isEmpty) {
      final firstLineEnd = _indexOfByteSeq(bodyBytes, [13, 10], 0);
      if (firstLineEnd > 2) {
        final firstLineStr = utf8.decode(bodyBytes.sublist(0, firstLineEnd), allowMalformed: true);
        if (firstLineStr.startsWith('--')) {
          boundary = firstLineStr.substring(2).trim();
        }
      }
    }

    if (boundary != null && boundary.isNotEmpty) {
      final delimiter = utf8.encode('--$boundary');
      final firstDelimiterIdx = _indexOfByteSeq(bodyBytes, delimiter, 0);

      if (firstDelimiterIdx >= 0) {
        final headerStart = firstDelimiterIdx + delimiter.length;
        // 查找头信息结束标志 (\r\n\r\n 或 \n\n)
        int headerEnd = _indexOfByteSeq(bodyBytes, [13, 10, 13, 10], headerStart);
        int dataStart = headerEnd >= 0 ? headerEnd + 4 : -1;

        if (headerEnd < 0) {
          headerEnd = _indexOfByteSeq(bodyBytes, [10, 10], headerStart);
          dataStart = headerEnd >= 0 ? headerEnd + 2 : -1;
        }

        if (dataStart >= 0 && dataStart < bodyBytes.length) {
          // 解析 Header 中的 filename
          String foundFilename = 'audio.wav';
          final headerBytes = bodyBytes.sublist(headerStart, headerEnd);
          final headerStr = utf8.decode(headerBytes, allowMalformed: true);
          final filenameMatch = RegExp(r'filename="?([^";\r\n]+)"?', caseSensitive: false).firstMatch(headerStr);
          if (filenameMatch != null) {
            foundFilename = filenameMatch.group(1)?.trim() ?? 'audio.wav';
          }

          // 寻找下一个 boundary 标志
          final nextDelimiterIdx = _indexOfByteSeq(bodyBytes, delimiter, dataStart);
          int dataEnd = nextDelimiterIdx >= 0 ? nextDelimiterIdx : bodyBytes.length;

          // 剥离尾部的 \r\n (CRLF) 或 \n (LF)
          if (dataEnd >= 2 && bodyBytes[dataEnd - 2] == 13 && bodyBytes[dataEnd - 1] == 10) {
            dataEnd -= 2;
          } else if (dataEnd >= 1 && bodyBytes[dataEnd - 1] == 10) {
            dataEnd -= 1;
          }

          if (dataEnd > dataStart) {
            return (
              audioBytes: bodyBytes.sublist(dataStart, dataEnd),
              filename: foundFilename,
            );
          }
        }
      }
    }

    // 3. 兜底方案：智能扫描 RIFF 头部 (针对 WAV 音频)
    final riffIdx = _indexOfByteSeq(bodyBytes, [0x52, 0x49, 0x46, 0x46], 0); // "RIFF"
    if (riffIdx >= 0 && riffIdx + 12 <= bodyBytes.length) {
      final waveIdx = _indexOfByteSeq(bodyBytes, [0x57, 0x41, 0x56, 0x45], riffIdx); // "WAVE"
      if (waveIdx == riffIdx + 8) {
        return (audioBytes: bodyBytes.sublist(riffIdx), filename: 'audio.wav');
      }
    }

    return (audioBytes: bodyBytes, filename: 'audio.wav');
  }

  /// 在字节数组中高效定位指定子序列索引
  static int _indexOfByteSeq(List<int> source, List<int> pattern, int start) {
    if (pattern.isEmpty || start + pattern.length > source.length) return -1;
    final first = pattern[0];
    final max = source.length - pattern.length;

    for (int i = start; i <= max; i++) {
      if (source[i] != first) continue;
      bool match = true;
      for (int j = 1; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
