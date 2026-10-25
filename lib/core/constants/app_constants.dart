/// PolyScribe (声织纪要) 系统核心常量
class AppConstants {
  AppConstants._();

  // 系统标识
  static const String appFullName = '声织纪要';
  static const String appShortName = '声织';
  static const String appEnglishName = 'PolyScribe';
  static const String appSlogan = '多角色离线语音转写与声纹中枢';
  static const String appId = 'com.polyscribe.audio';
  static const String appVersion = 'v0.2.0-beta.2';
  static const int appBuildNumber = 202;

  // 音频处理核心规格
  static const int sampleRate = 16000; // 统一 16kHz
  static const int channels = 1;       // 单声道
  static const int bitsPerSample = 16; // 16-bit PCM

  // 本地转发服务配置
  static const int defaultServerPort = 8765;
  static const String serverIdentifier = 'PolyScribe-Local-STT/1.0';
  static const String mdnsServiceType = '_polyscribe-stt._tcp.local.';

  // 声纹与聚类参数 (经 CAM++ 192维向量超球面对齐调优，彻底抑制同人分裂多角)
  static const double speakerSimilarityThreshold = 0.42; // 余弦相似度判同阈值 (从 0.52 下调至 0.42，精准覆盖自然语气波动与情绪起伏)
  static const double emaAlpha = 0.85;                    // 质心更新指数平滑系数 (更重历史稳态质心)
  static const int minValidSpeechMs = 1000;               // 声纹质心迭代最小有效时长 (1000ms，短于此不污染质心)
  static const int maxSpeakerShiftGapMs = 4500;           // 角色继承最大允许停顿间隔 (4500ms，4.5秒内自然喘息与停顿直接继承上一角色)

  // 内存防 OOM 控制
  static const int ringBufferSeconds = 30;                // 30秒定长环形内存缓冲区
  static const int autoChunkFlushMinutes = 5;             // 5分钟分段自动落盘
  static const int modelIdleReleaseMinutes = 15;          // 15分钟空闲自动休眠释放
}
