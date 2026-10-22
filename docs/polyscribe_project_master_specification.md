# PolyScribe (声织纪要) - 软件系统架构设计与开发总文档 (Master Specification)

> **版本**：v1.0.0  
> **状态**：正式发布 / 开发基线  
> **定位**：端侧全离线多角色语音识别（STT）、声纹分离、智能会议纪要与本地语音中枢系统

---

## 目录
- [一、 项目定位与工程元数据规范](#一-项目定位与工程元数据规范)
- [二、 核心技术栈与模型选型架构](#二-核心技术栈与模型选型架构)
  - [1. 跨平台与底层系统技术栈](#1-跨平台与底层系统技术栈)
  - [2. 本地 AI 模型矩阵组合（全端离线 Int8 量化）](#2-本地-ai-模型矩阵组合全端离线-int8-量化)
- [三、 整体系统架构与数据流设计](#三-整体系统架构与数据流设计)
  - [1. 系统分层架构全景图](#1-系统分层架构全景图)
  - [2. 关键业务数据流向](#2-关键业务数据流向)
- [四、 核心功能模块详细设计](#四-核心功能模块详细设计)
  - [模块 A：多角色分辨（Speaker Diarization）双模式引擎](#模块-a多角色分辨speaker-diarization双模式引擎)
  - [模块 B：本地 STT 转发中心与全协议兼容服务](#模块-b本地-stt-转发中心与全协议兼容服务)
  - [模块 C：超长会议后台保活、防 OOM 与流畅渲染方案](#模块-c超长会议后台保活防-oom-与流畅渲染方案)
  - [模块 D：音字同步播放、拖拽定位与全文检索系统](#模块-d音字同步播放拖拽定位与全文检索系统)
  - [模块 E：Windows 桌面端专属增强（双轨内录与桌面生产力）](#模块-ewindows-桌面端专属增强双轨内录与桌面生产力)
- [五、 数据持久化与存储层物理设计 (SQLite + FTS5)](#五-数据持久化与存储层物理设计-sqlite--fts5)
- [六、 视觉与交互规范（多角色专属 UI 色板）](#六-视觉与交互规范多角色专属-ui-色板)
- [七、 关键工程避坑指南与最佳实践](#七-关键工程避坑指南与最佳实践)
- [八、 分阶段开发计划与工程里程碑 (Roadmap)](#八-分阶段开发计划与工程里程碑-roadmap)

---

## 一、 项目定位与工程元数据规范

| 配置项 | 规范设定值 | 适用场景与工程说明 |
| :--- | :--- | :--- |
| **中文全称** | **声织纪要** | 应用商店标题、关于页面、Windows 窗口主标题、安装程序标题 |
| **中文简称** | **声织** | 移动端桌面图标下方名称（精简为 2 个汉字，杜绝系统文本截断，视觉最稳） |
| **英文名称** | **PolyScribe** | 国际化语言环境、GitHub 仓库名、代码命名空间、CLI 工具名 |
| **Slogan（副标题）** | **多角色离线语音转写与声纹中枢** | 应用启动页（Splash）、应用商店一句话简介、推广副标题 |
| **核心包名 (App ID)** | `com.polyscribe.audio` | Android `applicationId` / iOS `Bundle Identifier` |
| **Windows 内部标识** | `PolyScribe.Desktop.Audio` | Windows 注册表键值、MSIX/InnoSetup 安装包 AppId |
| **自定义 URL Scheme** | `polyscribe://` | 第三方应用/浏览器 DeepLink 唤醒（如 `polyscribe://transcribe?uri=...`） |
| **本地 API 服务标识** | `PolyScribe-Local-STT/1.0` | HTTP 响应头 `Server` 字段、局域网 mDNS 服务广播名（`_polyscribe-stt._tcp.local.`） |
| **Android 语音服务名** | `PolyScribe 离线语音引擎` | 注册系统 `RecognitionService` 时在系统默认语音识别服务列表中展示的名称 |

---

## 二、 核心技术栈与模型选型架构

要在移动端（ARM64）与 Windows 桌面端（x86_64/ARM64）共用一套底层推理逻辑，同时杜绝繁重的 Python 环境依赖，采用 **Flutter + sherpa-onnx** 原生 C++ 方案。

### 1. 跨平台与底层系统技术栈

| 模块 | 推荐方案 | 选型理由与技术特性 |
| :--- | :--- | :--- |
| **应用与 UI 框架** | **Flutter (Dart)** | 一套代码原生编译 Android、iOS、Windows；采用新一代 Impeller/Skia 渲染引擎，天然适配长列表虚拟化滚动与高频波形重绘；通过 Dart FFI 零损耗穿透调用 C++。 |
| **端侧推理引擎** | **sherpa-onnx** (k2-fsa) | 基于 ONNX Runtime 的纯 C++ 语音引擎，无 Python/PyTorch 依赖；原生提供 Dart FFI 绑定包；整合 VAD + ASR + 说话人切分 + 声纹特征提取，支持 NPU/GPU/CPU Int8 加速。 |
| **音频解码与重采样** | **FFmpegKit** / 原生解码器 | 兼容五花八门的录音格式（`.m4a`, `.amr`, `.mp3`, `.aac`, `.ogg`, `.opus`, `.wav`），统一转换为模型标准的 **16kHz、16-bit、单声道 PCM**。 |
| **本地数据库与检索** | **SQLite3 + FTS5** | 结合 `simple` 中文拼音分词扩展，实现百万字级纪要的毫秒级全文检索与时间戳定位。 |
| **内置 API 服务器** | **Dart `shelf` 技术栈** | 在后台独立 Isolate 线程中启动轻量级 HTTP (`shelf_router`) 与 WebSocket (`shelf_web_socket`) 服务，无需反向代理与外部组件。 |

### 2. 本地 AI 模型矩阵组合（全端离线 Int8 量化）

为了兼顾实时会议低延迟与高准确率，整体模型体积控制在 **300MB 以内**，运行时内存占用稳定在 **500MB 以下**：

```
[音频输入 16kHz PCM]
       │
       ▼
1. Silero-VAD v5 (2MB) ────────► [静音过滤 / 语音分段切片]
       │
       ├─────────────────────────────────┐
       ▼                                 ▼
2. SenseVoice-Small (230MB)       3. 多角色分离组合 (31MB)
   - 中/粤/英/日/韩自动多语种混识       ├─ pyannote-segmentation-3.0 (6MB: 边界切分)
   - RTF ≈ 0.05 (极速推理)             └─ CAM++ / ERes2Net (25MB: 提取声纹特征向量)
       │                                 │
       └────────────────┬────────────────┘
                        ▼
             [带说话人标签与时间戳的文字流]
```

1. **VAD（语音活动检测）**：`Silero-VAD v5 (ONNX)`（约 2MB）
   - **作用**：实时切分有效语音片段，滤除无声区与背景底噪，防止模型空转和幻觉（Hallucination）。
2. **ASR（主力语音识别）**：`SenseVoice-Small (Int8 ONNX)`（约 230MB）
   - **作用**：高精度中文识别，原生支持中、粤、英、日、韩混合自动识别；推理极快（骁龙 8 系/天玑平台 RTF 约 0.05）。
   - **多语种扩展**：支持应用内可选下载 `Whisper-Base/Small (Int8 ONNX)` 挂载覆盖小语种需求。
3. **流式实时预览（可选增强）**：`Paraformer-streaming` 或 `Zipformer-bilingual`（约 70MB〜150MB）
   - **作用**：提供“字字实时蹦出”的实时预览草稿，待 VAD 停顿截断后由 `SenseVoice` 替换为高精度终稿。
4. **多角色分辨（Speaker Diarization）双模型组合**：
   - **说话人切分模型**：`pyannote-segmentation-3.0 (Int8 ONNX)`（约 6MB），检测同一语音切片内的多人抢话与换人边界点。
   - **声纹特征提取模型**：阿里 3D-Speaker 开源的 `CAM++` 或 `ERes2Net (ONNX)`（约 25MB），提取 192/512 维高维声纹向量（Embedding）。

---

## 三、 整体系统架构与数据流设计

### 1. 系统分层架构全景图

```
+-----------------------------------------------------------------------------------+
|                                  表现层 (Flutter UI)                               |
|  [实时长会议录音台]     [多选通话录音批处理队列]      [音字同步播放器 & FTS5全文检索]   |
|  [API 转发服务控制台]   [声纹库管理与实名标记]        [Windows 双轨内录控制台]          |
+---------+-----------------------+-----------------------------+-------------------+
          |                       |                             |
+---------v-----------------------v-----------------------------v-------------------+
|                              核心业务与服务层 (Service Layer)                       |
|  +---------------------------+  +--------------------------+  +----------------+  |
|  | 后台保活与任务调度中心      |  | 本地 STT 转发服务器       |  | 音字同步控制器  |  |
|  | - Android Foreground Svc  |  | - HTTP (/v1/audio/...)   |  | - 二分查找时间戳|  |
|  | - WakeLock / WifiLock     |  | - WebSocket 流式接口      |  | - 拖拽定位Seek |  |
|  | - 批处理串行/并发调度队列  |  | - 系统级 RecognitionSvc  |  +----------------+  |
|  +---------------------------+  +--------------------------+                      |
+-----------------------------------------+-----------------------------------------+
                                          | (Dart FFI / Isolate 跨线程通信)
+-----------------------------------------v-----------------------------------------+
|                           C++ 原生推理与音频引擎层 (Native Layer)                   |
|  [FFmpeg 解码/重采样 16kHz] ──► [Silero VAD 切片] ──┬─► [SenseVoice 多语种转写]   |
|  [WASAPI / AudioRecord 采集]                        └─► [Pyannote + CAM++ 声纹聚类]|
+-----------------------------------------+-----------------------------------------+
                                          |
+-----------------------------------------v-----------------------------------------+
|                               数据持久层 (Storage Layer)                           |
|  [分段音频文件库 (.opus/.wav)]   [SQLite + FTS5 纪要数据库]   [预设实名声纹特征库]   |
+-----------------------------------------------------------------------------------+
```

### 2. 关键业务数据流向
1. **音频录制/导入流**：输入音频 $\to$ 环形缓冲区 / FFmpeg 重采样 $\to$ 16kHz 16-bit 单声道 PCM。
2. **切片与特征提取流**：PCM 流 $\to$ Silero VAD 切片 $\to$ pyannote 边界侦测 $\to$ CAM++ 声纹向量化。
3. **聚类与转写流**：
   - 离线模式：全局 AHC / 谱聚类分配角色 $\to$ SenseVoice 转写文本与字词级时间戳。
   - 实时模式：动态声纹质心池计算 Cosine 相似度 $\to$ 实时上屏并更新质心。
4. **持久化与检索流**：结果写入 SQLite `tasks` 与 `segments` 表 $\to$ 同步写入 `segments_fts` 虚拟表。

---

## 四、 核心功能模块详细设计

### 模块 A：多角色分辨（Speaker Diarization）双模式引擎

根据使用场景的差异，多角色分离分为两种核心模式：

#### 1. 模式 1：离线文件批处理（通话录音 / 外部音频导入）
* **物理声道预检（通话录音杀手锏）**：
  - 许多手机系统或通话录音 App 会将“本机麦克风声音”录在左声道、“对方听筒声音”录在右声道（立体声双通道）。
  - 导入时先进行双声道相关性检测：若判定左右声道为独立音频流，直接按物理左/右声道解耦为“角色 A / 角色 B”，**识别准确率 100% 且完全零算力消耗**。
* **单声道混合音频全局聚类**：
  - 调用 `sherpa-onnx` 的 `OfflineSpeakerDiarization` 管线；
  - `pyannote-segmentation` 执行滑动窗口切分；
  - `CAM++` 抽取所有片段的 Embedding 向量；
  - 执行**层次凝聚聚类（AHC）**或**自适应谱聚类（Spectral Clustering）**，自动确定说话人数量 $K$ 并打上标签；
  - 将分段精准送入 `SenseVoice` 识别出对应内容。

#### 2. 模式 2：实时会议记录（在线增量聚类 Online Clustering）
* 采用**动态声纹质心池（Dynamic Centroid Bank）**算法：
  - 当 VAD 判定一句话停顿结束（时长大于阈值，如 $\ge 0.8$ 秒），提取该段声纹向量 $V_{new}$。
  - 与当前会议已存在的声纹质心池 $\{C_1, C_2, \dots, C_k\}$ 计算余弦相似度：
    $$\text{CosineSim}(V_{new}, C_i) = \frac{V_{new} \cdot C_i}{\|V_{new}\| \|C_i\|}$$
  - **阈值判定**：
    - 若 $\max(\text{CosineSim}) \ge 0.65$，判定为角色 $i$，并通过指数移动平均（EMA）更新质心：
      $$C_i^{(new)} = \alpha C_i^{(old)} + (1 - \alpha) V_{new} \quad (\alpha \approx 0.8)$$
    - 若 $\max(\text{CosineSim}) < 0.65$，则判定为新角色 $C_{k+1}$。
* **实名声纹绑定库**：
  - 允许用户提前录制或直接在会议纪要中将某个角色标记为“张总”、“李工”；
  - 将对应声纹向量存入持久化声纹库；后续新会议开启时，自动与该库匹配，直接显示真实姓名。

---

### 模块 B：本地 STT 转发中心与全协议兼容服务

为了无缝接入听书软件、沉浸式翻译、第三方 AI 助手及系统语音输入，提供三层服务机制：

```
                              [外部调用方]
                                   │
       ┌───────────────────────────┼───────────────────────────┐
       ▼                           ▼                           ▼
[OpenAI 兼容 REST API]       [WebSocket 流式 API]        [Android 原生 RecognitionSvc]
POST /v1/audio/transcriptions  ws://.../v1/audio/stream   系统级语音引擎 (听书/输入法调用)
       │                           │                           │
       └───────────────────────────┼───────────────────────────┘
                                   ▼
                   [本地 Isolate 统一调度队列 (并发锁)]
                                   │
                                   ▼
                    [SenseVoice-Small 单例推理实例]
```

#### 1. 标准 OpenAI Whisper 兼容 REST API
* **监听地址**：`http://127.0.0.1:8765`（本机调用）或 `http://0.0.0.0:8765`（局域网协作）。
* **核心路由**：`POST /v1/audio/transcriptions`
* **协议规范**：
  - `Content-Type: multipart/form-data`
  - 参数：`file`（音频文件/切片）、`model`（默认或指定）、`language`（可选语种）、`response_format`（`json`、`text`、`srt`、`verbose_json`）。
  - **私有扩展参数**：`diarize=true`。开启时，在 `verbose_json` 的 `segments` 节点中增加 `speaker` 与 `speaker_id` 属性。

#### 2. 低延迟 WebSocket 流式 API
* **核心路由**：`ws://127.0.0.1:8765/v1/audio/stream`
* **协议流程**：
  - 握手成功后，客户端以二进制流形式持续推送 16kHz 16-bit 单声道 PCM 数据帧；
  - 服务端增量返回 JSON 识别结构体：
    ```json
    {
      "is_final": true,
      "segment_id": 108,
      "speaker": "张总",
      "speaker_id": "SPK_01",
      "start_ms": 32100,
      "end_ms": 35400,
      "language": "zh",
      "text": "这个项目的交付时间节点必须严格遵守。"
    }
    ```

#### 3. Android 原生系统级 `RecognitionService`
* 在 Android 宿主层继承 `android.speech.RecognitionService`，并注册于 `AndroidManifest.xml`；
* 用户在系统“首选语音输入服务”中选择“PolyScribe 离线语音引擎”；
* 任何调用 Android 原生 `SpeechRecognizer` 的第三方阅读器、听书 App 或输入法，将自动直接调用本系统的本地离线识别能力。

---

### 模块 C：超长会议后台保活、防 OOM 与流畅渲染方案

针对 2〜4 小时以上的长会议，必须彻底解决内存泄漏、系统强杀与列表渲染掉帧问题：

#### 1. Android 移动端后台保活三剑客
1. **前台服务（Foreground Service）**：
   - 录音及监听模式下启动常驻前台服务，并在通知栏展示动态驻留组件（会议时长、实时发言人、暂停/终止按钮）；
   - `AndroidManifest.xml` 声明双服务类型：`android:foregroundServiceType="microphone|mediaPlayback"`。
2. **底层硬件锁机制**：
   - 录音期间持有 `PowerManager.PARTIAL_WAKE_LOCK`，防止 CPU 息屏休眠；
   - 开启 API 局域网转发时，持有 `WIFI_MODE_FULL_HIGH_PERF` 保证 Wi-Fi 通道畅通。
3. **电池白名单自动引导**：
   - 检查 `PowerManager.isIgnoringBatteryOptimizations`，首次运行主动弹窗引导用户授予“无限制”电池使用策略。
4. **推理线程隔离**：
   - 推理逻辑全部运行在独立的 `InferenceWorkerIsolate` 中，绑定 2〜4 核运行，杜绝占用 UI 线程导致丢帧。

#### 2. 环形缓冲区与分段落盘（零内存膨胀）
* 采集的音频严禁长久留存在内存中；
* 内存中仅维护一个 **30 秒定长环形缓冲区 (Ring Buffer)** 用于 VAD 判定与特征截取；
* 数据流每隔 **5 分钟** 自动切片落盘（或追加写入单个 `.opus`/`.wav` 容器）；
* 录制时长即使长达 10 小时，内存占用依然平稳在固定水位。

#### 3. 万级长文本虚拟化流畅渲染
* 会议详情页采用 Flutter `CustomScrollView` + `SliverList.builder`，结合 `scrollable_positioned_list`；
* Viewport 视口内仅实例化可见的 10〜15 个段落卡片，滑出即回收；
* 新增句子追加仅通过局部通知驱动，严禁全量重建 Widget 树。

---

### 模块 D：音字同步播放、拖拽定位与全文检索系统

#### 1. 正向联动（播音频 $\to$ 文本高亮并居中）
* 播放器以 `100ms` 为周期上报播放时间戳 `currentMs`；
* 在已按 `start_ms` 排序的 `segments` 内存缓存中，执行**二分查找（Binary Search，时间复杂度 $O(\log N)$）**；
* 命中满足 `start_ms <= currentMs <= end_ms` 的目标段落；
* 若用户当前未处于手动滑屏状态（`!isUserTouching`），自动平滑居中滚动至目标卡片。

#### 2. 反向联动（点击/拖拽文本 $\to$ 音频精准跳转）
* **段落级跳转**：轻触气泡，播放器直接 Seek 至 `segment.startMs`。
* **字词级拖拽定位（高阶交互）**：
  - 基于 `SenseVoice` 输出的词级别时间戳（保存在 `words_json`）；
  - 手指在文字行滑动时，动态计算字字符索引并提取精确的毫秒时间；
  - 界面显示浮动时间放大镜气泡，松手瞬间音频精准跳转至该字符发音起点。

---

### 模块 E：Windows 桌面端专属增强（双轨内录与桌面生产力）

1. **WASAPI Loopback（系统内录）+ 麦克风双轨分离**：
   - Windows 端原生支持通过 WASAPI Loopback 抓取电脑扬声器发出的声音（远端腾讯会议、Zoom、网页外语音视频）；
   - 同时单独开启麦克风采集本地声音；
   - 天然将音频拆分为“我方轨道”与“远端轨道”，免除复杂的声纹切分运算即可实现无误分离。
2. **多格式生产力导出中心**：
   - **字幕格式**：带说话人标签与毫秒级时间戳的标准 `.srt` / `.vtt` 文件；
   - **文档格式**：结构化会议纪要 Markdown、Word (`.docx`)、PDF；
   - **归档包**：包含完整音频与轻量 SQLite 数据的独立归档文件。

---

## 五、 数据持久化与存储层物理设计 (SQLite + FTS5)

```sql
-- 1. 任务与会议主表
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    source_type TEXT NOT NULL,       -- 'live_meeting' (实时会议) | 'imported_audio' (导入音频)
    audio_path TEXT NOT NULL,        -- 音频文件物理存储路径
    duration_ms INTEGER DEFAULT 0,  -- 总音频时长 (毫秒)
    created_at INTEGER NOT NULL,     -- 创建时间戳 (毫秒)
    status TEXT NOT NULL             -- 'recording' | 'queued' | 'processing' | 'completed' | 'error'
);

-- 2. 转写段落与时间戳明细表
CREATE TABLE segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    speaker_id TEXT NOT NULL,        -- 角色唯一标识 (如 'SPK_01')
    speaker_name TEXT,               -- 用户自定义昵称/实名 (如 '张总')
    start_ms INTEGER NOT NULL,       -- 起始时间 (毫秒)
    end_ms INTEGER NOT NULL,         -- 结束时间 (毫秒)
    text TEXT NOT NULL,              -- 转写内容
    words_json TEXT,                 -- 字词级时间戳 [{"w":"你","s":100,"e":250},{"w":"好","s":260,"e":400}]
    FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX idx_segments_task_time ON segments(task_id, start_ms);

-- 3. FTS5 全文检索引擎虚拟表 (支持毫秒级跨纪要检索)
CREATE VIRTUAL TABLE segments_fts USING fts5(
    text,
    task_id UNINDEXED,
    segment_id UNINDEXED,
    tokenize = 'simple'              -- 集成 simple 中文拼音与字级分词器
);

-- 4. 实名声纹库表 (用于跨会议自动识别实名)
CREATE TABLE voice_prints (
    id TEXT PRIMARY KEY,
    person_name TEXT NOT NULL,       -- 实名名称 (如 '张总')
    embedding BLOB NOT NULL,         -- 192/512维声纹向量二进制浮点数据
    sample_count INTEGER DEFAULT 1,  -- 参与均值更新的样本数
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

---

## 六、 视觉与交互规范（多角色专属 UI 色板）

在多角色气泡与波形渲染中，系统统一采用以下色盲友好、高对比度的标准调色盘：

| 角色序号 | 预设角色定义 | 规范色彩名称 | HEX 色值 | 预览/适用场景 |
| :---: | :--- | :--- | :---: | :--- |
| **角色 1** | 主讲人 / 我方发言 | **活力珊瑚橙** | `#F97316` | 主态气泡、高亮波形核心色 |
| **角色 2** | 对方 / 主要嘉宾 A | **翡翠薄荷绿** | `#10B981` | 响应气泡、第二发言人 |
| **角色 3** | 参会嘉宾 B | **星云电光蓝** | `#38BDF8` | 协作发言人 |
| **角色 4** | 参会嘉宾 C | **紫罗兰** | `#A855F7` | 外部访客、偶发发言 |
| **角色 5** | 参会嘉宾 D | **琥珀金** | `#EAB308` | 特邀发言人 |
| **角色 6** | 参会嘉宾 E 及其他 | **玫瑰粉** | `#EC4899` | 自由讨论、背景多角色 |

---

## 七、 关键工程避坑指南与最佳实践

1. **模型生命周期与单例驻留（杜绝频繁冷启动）**
   - `SenseVoice` 与声纹模型初始化通常需耗费 1〜2 秒；
   - 务必使用单例模式常驻于后台 Worker Isolate，避免在每个 API 请求或音频切片到来时重新加载导致 OOM 和高延迟；
   - **休眠策略**：设置 15 分钟无活动计时器，超时后自动释放模型显存/内存。
2. **极短语音的角色漂移抑制（消除“嗯、啊、对”误识别）**
   - 声纹提取模型在语音时长 $< 0.8$ 秒时，特征向量极度离散不稳定，极易误分类；
   - **解法**：对时长小于 0.8 秒的超短段落，若前后无明显换人停顿（停顿 $< 400\text{ms}$），直接**继承上一句的角色 ID**，且该段向量**不参与全局质心更新**。
3. **通话录音双声道优先策略**
   - 导入音频前首选检测左右声道互相关系数；
   - 若互相关极低（独立双声道），直接跳过耗算力的声纹聚类模型，100% 准确完成左右声道角色分割。
4. **iOS 移动端特殊保活适配**
   - iOS 必须在 `Info.plist` 中声明 `UIBackgroundModes` 包含 `audio`；
   - 只要应用持有活动的音频采集会话（Audio Session）或播放无声音频流，即可保持后台存活及内置 HTTP 服务运行。

---

## 八、 分阶段开发计划与工程里程碑 (Roadmap)

```
[第一阶段: 引擎打通] ──► [第二阶段: 批处理与音字交互] ──► [第三阶段: 实时长会议保活] ──► [第四阶段: 本地STT服务] ──► [第五阶段: Windows端与发版]
   (第 1 ~ 2 周)               (第 3 ~ 4 周)                 (第 5 ~ 6 周)              (第 7 ~ 8 周)             (第 9 ~ 10 周)
```

### 第一阶段：底层推理引擎与音频管线打通（第 1 ～ 2 周）
* **目标**：在 Android 平台跑通端侧离线语音识别 + 声纹提取的最小可行性闭环（MVP）。
* **关键任务**：
  1. 初始化 Flutter 工程，配置工程包名 `com.polyscribe.audio`，集成 `sherpa_onnx` 与 `ffmpeg_kit_flutter_min`。
  2. 实现模型资产管理器，支持应用启动时自动解压/加载 `Silero-VAD`、`SenseVoice-Small-int8`、`pyannote` 与 `CAM++` 四个模型。
  3. 搭建独立后台 `InferenceWorkerIsolate`，跑通音频解码、重采样、离线聚类与 ASR 流水线。

### 第二阶段：多选录音批处理与音字同步播放器（第 3 ～ 4 周）
* **目标**：实现通话录音多文件队列导入、离线批处理转写、二分音字同步播放与全文检索。
* **关键任务**：
  1. 初始化 SQLite 数据库与 FTS5 全文检索表，接入 `simple` 分词扩展。
  2. 实现多选文件选择器、任务排队调度器、双声道物理分离预检机制。
  3. 构建音字同步播放详情页：集成波形进度条、二分查找高亮滚动、Token 级拖拽 Seek。

### 第三阶段：实时长会议记录与移动端后台保活（第 5 ～ 6 周）
* **目标**：实现 3 小时以上连续高稳定会议录音，息屏与切后台不掉线、零内存膨胀。
* **关键任务**：
  1. 开发麦克风实时采集管道、30 秒环形缓冲区与分段写盘容灾机制。
  2. 实现在线动态声纹质心池（Online Clustering）及实名声纹库绑定。
  3. 开发 Android 原生前台服务（带通知栏控制项）、硬件锁（WakeLock）及电池优化引导。
  4. 完成 3 小时长音频压力测试，监控热指标与内存水位。

### 第四阶段：本地 STT API 转发服务与系统语音接口（第 7 ～ 8 周）
* **目标**：将应用打造为系统本地语音转写中枢，支持第三方工具与系统级语音输入调用。
* **关键任务**：
  1. 基于 `shelf` 构建兼容 OpenAI Whisper 格式的 HTTP `/v1/audio/transcriptions` 接口与 WebSocket 流式接口。
  2. 实现模型推理请求排队锁，避免并发调用引发内存超载。
  3. 实现 Android 原生 `RecognitionService` 桥接层，支持手机系统级语音引擎替换。
  4. 构筑 API 转发控制台 UI，支持局域网 IP 查看、配置复制及调用日志监控。

### 第五阶段：Windows 桌面端适配与进阶导出打磨（第 9 ～ 10 周）
* **目标**：完成 Windows 桌面端适配，并实现系统内录与多格式生产力导出。
* **关键任务**：
  1. 开启 Flutter Windows 编译目标，调试 `sherpa-onnx` C++ 动态链接库与硬件加速支持。
  2. 实现 WASAPI Loopback 双轨内录（扬声器内录 + 麦克风），针对腾讯会议/Zoom/直播场景优化。
  3. 交付多格式导出中心（SRT/VTT 字幕、Markdown 纪要、Word 及带时间戳归档包）。
