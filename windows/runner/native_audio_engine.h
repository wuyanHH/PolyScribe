#ifndef RUNNER_NATIVE_AUDIO_ENGINE_H_
#define RUNNER_NATIVE_AUDIO_ENGINE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <windows.h>

constexpr UINT WM_APP_DECODE_RESULT = WM_APP + 101;

// 异步解码结果跨线程调度载荷
struct DecodeCallbackPayload {
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  bool ok;
  std::string err_msg;
};

// Windows 原生音频引擎：
// 1. 基于 Media Foundation (IMFSourceReader) 的全格式离线音频解码与 16kHz WAV 转换器
// 2. 基于 WASAPI Process Loopback + Endpoint Loopback + 麦克风捕获的全场景实时录音中枢
class NativeAudioEngine {
 public:
  static NativeAudioEngine& Instance();

  // 注册 Flutter MethodChannel 并绑定主窗口句柄以便跨线程安全派发结果
  void RegisterChannel(flutter::BinaryMessenger* messenger, HWND window_handle = nullptr);

  // 销毁并释放所有音频采集线程
  void Shutdown();

 private:
  NativeAudioEngine();
  ~NativeAudioEngine();

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 离线全格式音频解码为 16kHz 单声道 16-bit WAV
  static bool DecodeFileTo16kMonoWav(const std::wstring& input_path,
                                     const std::wstring& output_path,
                                     int target_sample_rate,
                                     std::string* out_error);

  // 启动实时 WASAPI 录制 ("mic", "speaker", "dual")
  bool StartRecording(const std::wstring& file_path, const std::string& mode);
  void PauseRecording();
  void ResumeRecording();
  std::wstring StopRecording();

  // 后台 WASAPI 采集主循环
  void CaptureThreadMain(std::wstring file_path, std::string mode);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_handle_{nullptr};

  std::atomic<bool> is_recording_{false};
  std::atomic<bool> is_paused_{false};
  std::atomic<bool> stop_requested_{false};
  std::atomic<double> current_amplitude_{0.0};

  std::thread capture_thread_;
  std::wstring current_file_path_;

  std::mutex buffer_mutex_;
  std::vector<int16_t> pending_pcm_16k_;
};

#endif  // RUNNER_NATIVE_AUDIO_ENGINE_H_
