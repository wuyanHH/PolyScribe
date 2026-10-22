# Flutter 基础与核心组件混淆保护规则
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Sherpa-ONNX 离线推理引擎 JNI 与底层 Native 接口防裁剪保护
-keep class com.k2fsa.sherpa.onnx.** { *; }
-dontwarn com.k2fsa.sherpa.onnx.**

# 保持所有 Native 方法签名与 C/C++ 动态链接符号
-keepclasseswithmembernames class * {
    native <methods>;
}

# SQLite 与 Sqflite 原生桥接保护
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**

# Google Play Core 拆分安装组件警告忽略 (Flutter 引擎内部引用但未使用)
-dontwarn com.google.android.play.core.**
