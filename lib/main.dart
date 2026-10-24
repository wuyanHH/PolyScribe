import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化 sherpa-onnx 原生 C++ 推理库绑定
  if (!kIsWeb) {
    try {
      sherpa.initBindings();
    } catch (e) {
      debugPrint('[PolyScribe] 原生 sherpa-onnx 绑定初始化异常: $e');
    }
  }

  runApp(const PolyScribeApp());
}

