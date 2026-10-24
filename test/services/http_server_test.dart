import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:polyscribe/data/models/transcript_segment.dart';
import 'package:polyscribe/services/server/http_server.dart';

void main() {
  group('LocalHttpServer 本地转写 API 兼容性测试', () {
    late LocalHttpServer server;
    const testPort = 18765;

    setUp(() async {
      server = LocalHttpServer(
        port: testPort,
        onTranscribe: (bytes, filename, {bool diarize = false}) async {
          return [
            TranscriptSegment(
              taskId: 't1',
              speakerId: 'SPK_01',
              speakerName: '张总',
              startMs: 1000,
              endMs: 3500,
              text: '交付节点必须严格遵守。',
            ),
          ];
        },
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('健康检查 GET /health', () async {
      final res = await http.get(Uri.parse('http://127.0.0.1:$testPort/health'));
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body);
      expect(json['status'], 'ok');
      expect(res.headers['server'], 'PolyScribe-Local-STT/1.0');
    });

    test('POST /v1/audio/transcriptions 默认 JSON 格式', () async {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:$testPort/v1/audio/transcriptions'),
        headers: {'content-type': 'application/octet-stream'},
        body: [0, 1, 2, 3], // 模拟音频字节
      );
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body);
      expect(json['text'], '交付节点必须严格遵守。');
    });

    test('POST /v1/audio/transcriptions SRT 字幕格式', () async {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:$testPort/v1/audio/transcriptions?response_format=srt'),
        headers: {'content-type': 'application/octet-stream'},
        body: [0, 1, 2, 3],
      );
      expect(res.statusCode, 200);
      expect(res.body, contains('00:00:01,000 --> 00:00:03,500'));
      expect(res.body, contains('[张总]: 交付节点必须严格遵守。'));
    });

    test('POST /v1/audio/transcriptions verbose_json 格式', () async {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:$testPort/v1/audio/transcriptions?response_format=verbose_json&diarize=true'),
        headers: {'content-type': 'application/octet-stream'},
        body: [0, 1, 2, 3],
      );
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body);
      expect(json['language'], 'chinese');
      expect(json['segments'], isNotEmpty);
      expect(json['segments'][0]['speaker'], '张总');
    });

    test('POST /v1/audio/transcriptions 标准 Multipart/form-data 文件上传测试', () async {
      final uri = Uri.parse('http://127.0.0.1:$testPort/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        [10, 20, 30, 40, 50],
        filename: 'meeting_audio.wav',
      ));
      request.fields['model'] = 'whisper-1';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      expect(response.statusCode, 200);
      final json = jsonDecode(response.body);
      expect(json['text'], '交付节点必须严格遵守。');
    });
  });
}
