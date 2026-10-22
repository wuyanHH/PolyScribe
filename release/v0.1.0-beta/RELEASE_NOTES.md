# PolyScribe (声织纪要) v0.1.0-beta 发布说明

🎉 **PolyScribe (声织纪要) 迎来首发测试版 v0.1.0-beta！**

PolyScribe 是一款基于 Flutter 原生构建、采用 `sherpa-onnx` C++ 推理引擎的**端侧纯离线多角色语音识别（STT）、声纹聚类切分与本地语音中枢系统**。本版本实现了从音频采集、离线多角色识别、音字同步拖拽播放、多格式生产力导出，到本地兼容 OpenAI Whisper 协议的 HTTP/WebSocket 服务全闭环。

---

## 🌟 核心特性与架构亮点

### 1. 纯端侧离线 AI 矩阵（零数据出境）
- **主力 STT 语音识别**：内置/按需加载阿里 `SenseVoice-Small (Int8)`，高精度自动混识中、粤、英、日、韩五语种，RTF 约 0.05 极速推理。
- **语音活动检测 (VAD)**：集成 `Silero-VAD v5`，毫秒级滤除背景静音与噪声。
- **声纹切分与聚类 (Diarization)**：`pyannote-segmentation-3.0` 换人边界切分 + `CAM++ / 3D-Speaker` 高维声纹提取，实现长会议多角色发言自动区分与实名标记。

### 2. AI 模型下载与更新管理中心
- **一键下载部署**：主界面一键探测模型就绪状态，缺失时一键批量下载与全自动后台解压部署。
- **多加速源支持**：内置 **国内高速镜像源 (ModelScope 魔搭社区)** 与 **全球官方源 (GitHub Releases)**，国内宽带极速满速下载。
- **在线检查更新**：随时检查各模型最新版本与 SHA256 签名，保障端侧模型持续迭代。

### 3. 多场景生产力交互
- **通话录音批处理**：多选外部录音文件排队串行转写，内置双声道互相关系数检测（独立双声道 100% 角色秒分离）。
- **音字同步播放器**：二分查找高频时间戳对齐，支持点击字幕精准 Seek、拖拽波形高亮跟随。
- **全文毫秒级检索**：SQLite3 + FTS5 全文索引，支持高亮定位与原音回放。
- **生产力导出中心**：一键导出 SRT、WebVTT 字幕、Markdown 结构化纪要与标准 JSON。

### 4. 本地 STT 转发服务
- 内置兼容 OpenAI Whisper 格式的本地 HTTP `/v1/audio/transcriptions` 接口与 WebSocket 流式接口。
- 局域网 mDNS 发现与调用日志审计，支持第三方应用（如剪映、沉浸式翻译等）接入本地识别。

---

## 📦 各架构打包与产物清单

| 资产文件名 | 平台与架构 | 格式 | 说明 |
| :--- | :--- | :--- | :--- |
| `PolyScribe-v0.1.0-beta-android-arm64-v8a.apk` | Android (ARM64-v8a) | APK | 主流 64 位手机推荐，体积精简性能最优 |
| `PolyScribe-v0.1.0-beta-android-arm64-v8a.zip` | Android (ARM64-v8a) | ZIP 压缩包 | arm64 单独压缩包 |
| `PolyScribe-v0.1.0-beta-android-armeabi-v7a.apk` | Android (ARMv7) | APK | 适用于老旧 32 位 Android 设备 |
| `PolyScribe-v0.1.0-beta-android-x86_64.apk` | Android (x86_64) | APK | 适用于 PC 安卓模拟器与 ChromeOS |
| `PolyScribe-v0.1.0-beta-android-universal.apk` | Android (全架构) | APK | 包含所有 CPU 架构库的兼容包 |
| `PolyScribe-v0.1.0-beta-android-all-apks.zip` | Android (全架构集合) | ZIP 压缩包 | 包含上述全部 Android APK 文件的完整压缩包 |
| `PolyScribe-v0.1.0-beta-windows-x64.zip` | Windows 10/11 (x64) | ZIP 绿色包 | 解压即用，支持桌面生产力与 WASAPI 双轨内录 |

---

## 🔒 完整性与安全哈希
详见发布包内的 `SHA256SUMS.txt` 校验文件。
