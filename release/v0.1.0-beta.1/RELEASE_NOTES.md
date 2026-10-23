# PolyScribe (声织纪要) v0.1.0-beta.1 发布说明

🎉 **PolyScribe (声织纪要) v0.1.0-beta.1 发布！**

本版本重点修复了多格式录音文件导入后的离线转写崩溃、详情页音字同步刷新延迟，以及列表发言人展示排版优化，带来了更稳定、精准的纯端侧离线语音转写体验。

---

## 🛠️ 核心修复与升级

### 1. 修复离线推理工作线程原生 FFI 绑定
- 解决子线程（`InferenceWorkerIsolate`）中漏调 `sherpa.initBindings()` 导致底层 C++ `OfflineRecognizer` 构造失败的缺陷。
- 彻底移除开发期硬编码占位文本，若模型异常直接中断并上报真实错误状态，绝无虚假数据。

### 2. 修复纪要详情页音字同步刷新假死
- 解决进入详情页时因异步加载段落缺少 `setState` 触发 UI 重绘，从而误报“音频已移除”和“暂无段落”的问题。
- 引入优雅的加载状态守卫，段落与本地音频物理状态秒级准确同步。

### 3. 多格式音频全自动转码管线
- 针对 `.m4a`、`.mp3`、`.aac` 等非标准波形文件，自动桥接系统解码管线将其转换为规范的 16kHz PCM 单声道 WAV 后送入 SenseVoice 引擎，防止非 WAV 文件的解析异常。

### 4. 优化列表发言人展示与自适应排版
- 针对发言人较多的场景，改用独立色彩胶囊与 `等 N 人` 计数徽章紧凑呈现，告别大段冗长文本。
- 录音时长自动格式化为 `X分Y秒`，元数据标签引入 `Wrap` 弹性流式布局，彻底杜绝小屏溢出。

---

## 📦 各架构打包与产物清单

| 资产文件名 | 平台与架构 | 格式 | 推荐场景 |
| :--- | :--- | :--- | :--- |
| **`PolyScribe-v0.1.0-beta.1-android-arm64-v8a.apk`** | **Android (ARM64-v8a)** | **APK** | **主流现代 64 位手机首选 (v8版本)，性能与体积最佳** |
| `PolyScribe-v0.1.0-beta.1-android-arm64-v8a.zip` | Android (ARM64-v8a) | ZIP 压缩包 | arm64 单独分流归档包 |
| `PolyScribe-v0.1.0-beta.1-android-armeabi-v7a.apk` | Android (ARMv7) | APK | 老旧 32 位 Android 手机与特定车载设备 |
| `PolyScribe-v0.1.0-beta.1-android-x86_64.apk` | Android (x86_64) | APK | PC 安卓模拟器与 ChromeOS |
| `PolyScribe-v0.1.0-beta.1-android-all-apks.zip` | Android (全架构集合) | ZIP 压缩包 | 包含上述全部架构 APK 文件的完整压缩包 |
| `PolyScribe-v0.1.0-beta.1-windows-x64.zip` | Windows 10/11 (x64) | ZIP 绿色包 | 解压即用，支持桌面生产力、WASAPI 双轨录音与本地转写服务 |

---

## 🔒 完整性与安全哈希 (SHA256)

请参见同级目录下的 `SHA256SUMS.txt` 文件校验安装包完整性。
