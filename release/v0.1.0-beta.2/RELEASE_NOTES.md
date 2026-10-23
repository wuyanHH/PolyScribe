# PolyScribe (声织纪要) v0.1.0-beta.2 发布说明

🎉 **PolyScribe (声织纪要) v0.1.0-beta.2 正式发布！**

本版本带来了全栈级的架构性能突破与交互体验打磨，重点集成了 **Windows 原生 C++ 音频引擎 (WASAPI 环回内录与高性能解码)**、**Android 硬件级 MediaCodec 音频转码管线**，并对 **音字同步播放器、多发言人声纹质心入库、批量导入任务队列与各模块 UI** 进行了深度重构与打磨。

---

## 🛠️ 核心功能与技术升级

### 1. 双端底层原生音频引擎升级 (Native Audio Engine)
- **Windows 原生 C++ 引擎**：
  - 新增 `windows/runner/native_audio_engine.cpp`，支持原生高性能 WAV 解码、WASAPI 环回内录通道及音频格式规范化。
  - 深度桥接 Flutter 平台通道，支持桌面端音视频内录监听与高效无损抽取。
- **Android 原生硬件解码 (MediaCodec / MediaExtractor)**：
  - 增强 `MainActivity.kt` 原生实现，完善 `.m4a`、`.mp3`、`.aac` 等多格式音频硬件解码流水线，统一输出 16kHz 16-bit 单声道 PCM/WAV，杜绝非标准波形崩溃。

### 2. 音字同步播放器 (SyncPlayerScreen) 体验飞跃
- **多角色发言人精细化操作**：
  - 支持在段落卡片中一键快捷重命名角色，并自动同步更新整篇纪要的同名发言人。
  - 支持将指定段落提取的高维特征向量一键入库为实名声纹质心（绑定声纹库）。
- **沉浸阅读与时间轴交互**：
  - 优化段落二分查找音字同步高亮性能，播放过程中自动平滑滚动。
  - 支持全屏沉浸纪要模式、波形可视化拖拽试听与段落快速跳转。

### 3. 批量导入与任务队列可靠性加固 (TaskQueueService)
- **并发锁与队列持久化**：
  - 完善任务队列防挤占并发锁，支持音频导入后自动隔离与本地持久化。
  - 任务异常断电状态感知与重试机制，杜绝后台转写假死或状态丢失。

### 4. 界面与交互全方位打磨 (UI & UX Polish)
- **主界面与纪要工作台**：现代拟态半透明卡片、流式标签布局、多选批量导出与删除。
- **声纹库 (Voiceprint Vault)**：声纹质心向量特征管理、相似度比对与声学特征可视化。
- **本地服务控制台 (Server Console)**：局域网 API 监听状态、实时请求审计日志与内存健康监控。

---

## 📦 各架构打包与产物清单

| 资产文件名 | 平台与架构 | 格式 | 推荐场景 |
| :--- | :--- | :--- | :--- |
| **`PolyScribe-v0.1.0-beta.2-android-arm64-v8a.apk`** | **Android (ARM64-v8a)** | **APK** | **主流现代 64 位手机首选，性能与体积最佳 (推荐)** |
| `PolyScribe-v0.1.0-beta.2-android-arm64-v8a.zip` | Android (ARM64-v8a) | ZIP 压缩包 | arm64 单独压缩包与分流归档 |
| `PolyScribe-v0.1.0-beta.2-android-armeabi-v7a.apk` | Android (ARMv7) | APK | 老旧 32 位 Android 手机与特定车载设备 |
| `PolyScribe-v0.1.0-beta.2-android-x86_64.apk` | Android (x86_64) | APK | PC 安卓模拟器与 ChromeOS |
| `PolyScribe-v0.1.0-beta.2-android-all-apks.zip` | Android (全架构集合) | ZIP 压缩包 | 包含上述全部架构 APK 文件的完整集合包 |
| **`PolyScribe-v0.1.0-beta.2-windows-x64.zip`** | **Windows 10/11 (x64)** | **ZIP 绿色包** | **解压即用，支持桌面生产力、WASAPI 双轨内录与本地转写服务** |

---

## 🔒 完整性与安全哈希 (SHA-256)

```text
bc09ca5e203922fa8b7349c619cde69fcc7a53a4d3b6b4334e36f9b1efd60585  PolyScribe-v0.1.0-beta.2-android-all-apks.zip
f50e2bd1cf786a0d61b1040f011c78fb9b9eea8faaf157d97df06d76db8358d5  PolyScribe-v0.1.0-beta.2-android-arm64-v8a.apk
c0f4ea1c029911dd98cc55bc25aec1aa6420dd3a8ab2e20b70a6e35d37711451  PolyScribe-v0.1.0-beta.2-android-arm64-v8a.zip
611696a2e0f1593116b68b353b28d3f388a30f8fc4fd2179fec35d092f486d8d  PolyScribe-v0.1.0-beta.2-android-armeabi-v7a.apk
092226516fe69718d9490207b9c2da57b2b4619ebb27ed54f57d60c054b91bac  PolyScribe-v0.1.0-beta.2-android-x86_64.apk
9056e5e2603a27d5bcd0f3b693c987a7691525d63f9683507f3d13886d9a9c41  PolyScribe-v0.1.0-beta.2-windows-x64.zip
```
