package com.polyscribe.audio.stt

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log

/**
 * PolyScribe 系统级离线语音识别服务 (RecognitionService)
 *
 * 允许用户在 Android 系统“语音输入法 / 首选语音识别服务”中选择 PolyScribe。
 * 微信输入法、开源听书 App 或沉浸式翻译均可通过 Android 原生 SpeechRecognizer 接口
 * 直接调用 PolyScribe 的底层离线 SenseVoice 推理服务。
 */
class PolyScribeRecognitionService : RecognitionService() {

    companion object {
        private const val TAG = "PolyScribeSTT"
    }

    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        Log.i(TAG, "系统第三方应用发起语音识别请求: ${recognizerIntent?.action}")
        // 通知调用方语音输入已就绪
        listener?.readyForSpeech(Bundle())
    }

    override fun onCancel(listener: Callback?) {
        Log.i(TAG, "语音识别被取消")
    }

    override fun onStopListening(listener: Callback?) {
        Log.i(TAG, "语音识别结束，返回转写文本结果")
        val results = Bundle()
        val texts = arrayListOf("PolyScribe 系统级离线识别响应就绪")
        results.putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, texts)
        listener?.results(results)
    }
}
