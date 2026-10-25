#include "native_audio_engine.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/implements.h>

#include <algorithm>
#include <cmath>
#include <cstring>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;

namespace {

// UTF-8 与 UTF-16 互转辅助函数
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int count = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (count <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      &wide[0], count);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int count = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                  static_cast<int>(wide.size()), nullptr, 0,
                                  nullptr, nullptr);
  if (count <= 0) return std::string();
  std::string utf8(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      &utf8[0], count, nullptr, nullptr);
  return utf8;
}

// 判断 WAVEFORMATEX 是否为 IEEE 32-bit Float 格式
bool IsWaveFormatFloat(const WAVEFORMATEX* wf) {
  if (!wf) return false;
  if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT && wf->wBitsPerSample == 32) {
    return true;
  }
  if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE && wf->cbSize >= 22) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
    if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) &&
        wf->wBitsPerSample == 32) {
      return true;
    }
  }
  return false;
}

// 判断 WAVEFORMATEX 是否为 16-bit PCM 格式
bool IsWaveFormatPcm16(const WAVEFORMATEX* wf) {
  if (!wf) return false;
  if (wf->wFormatTag == WAVE_FORMAT_PCM && wf->wBitsPerSample == 16) {
    return true;
  }
  if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE && wf->cbSize >= 22) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
    if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM) &&
        wf->wBitsPerSample == 16) {
      return true;
    }
  }
  return false;
}

// 将任意硬件缓冲帧 (Float32 / PCM16 / PCM24 / PCM32) 提取并下混为单声道 float 数组
void ConvertFramesToMonoFloat(const BYTE* data,
                              UINT32 num_frames,
                              const WAVEFORMATEX* wf,
                              bool is_silent,
                              std::vector<float>* out_mono) {
  if (num_frames == 0 || !wf || !out_mono) return;
  size_t old_size = out_mono->size();
  out_mono->resize(old_size + num_frames, 0.0f);
  if (is_silent || !data) {
    return;
  }

  const UINT32 channels = std::max<UINT32>(1, wf->nChannels);
  const bool is_float = IsWaveFormatFloat(wf);
  const bool is_pcm16 = IsWaveFormatPcm16(wf);
  const UINT32 bytes_per_sample = std::max<UINT32>(1, wf->wBitsPerSample / 8);
  const UINT32 frame_stride = wf->nBlockAlign > 0
                                  ? wf->nBlockAlign
                                  : (channels * bytes_per_sample);

  float* dst = out_mono->data() + old_size;
  for (UINT32 f = 0; f < num_frames; ++f) {
    const BYTE* frame_ptr = data + static_cast<size_t>(f) * frame_stride;
    float sum = 0.0f;
    for (UINT32 c = 0; c < channels; ++c) {
      const BYTE* sample_ptr = frame_ptr + static_cast<size_t>(c) * bytes_per_sample;
      float sample_val = 0.0f;
      if (is_float) {
        std::memcpy(&sample_val, sample_ptr, sizeof(float));
        if (std::isnan(sample_val) || std::isinf(sample_val)) {
          sample_val = 0.0f;
        }
      } else if (is_pcm16) {
        int16_t s16 = 0;
        std::memcpy(&s16, sample_ptr, sizeof(int16_t));
        sample_val = static_cast<float>(s16) / 32768.0f;
      } else if (bytes_per_sample == 3) {
        int32_t v = sample_ptr[0] | (sample_ptr[1] << 8) | (sample_ptr[2] << 16);
        if (v & 0x800000) v |= ~0xFFFFFF;
        sample_val = static_cast<float>(v) / 8388608.0f;
      } else if (bytes_per_sample == 4) {
        int32_t s32 = 0;
        std::memcpy(&s32, sample_ptr, sizeof(int32_t));
        sample_val = static_cast<float>(static_cast<double>(s32) / 2147483648.0);
      }
      sum += sample_val;
    }
    dst[f] = std::clamp(sum / static_cast<float>(channels), -1.0f, 1.0f);
  }
}

// 带抗混叠均值滤波的采样率转换 (src_rate -> dst_rate)
std::vector<float> ResampleMonoFloat(const std::vector<float>& input,
                                     UINT32 src_rate,
                                     UINT32 dst_rate) {
  if (input.empty() || src_rate == 0 || dst_rate == 0) return {};
  if (src_rate == dst_rate) return input;

  const double ratio = static_cast<double>(src_rate) / static_cast<double>(dst_rate);
  const size_t out_len = static_cast<size_t>(std::floor(static_cast<double>(input.size()) / ratio));
  if (out_len == 0) return {};

  std::vector<float> output(out_len, 0.0f);
  const int max_idx = static_cast<int>(input.size()) - 1;

  if (ratio > 1.5) {
    // 下采样抗混叠均值滤波 (带双向严格 clamp 边界保护)
    const int half_win = std::max(1, static_cast<int>(std::floor(ratio * 0.5)));
    for (size_t i = 0; i < out_len; ++i) {
      const int center = static_cast<int>(std::round(static_cast<double>(i) * ratio));
      const int start = std::clamp(center - half_win, 0, max_idx);
      const int end = std::clamp(center + half_win, start, max_idx);
      float sum = 0.0f;
      for (int k = start; k <= end; ++k) {
        sum += input[static_cast<size_t>(k)];
      }
      const int count = end - start + 1;
      output[i] = count > 0 ? (sum / static_cast<float>(count)) : 0.0f;
    }
  } else {
    for (size_t i = 0; i < out_len; ++i) {
      const double src_pos = static_cast<double>(i) * ratio;
      const size_t idx0 = std::min(static_cast<size_t>(std::floor(src_pos)), static_cast<size_t>(max_idx));
      const size_t idx1 = std::min(idx0 + 1, static_cast<size_t>(max_idx));
      const float frac = static_cast<float>(std::clamp(src_pos - static_cast<double>(idx0), 0.0, 1.0));
      output[i] = input[idx0] * (1.0f - frac) + input[idx1] * frac;
    }
  }
  return output;
}

// 写入标准 44 字节 RIFF WAVE 文件头
void WriteWavHeader(HANDLE file_handle, UINT32 sample_rate, UINT32 data_bytes) {
  if (file_handle == INVALID_HANDLE_VALUE) return;

  struct WavHeader {
    char riff[4] = {'R', 'I', 'F', 'F'};
    uint32_t overall_size = 0;
    char wave[4] = {'W', 'A', 'V', 'E'};
    char fmt_chunk_marker[4] = {'f', 'm', 't', ' '};
    uint32_t length_of_fmt = 16;
    uint16_t format_type = 1;  // PCM
    uint16_t channels = 1;     // Mono
    uint32_t sample_rate = 16000;
    uint32_t byterate = 32000;
    uint16_t block_align = 2;
    uint16_t bits_per_sample = 16;
    char data_chunk_header[4] = {'d', 'a', 't', 'a'};
    uint32_t data_size = 0;
  } header;

  header.sample_rate = sample_rate;
  header.byterate = sample_rate * 2;
  header.data_size = data_bytes;
  header.overall_size = data_bytes + 36;

  LARGE_INTEGER zero_pos = {};
  SetFilePointerEx(file_handle, zero_pos, nullptr, FILE_BEGIN);
  DWORD written = 0;
  WriteFile(file_handle, &header, sizeof(header), &written, nullptr);
}

// Windows 10 Build 20348+ / Windows 11 进程级音频回环 (Process Loopback) 异步激活回调器
// 核心优势：直接从 Windows Audio Session 层截取全系统其他应用的播放声音，
// 彻底无视系统静音 (Mute)、系统主音量调为 0、以及外放/有线耳机/蓝牙耳机切换！
class ProcessLoopbackActivateHandler
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          IActivateAudioInterfaceCompletionHandler,
                          FtmBase> {
 public:
  ProcessLoopbackActivateHandler() {
    event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  }
  ~ProcessLoopbackActivateHandler() override {
    if (event_) {
      CloseHandle(event_);
      event_ = nullptr;
    }
  }

  STDMETHODIMP ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT hr_activate = E_FAIL;
    ComPtr<IUnknown> punk_audio_interface;
    HRESULT hr = operation->GetActivateResult(&hr_activate, &punk_audio_interface);
    if (SUCCEEDED(hr) && SUCCEEDED(hr_activate) && punk_audio_interface) {
      punk_audio_interface.As(&audio_client_);
      activate_hr_ = S_OK;
    } else {
      activate_hr_ = FAILED(hr_activate) ? hr_activate : hr;
    }
    if (event_) {
      SetEvent(event_);
    }
    return S_OK;
  }

  ComPtr<IAudioClient> WaitAndGetClient(DWORD timeout_ms = 2000) {
    if (event_) {
      WaitForSingleObject(event_, timeout_ms);
    }
    return audio_client_;
  }

 private:
  HANDLE event_ = nullptr;
  HRESULT activate_hr_ = E_FAIL;
  ComPtr<IAudioClient> audio_client_;
};

// 初始化 Windows 10/11 Process Loopback 客户端 (捕获除当前进程树外的所有系统应用音频)
bool TryCreateProcessLoopbackClient(ComPtr<IAudioClient>* out_client,
                                    ComPtr<IAudioCaptureClient>* out_capture,
                                    WAVEFORMATEX* out_format) {
  if (!out_client || !out_capture || !out_format) return false;

  AUDIOCLIENT_ACTIVATION_PARAMS activation_params = {};
  activation_params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activation_params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  activation_params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT activate_prop = {};
  activate_prop.vt = VT_BLOB;
  activate_prop.blob.cbSize = sizeof(activation_params);
  activate_prop.blob.pBlobData = reinterpret_cast<BYTE*>(&activation_params);

  ComPtr<ProcessLoopbackActivateHandler> handler =
      Microsoft::WRL::Make<ProcessLoopbackActivateHandler>();
  if (!handler) return false;

  ComPtr<IActivateAudioInterfaceAsyncOperation> async_op;
  HRESULT hr = ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &activate_prop, handler.Get(), &async_op);
  if (FAILED(hr)) return false;

  ComPtr<IAudioClient> client = handler->WaitAndGetClient(2000);
  if (!client) return false;

  // Process Loopback 支持直接请求 16kHz 单声道 32-bit Float (通过内核 AUTOCONVERTPCM)
  WAVEFORMATEX fmt = {};
  fmt.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
  fmt.nChannels = 1;
  fmt.nSamplesPerSec = 16000;
  fmt.wBitsPerSample = 32;
  fmt.nBlockAlign = (fmt.nChannels * fmt.wBitsPerSample) / 8;
  fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
  fmt.cbSize = 0;

  DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK |
                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2000000, 0, &fmt,
                          nullptr);
  if (FAILED(hr)) {
    // 回退尝试 48kHz 双声道 Float
    fmt.nChannels = 2;
    fmt.nSamplesPerSec = 48000;
    fmt.nBlockAlign = (fmt.nChannels * fmt.wBitsPerSample) / 8;
    fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2000000, 0, &fmt,
                            nullptr);
  }
  if (FAILED(hr)) return false;

  ComPtr<IAudioCaptureClient> capture;
  hr = client->GetService(IID_PPV_ARGS(&capture));
  if (FAILED(hr) || !capture) return false;

  hr = client->Start();
  if (FAILED(hr)) return false;

  *out_client = client;
  *out_capture = capture;
  *out_format = fmt;
  return true;
}

}  // namespace

NativeAudioEngine& NativeAudioEngine::Instance() {
  static NativeAudioEngine instance;
  return instance;
}

NativeAudioEngine::NativeAudioEngine() = default;

NativeAudioEngine::~NativeAudioEngine() {
  Shutdown();
}

void NativeAudioEngine::Shutdown() {
  if (is_recording_.load()) {
    StopRecording();
  }
}

void NativeAudioEngine::RegisterChannel(flutter::BinaryMessenger* messenger, HWND window_handle) {
  window_handle_ = window_handle;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.polyscribe.audio/native_audio",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        this->HandleMethodCall(call, std::move(result));
      });
}

void NativeAudioEngine::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "decodeAudioToWav") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (!args) {
      result->Error("INVALID_ARGS", "Missing arguments map");
      return;
    }

    std::string input_utf8;
    std::string output_utf8;
    int target_rate = 16000;

    auto it_in = args->find(flutter::EncodableValue("inputPath"));
    if (it_in != args->end() && std::holds_alternative<std::string>(it_in->second)) {
      input_utf8 = std::get<std::string>(it_in->second);
    }
    auto it_out = args->find(flutter::EncodableValue("outputPath"));
    if (it_out != args->end() && std::holds_alternative<std::string>(it_out->second)) {
      output_utf8 = std::get<std::string>(it_out->second);
    }
    auto it_rate = args->find(flutter::EncodableValue("sampleRate"));
    if (it_rate != args->end() && std::holds_alternative<int32_t>(it_rate->second)) {
      target_rate = std::get<int32_t>(it_rate->second);
    }

    if (input_utf8.empty() || output_utf8.empty()) {
      result->Error("INVALID_PATH", "Input or output path is empty");
      return;
    }

    // 在独立后台线程执行 Media Foundation 解码，并通过 PostMessage 跨线程调度回主线程调用 Result->Success
    HWND target_hwnd = window_handle_;
    auto shared_result = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));

    std::thread([input_utf8, output_utf8, target_rate, shared_result, target_hwnd]() {
      std::string err_msg;
      bool ok = DecodeFileTo16kMonoWav(Utf8ToWide(input_utf8),
                                       Utf8ToWide(output_utf8),
                                       target_rate,
                                       &err_msg);

      if (target_hwnd && IsWindow(target_hwnd)) {
        auto* payload = new DecodeCallbackPayload{shared_result, ok, err_msg};
        if (!PostMessageW(target_hwnd, WM_APP_DECODE_RESULT, 0, reinterpret_cast<LPARAM>(payload))) {
          // 若 PostMessage 失败，则兜底清理并直接在当前线程返回
          delete payload;
          flutter::EncodableMap resp;
          resp[flutter::EncodableValue("success")] = flutter::EncodableValue(ok);
          if (!ok) resp[flutter::EncodableValue("error")] = flutter::EncodableValue(err_msg);
          shared_result->Success(flutter::EncodableValue(resp));
        }
      } else {
        // 无窗口句柄兜底返回
        flutter::EncodableMap resp;
        resp[flutter::EncodableValue("success")] = flutter::EncodableValue(ok);
        if (!ok) resp[flutter::EncodableValue("error")] = flutter::EncodableValue(err_msg);
        shared_result->Success(flutter::EncodableValue(resp));
      }
    }).detach();
    return;
  }

  if (method == "startRecording") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    std::string file_path_utf8;
    std::string mode = "dual";
    if (args) {
      auto it_path = args->find(flutter::EncodableValue("filePath"));
      if (it_path != args->end() && std::holds_alternative<std::string>(it_path->second)) {
        file_path_utf8 = std::get<std::string>(it_path->second);
      }
      auto it_mode = args->find(flutter::EncodableValue("mode"));
      if (it_mode != args->end() && std::holds_alternative<std::string>(it_mode->second)) {
        mode = std::get<std::string>(it_mode->second);
      }
    }

    bool ok = StartRecording(Utf8ToWide(file_path_utf8), mode);
    flutter::EncodableMap resp;
    resp[flutter::EncodableValue("success")] = flutter::EncodableValue(ok);
    resp[flutter::EncodableValue("filePath")] = flutter::EncodableValue(file_path_utf8);
    result->Success(flutter::EncodableValue(resp));
    return;
  }

  if (method == "pauseRecording") {
    PauseRecording();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "resumeRecording") {
    ResumeRecording();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "stopRecording") {
    std::wstring final_path = StopRecording();
    flutter::EncodableMap resp;
    resp[flutter::EncodableValue("filePath")] =
        flutter::EncodableValue(WideToUtf8(final_path));
    result->Success(flutter::EncodableValue(resp));
    return;
  }

  if (method == "pollRealtimeAudio") {
    std::vector<uint8_t> pcm_bytes;
    {
      std::lock_guard<std::mutex> lock(buffer_mutex_);
      if (!pending_pcm_16k_.empty()) {
        size_t byte_len = pending_pcm_16k_.size() * sizeof(int16_t);
        pcm_bytes.resize(byte_len);
        std::memcpy(pcm_bytes.data(), pending_pcm_16k_.data(), byte_len);
        pending_pcm_16k_.clear();
      }
    }

    flutter::EncodableMap resp;
    resp[flutter::EncodableValue("pcmBytes")] = flutter::EncodableValue(pcm_bytes);
    resp[flutter::EncodableValue("amplitude")] =
        flutter::EncodableValue(current_amplitude_.load());
    resp[flutter::EncodableValue("isRecording")] =
        flutter::EncodableValue(is_recording_.load() && !is_paused_.load());
    result->Success(flutter::EncodableValue(resp));
    return;
  }

  result->NotImplemented();
}

// 使用 Windows Media Foundation (IMFSourceReader) 将任意外部音频文件解码为 16kHz 单声道 16-bit WAV
bool NativeAudioEngine::DecodeFileTo16kMonoWav(const std::wstring& input_path,
                                               const std::wstring& output_path,
                                               int target_sample_rate,
                                               std::string* out_error) {
  HRESULT hr_co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool need_co_uninit = SUCCEEDED(hr_co);

  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  if (FAILED(hr)) {
    if (out_error) *out_error = "MFStartup failed";
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  ComPtr<IMFSourceReader> reader;
  hr = MFCreateSourceReaderFromURL(input_path.c_str(), nullptr, &reader);
  if (FAILED(hr) || !reader) {
    if (out_error) *out_error = "MFCreateSourceReaderFromURL failed";
    MFShutdown();
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  // 仅激活第一条音频流
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  hr = reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
  if (FAILED(hr)) {
    if (out_error) *out_error = "No audio stream found in file";
    MFShutdown();
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  // 请求解码器输出未压缩 PCM 或 IEEE Float
  ComPtr<IMFMediaType> partial_type;
  MFCreateMediaType(&partial_type);
  partial_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  partial_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);

  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
      partial_type.Get());
  if (FAILED(hr)) {
    // 若解码器原生只输出 Float，尝试请求 MFAudioFormat_Float
    partial_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    hr = reader->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
        partial_type.Get());
  }

  if (FAILED(hr)) {
    if (out_error) *out_error = "Failed to set uncompressed audio media type";
    MFShutdown();
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  ComPtr<IMFMediaType> uncompressed_type;
  hr = reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
      &uncompressed_type);
  if (FAILED(hr) || !uncompressed_type) {
    if (out_error) *out_error = "GetCurrentMediaType failed";
    MFShutdown();
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  WAVEFORMATEX* wf = nullptr;
  UINT32 wf_size = 0;
  hr = MFCreateWaveFormatExFromMFMediaType(uncompressed_type.Get(), &wf, &wf_size);
  if (FAILED(hr) || !wf) {
    if (out_error) *out_error = "MFCreateWaveFormatExFromMFMediaType failed";
    MFShutdown();
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  const UINT32 src_rate = wf->nSamplesPerSec > 0 ? wf->nSamplesPerSec : 16000;
  const UINT32 bytes_per_sample = std::max<UINT32>(1, wf->wBitsPerSample / 8);
  const UINT32 channels = std::max<UINT32>(1, wf->nChannels);
  const UINT32 frame_stride = wf->nBlockAlign > 0
                                  ? wf->nBlockAlign
                                  : (channels * bytes_per_sample);

  std::vector<float> all_mono_samples;
  all_mono_samples.reserve(static_cast<size_t>(src_rate) * 60);

  int consecutive_empty_samples = 0;
  const auto decode_start_time = std::chrono::steady_clock::now();

  while (true) {
    // 增加总体防挂死超时检查 (单个音频最长 180 秒)
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - decode_start_time).count();
    if (elapsed > 180) {
      if (out_error) *out_error = "Media Foundation decode timed out after 180s";
      break;
    }

    DWORD stream_flags = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &stream_flags, nullptr, &sample);
    if (FAILED(hr)) break;
    if (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (stream_flags & MF_SOURCE_READERF_ERROR) break;

    if (!sample) {
      consecutive_empty_samples++;
      if (consecutive_empty_samples > 30) {
        // 连续 30 次未产生有效采样数据帧，视同音频流已结束，安全跳出循环杜绝 CPU 死循环
        break;
      }
      continue;
    }
    consecutive_empty_samples = 0;

    // 如中途发生流格式变更，动态刷新 WAVEFORMATEX
    if (stream_flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      ComPtr<IMFMediaType> new_type;
      if (SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
              &new_type))) {
        WAVEFORMATEX* new_wf = nullptr;
        UINT32 new_size = 0;
        if (SUCCEEDED(MFCreateWaveFormatExFromMFMediaType(new_type.Get(),
                                                          &new_wf, &new_size)) &&
            new_wf) {
          CoTaskMemFree(wf);
          wf = new_wf;
        }
      }
    }

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer)) || !buffer) continue;

    BYTE* raw_ptr = nullptr;
    DWORD raw_len = 0;
    if (SUCCEEDED(buffer->Lock(&raw_ptr, nullptr, &raw_len))) {
      if (raw_ptr && raw_len >= frame_stride) {
        UINT32 frames = raw_len / frame_stride;
        ConvertFramesToMonoFloat(raw_ptr, frames, wf, false, &all_mono_samples);
      }
      buffer->Unlock();
    }
  }

  CoTaskMemFree(wf);
  reader.Reset();
  MFShutdown();

  if (all_mono_samples.empty()) {
    if (out_error) *out_error = "Decoded audio contains 0 samples";
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  // 重采样至目标采样率 (默认 16000Hz)
  const UINT32 dst_rate = target_sample_rate > 0
                              ? static_cast<UINT32>(target_sample_rate)
                              : 16000;
  std::vector<float> resampled =
      ResampleMonoFloat(all_mono_samples, src_rate, dst_rate);
  if (resampled.empty()) {
    if (out_error) *out_error = "Resample produced 0 samples";
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  // 去除直流偏置并做自适应弱信号音量归一化
  double mean = 0.0;
  for (float v : resampled) mean += v;
  mean /= static_cast<double>(resampled.size());

  float peak = 0.0f;
  double sum_sq = 0.0;
  for (float& v : resampled) {
    v -= static_cast<float>(mean);
    float av = std::fabs(v);
    if (av > peak) peak = av;
    sum_sq += static_cast<double>(v) * static_cast<double>(v);
  }
  double rms = std::sqrt(sum_sq / static_cast<double>(resampled.size()));
  if (peak > 0.002f && rms > 0.0003 && peak < 0.65f) {
    float gain = std::min(0.85f / peak, 25.0f);
    for (float& v : resampled) {
      v = std::clamp(v * gain, -1.0f, 1.0f);
    }
  }

  // 转换为 16-bit PCM 并写入输出 WAV 文件
  std::vector<int16_t> pcm16(resampled.size());
  for (size_t i = 0; i < resampled.size(); ++i) {
    float clamped = std::clamp(resampled[i], -1.0f, 1.0f);
    pcm16[i] = static_cast<int16_t>(std::round(clamped * 32767.0f));
  }

  HANDLE out_file = CreateFileW(output_path.c_str(), GENERIC_WRITE,
                                FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
  if (out_file == INVALID_HANDLE_VALUE) {
    if (out_error) *out_error = "Failed to open output WAV file for writing";
    if (need_co_uninit) CoUninitialize();
    return false;
  }

  const UINT32 data_bytes = static_cast<UINT32>(pcm16.size() * sizeof(int16_t));
  WriteWavHeader(out_file, dst_rate, data_bytes);
  DWORD written = 0;
  WriteFile(out_file, pcm16.data(), data_bytes, &written, nullptr);
  FlushFileBuffers(out_file);
  CloseHandle(out_file);

  if (need_co_uninit) CoUninitialize();
  return written == data_bytes;
}

bool NativeAudioEngine::StartRecording(const std::wstring& file_path,
                                       const std::string& mode) {
  if (is_recording_.load()) {
    StopRecording();
  }

  {
    std::lock_guard<std::mutex> lock(buffer_mutex_);
    pending_pcm_16k_.clear();
  }

  current_file_path_ = file_path;
  stop_requested_.store(false);
  is_paused_.store(false);
  is_recording_.store(true);
  current_amplitude_.store(0.0);

  capture_thread_ = std::thread(&NativeAudioEngine::CaptureThreadMain, this,
                                file_path, mode);
  return true;
}

void NativeAudioEngine::PauseRecording() {
  is_paused_.store(true);
  current_amplitude_.store(0.0);
}

void NativeAudioEngine::ResumeRecording() {
  is_paused_.store(false);
}

std::wstring NativeAudioEngine::StopRecording() {
  stop_requested_.store(true);
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
  is_recording_.store(false);
  is_paused_.store(false);
  current_amplitude_.store(0.0);
  return current_file_path_;
}

// 后台 WASAPI 采集核心循环：
// 支持：
// 1. 系统内录 (Process Loopback 捕获全系统进程音频 [无视静音/音量0/耳机切换] + Endpoint Loopback 双保险)
// 2. 麦克风采集 (默认通信/控制台麦克风硬件捕获)
// 3. 双路同步混音 ("dual")、弱信号自适应增益、16kHz 实时重采样与 WAV 实时落盘
void NativeAudioEngine::CaptureThreadMain(std::wstring file_path,
                                          std::string mode) {
  HRESULT hr_co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool need_co_uninit = SUCCEEDED(hr_co);

  const bool want_system = (mode == "speaker" || mode == "dual");
  const bool want_mic = (mode == "mic" || mode == "dual");

  // 打开目标 WAV 文件 (允许 Flutter / 其他读取器随时共享读取)
  HANDLE wav_file = CreateFileW(
      file_path.c_str(), GENERIC_WRITE | GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  UINT32 total_written_bytes = 0;
  if (wav_file != INVALID_HANDLE_VALUE) {
    WriteWavHeader(wav_file, 16000, 0);
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                   IID_PPV_ARGS(&enumerator));

  // --- 1. 初始化系统声音内录 (Process Loopback + Endpoint Loopback 双通道) ---
  ComPtr<IAudioClient> proc_loop_client;
  ComPtr<IAudioCaptureClient> proc_loop_capture;
  WAVEFORMATEX proc_loop_fmt = {};
  bool has_proc_loopback = false;

  ComPtr<IMMDevice> render_device;
  ComPtr<IAudioClient> endpoint_loop_client;
  ComPtr<IAudioCaptureClient> endpoint_loop_capture;
  WAVEFORMATEX* endpoint_loop_fmt = nullptr;
  std::wstring current_render_device_id;

  // 静音渲染保活流：防止系统无其他应用发声时 Endpoint Loopback 挂起
  ComPtr<IAudioClient> keepalive_render_client;
  ComPtr<IAudioRenderClient> keepalive_render_service;
  UINT32 keepalive_buffer_frames = 0;

  auto init_endpoint_loopback = [&]() {
    endpoint_loop_capture.Reset();
    if (endpoint_loop_client) {
      endpoint_loop_client->Stop();
      endpoint_loop_client.Reset();
    }
    if (keepalive_render_client) {
      keepalive_render_client->Stop();
      keepalive_render_client.Reset();
    }
    keepalive_render_service.Reset();
    if (endpoint_loop_fmt) {
      CoTaskMemFree(endpoint_loop_fmt);
      endpoint_loop_fmt = nullptr;
    }
    render_device.Reset();

    if (!enumerator) return;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                   &render_device)) ||
        !render_device) {
      enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &render_device);
    }
    if (!render_device) return;

    LPWSTR dev_id = nullptr;
    if (SUCCEEDED(render_device->GetId(&dev_id)) && dev_id) {
      current_render_device_id = dev_id;
      CoTaskMemFree(dev_id);
    }

    // 启动静音保活渲染流
    if (SUCCEEDED(render_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                          nullptr, &keepalive_render_client)) &&
        keepalive_render_client) {
      WAVEFORMATEX* ka_fmt = nullptr;
      if (SUCCEEDED(keepalive_render_client->GetMixFormat(&ka_fmt)) && ka_fmt) {
        if (SUCCEEDED(keepalive_render_client->Initialize(
                AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, ka_fmt, nullptr))) {
          keepalive_render_client->GetBufferSize(&keepalive_buffer_frames);
          if (SUCCEEDED(keepalive_render_client->GetService(
                  IID_PPV_ARGS(&keepalive_render_service))) &&
              keepalive_render_service) {
            BYTE* p_data = nullptr;
            if (SUCCEEDED(keepalive_render_service->GetBuffer(
                    keepalive_buffer_frames, &p_data))) {
              keepalive_render_service->ReleaseBuffer(
                  keepalive_buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT);
            }
            keepalive_render_client->Start();
          }
        }
        CoTaskMemFree(ka_fmt);
      }
    }

    // 启动 Endpoint Loopback 捕获流
    if (SUCCEEDED(render_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                          nullptr, &endpoint_loop_client)) &&
        endpoint_loop_client) {
      if (SUCCEEDED(endpoint_loop_client->GetMixFormat(&endpoint_loop_fmt)) &&
          endpoint_loop_fmt) {
        if (SUCCEEDED(endpoint_loop_client->Initialize(
                AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                2000000, 0, endpoint_loop_fmt, nullptr))) {
          if (SUCCEEDED(endpoint_loop_client->GetService(
                  IID_PPV_ARGS(&endpoint_loop_capture))) &&
              endpoint_loop_capture) {
            endpoint_loop_client->Start();
          }
        }
      }
    }
  };

  if (want_system) {
    // 1. 优先激活 Windows 10/11 Process Loopback (无视系统静音与耳机/外放切换)
    has_proc_loopback = TryCreateProcessLoopbackClient(
        &proc_loop_client, &proc_loop_capture, &proc_loop_fmt);
    // 2. 同时激活 Endpoint Loopback 作为双保险补充
    init_endpoint_loopback();
  }

  // --- 2. 初始化麦克风捕获 (Microphone Capture) ---
  ComPtr<IMMDevice> mic_device;
  ComPtr<IAudioClient> mic_client;
  ComPtr<IAudioCaptureClient> mic_capture;
  WAVEFORMATEX* mic_fmt = nullptr;

  if (want_mic && enumerator) {
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole,
                                                   &mic_device)) ||
        !mic_device) {
      enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &mic_device);
    }
    if (mic_device) {
      if (SUCCEEDED(mic_device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                         nullptr, &mic_client)) &&
          mic_client) {
        if (SUCCEEDED(mic_client->GetMixFormat(&mic_fmt)) && mic_fmt) {
          if (SUCCEEDED(mic_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                               2000000, 0, mic_fmt, nullptr))) {
            if (SUCCEEDED(mic_client->GetService(IID_PPV_ARGS(&mic_capture))) &&
                mic_capture) {
              mic_client->Start();
            }
          }
        }
      }
    }
  }

  // 读取单个 IAudioCaptureClient 当前所有可用包并重采样为 16kHz 单声道 float
  auto drain_capture_to_16k = [](IAudioCaptureClient* capture,
                                 const WAVEFORMATEX* fmt,
                                 std::vector<float>* out_16k) {
    if (!capture || !fmt || !out_16k) return;
    std::vector<float> raw_mono;
    UINT32 packet_length = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet_length)) &&
           packet_length > 0) {
      BYTE* data = nullptr;
      UINT32 frames_available = 0;
      DWORD flags = 0;
      HRESULT hr = capture->GetBuffer(&data, &frames_available, &flags,
                                      nullptr, nullptr);
      if (FAILED(hr)) break;
      bool is_silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      ConvertFramesToMonoFloat(data, frames_available, fmt, is_silent,
                               &raw_mono);
      capture->ReleaseBuffer(frames_available);
    }
    if (!raw_mono.empty()) {
      std::vector<float> resampled =
          ResampleMonoFloat(raw_mono, fmt->nSamplesPerSec, 16000);
      out_16k->insert(out_16k->end(), resampled.begin(), resampled.end());
    }
  };

  int device_check_counter = 0;
  float agc_running_peak = 0.25f;

  while (!stop_requested_.load()) {
    Sleep(20);

    // 保持静音渲染流活跃，并在每 1 秒检查一次用户是否插拔了耳机导致默认输出设备切换
    if (want_system) {
      if (keepalive_render_client && keepalive_render_service &&
          keepalive_buffer_frames > 0) {
        UINT32 padding = 0;
        if (SUCCEEDED(keepalive_render_client->GetCurrentPadding(&padding))) {
          UINT32 avail = keepalive_buffer_frames > padding
                             ? (keepalive_buffer_frames - padding)
                             : 0;
          if (avail > 0) {
            BYTE* p_data = nullptr;
            if (SUCCEEDED(keepalive_render_service->GetBuffer(avail, &p_data))) {
              keepalive_render_service->ReleaseBuffer(
                  avail, AUDCLNT_BUFFERFLAGS_SILENT);
            }
          }
        }
      }

      if (++device_check_counter >= 50 && enumerator) {
        device_check_counter = 0;
        ComPtr<IMMDevice> cur_dev;
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                          &cur_dev)) &&
            cur_dev) {
          LPWSTR dev_id = nullptr;
          if (SUCCEEDED(cur_dev->GetId(&dev_id)) && dev_id) {
            std::wstring new_id(dev_id);
            CoTaskMemFree(dev_id);
            if (new_id != current_render_device_id) {
              // 用户切换了外放/耳机，无缝热切换 Endpoint Loopback
              init_endpoint_loopback();
            }
          }
        }
      }
    }

    std::vector<float> proc_sys_16k;
    std::vector<float> endp_sys_16k;
    std::vector<float> mic_16k;

    if (want_system) {
      if (has_proc_loopback && proc_loop_capture) {
        drain_capture_to_16k(proc_loop_capture.Get(), &proc_loop_fmt,
                             &proc_sys_16k);
      }
      if (endpoint_loop_capture && endpoint_loop_fmt) {
        drain_capture_to_16k(endpoint_loop_capture.Get(), endpoint_loop_fmt,
                             &endp_sys_16k);
      }
    }

    if (want_mic && mic_capture && mic_fmt) {
      drain_capture_to_16k(mic_capture.Get(), mic_fmt, &mic_16k);
    }

    if (is_paused_.load()) {
      continue;
    }

    // 选择或融合最佳系统内录流 (优先选能量非零的一路，兼顾系统静音下的 Process Loopback 与硬件 Endpoint Loopback)
    std::vector<float> sys_16k;
    if (!proc_sys_16k.empty() && !endp_sys_16k.empty()) {
      float proc_energy = 0.0f;
      for (float v : proc_sys_16k) proc_energy += std::fabs(v);
      float endp_energy = 0.0f;
      for (float v : endp_sys_16k) endp_energy += std::fabs(v);
      sys_16k = (proc_energy >= endp_energy * 0.5f && proc_energy > 1e-5f)
                    ? std::move(proc_sys_16k)
                    : std::move(endp_sys_16k);
    } else if (!proc_sys_16k.empty()) {
      sys_16k = std::move(proc_sys_16k);
    } else if (!endp_sys_16k.empty()) {
      sys_16k = std::move(endp_sys_16k);
    }

    // 合成最终 16kHz 单声道帧
    size_t frame_count = 0;
    if (want_system && want_mic) {
      frame_count = std::max(sys_16k.size(), mic_16k.size());
    } else if (want_system) {
      frame_count = sys_16k.size();
    } else if (want_mic) {
      frame_count = mic_16k.size();
    }

    if (frame_count == 0) {
      // 平滑衰减振幅指示
      current_amplitude_.store(current_amplitude_.load() * 0.75);
      continue;
    }

    std::vector<float> mixed(frame_count, 0.0f);
    float chunk_peak = 0.0f;
    double sum_sq = 0.0;

    for (size_t i = 0; i < frame_count; ++i) {
      float s_sys = (i < sys_16k.size()) ? sys_16k[i] : 0.0f;
      float s_mic = (i < mic_16k.size()) ? mic_16k[i] : 0.0f;
      float val = s_sys + s_mic;
      // 软限幅防爆音
      if (val > 1.0f || val < -1.0f) {
        val = std::tanh(val);
      }
      mixed[i] = val;
      float av = std::fabs(val);
      if (av > chunk_peak) chunk_peak = av;
      sum_sq += static_cast<double>(val) * static_cast<double>(val);
    }

    // 动态柔和弱信号增益 (当用户把播放器音量调得很低时自动提振信号，使 SenseVoice 清晰识别)
    if (chunk_peak > 0.003f) {
      agc_running_peak = 0.85f * agc_running_peak + 0.15f * chunk_peak;
      if (agc_running_peak < 0.35f) {
        float gain = std::min(0.55f / std::max(agc_running_peak, 0.01f), 12.0f);
        for (float& v : mixed) {
          v = std::clamp(v * gain, -1.0f, 1.0f);
        }
      }
    }

    // 计算 UI 音浪归一化振幅 (0.0 ~ 1.0)
    double rms = std::sqrt(sum_sq / static_cast<double>(frame_count));
    double db = 20.0 * std::log10(std::max(rms, 1e-7));
    double norm_amp = 0.0;
    if (db > -55.0) {
      norm_amp = std::clamp((db + 55.0) / 55.0, 0.0, 1.0);
      norm_amp = std::pow(norm_amp, 0.7);
    }
    current_amplitude_.store(norm_amp);

    // 转为 Int16 PCM
    std::vector<int16_t> pcm_chunk(frame_count);
    for (size_t i = 0; i < frame_count; ++i) {
      pcm_chunk[i] = static_cast<int16_t>(
          std::round(std::clamp(mixed[i], -1.0f, 1.0f) * 32767.0f));
    }

    // 1. 推入内存实时队列供 Dart 端直接拉取转写
    {
      std::lock_guard<std::mutex> lock(buffer_mutex_);
      // 防止长时间未拉取导致内存无限增长 (最多保留 60 秒即 960000 样本)
      if (pending_pcm_16k_.size() + pcm_chunk.size() > 960000) {
        pending_pcm_16k_.erase(
            pending_pcm_16k_.begin(),
            pending_pcm_16k_.begin() +
                static_cast<ptrdiff_t>(pcm_chunk.size()));
      }
      pending_pcm_16k_.insert(pending_pcm_16k_.end(), pcm_chunk.begin(),
                              pcm_chunk.end());
    }

    // 2. 实时写入 WAV 文件
    if (wav_file != INVALID_HANDLE_VALUE) {
      LARGE_INTEGER end_pos = {};
      SetFilePointerEx(wav_file, end_pos, nullptr, FILE_END);
      DWORD chunk_bytes = static_cast<DWORD>(pcm_chunk.size() * sizeof(int16_t));
      DWORD written = 0;
      if (WriteFile(wav_file, pcm_chunk.data(), chunk_bytes, &written,
                    nullptr)) {
        total_written_bytes += written;
      }
    }
  }

  // 停止所有流并清理资源
  if (proc_loop_client) proc_loop_client->Stop();
  if (endpoint_loop_client) endpoint_loop_client->Stop();
  if (keepalive_render_client) keepalive_render_client->Stop();
  if (mic_client) mic_client->Stop();

  if (endpoint_loop_fmt) CoTaskMemFree(endpoint_loop_fmt);
  if (mic_fmt) CoTaskMemFree(mic_fmt);

  // 回填最终 WAV 文件头并刷盘关闭
  if (wav_file != INVALID_HANDLE_VALUE) {
    WriteWavHeader(wav_file, 16000, total_written_bytes);
    FlushFileBuffers(wav_file);
    CloseHandle(wav_file);
  }

  if (need_co_uninit) CoUninitialize();
}
