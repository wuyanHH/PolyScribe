import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import '../../core/constants/app_constants.dart';

/// 流式分段识别回调定义
typedef OnStreamChunkReceived = Future<Map<String, dynamic>> Function(List<int> pcmBytes);

/// 低延迟 WebSocket 流式转写服务
class LocalWsServer {
  final int port;
  final OnStreamChunkReceived? onChunk;
  HttpServer? _server;

  LocalWsServer({
    this.port = AppConstants.defaultServerPort + 1, // 默认 8766 端口或共用
    this.onChunk,
  });

  bool get isRunning => _server != null;

  /// 启动 WebSocket 服务
  Future<void> start() async {
    if (_server != null) return;

    final handler = webSocketHandler((dynamic webSocket, [dynamic protocol]) {
      debugPrint('[LocalWsServer] 新客户端已连接 WebSocket');

      webSocket.stream.listen(
        (message) async {
          if (message is List<int>) {
            // 接收二进制 PCM 音频帧
            if (onChunk != null) {
              final result = await onChunk!(message);
              webSocket.sink.add(jsonEncode(result));
            } else {
              // 模拟即时回执响应
              final mockResponse = {
                'is_final': true,
                'speaker': '主讲人',
                'speaker_id': 'SPK_01',
                'start_ms': 0,
                'end_ms': 1000,
                'text': '流式语音识别响应正常',
              };
              webSocket.sink.add(jsonEncode(mockResponse));
            }
          } else if (message is String) {
            // 控制消息 (如 ping/pong 或心跳)
            if (message == 'ping') {
              webSocket.sink.add('pong');
            }
          }
        },
        onError: (error) {
          debugPrint('[LocalWsServer] WebSocket 连接异常: $error');
        },
        onDone: () {
          debugPrint('[LocalWsServer] 客户端已断开连接');
        },
      );
    });

    _server = await io.serve(handler, InternetAddress.anyIPv4, port);
    debugPrint('[LocalWsServer] WebSocket 流式服务已启动: ws://0.0.0.0:$port');
  }

  /// 停止服务
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    debugPrint('[LocalWsServer] WebSocket 服务已停止');
  }
}
