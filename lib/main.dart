import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'app.dart';
import 'services/app_storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化外部存储与资产路径管理器
  await AppStorageService.instance.init();
  
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

