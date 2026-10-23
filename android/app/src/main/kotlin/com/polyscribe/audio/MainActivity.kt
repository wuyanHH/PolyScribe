package com.polyscribe.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.polyscribe.audio/native_audio"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeAudioToWav" -> {
                        val inputPath = call.argument<String>("inputPath") ?: ""
                        val outputPath = call.argument<String>("outputPath") ?: ""
                        val targetRate = call.argument<Int>("sampleRate") ?: 16000

                        if (inputPath.isEmpty() || outputPath.isEmpty()) {
                            result.error("INVALID_ARGS", "Input or output path is empty", null)
                            return@setMethodCallHandler
                        }

                        thread {
                            try {
                                val ok = decodeAudioFileTo16kMonoWav(inputPath, outputPath, targetRate)
                                runOnUiThread {
                                    result.success(mapOf("success" to ok))
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.success(
                                        mapOf(
                                            "success" to false,
                                            "error" to (e.message ?: "Unknown decode error")
                                        )
                                    )
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 使用 Android 原生 MediaExtractor + MediaCodec 将任意格式音频 (m4a, mp3, aac, flac, ogg, wav, amr...)
     * 解码并重采样为标准 16kHz 单声道 16-bit PCM WAV 文件
     */
    private fun decodeAudioFileTo16kMonoWav(
        inputPath: String,
        outputPath: String,
        targetSampleRate: Int
    ): Boolean {
        val extractor = MediaExtractor()
        extractor.setDataSource(inputPath)

        var audioTrackIndex = -1
        var trackFormat: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("audio/")) {
                audioTrackIndex = i
                trackFormat = format
                break
            }
        }

        if (audioTrackIndex < 0 || trackFormat == null) {
            extractor.release()
            return false
        }

        extractor.selectTrack(audioTrackIndex)
        val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: return false
        var sampleRate = if (trackFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
            trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else {
            16000
        }
        var channelCount = if (trackFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        } else {
            1
        }

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(trackFormat, null, null, 0)
        codec.start()

        val monoFloatList = ArrayList<Float>(sampleRate * 30)
        val bufferInfo = MediaCodec.BufferInfo()
        var isInputEOS = false
        var isOutputEOS = false

        try {
            while (!isOutputEOS) {
                if (!isInputEOS) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inIndex)
                        if (inputBuffer != null) {
                            val sampleSize = extractor.readSampleData(inputBuffer, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(
                                    inIndex,
                                    0,
                                    0,
                                    0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                isInputEOS = true
                            } else {
                                val presentationTimeUs = extractor.sampleTime
                                codec.queueInputBuffer(inIndex, 0, sampleSize, presentationTimeUs, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = codec.outputFormat
                        if (newFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            sampleRate = newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }
                        if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channelCount = max(1, newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                        }
                    }
                    outIndex >= 0 -> {
                        val outputBuffer = codec.getOutputBuffer(outIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            outputBuffer.order(ByteOrder.LITTLE_ENDIAN)

                            val shortCount = bufferInfo.size / 2
                            val frameCount = shortCount / max(1, channelCount)
                            for (f in 0 until frameCount) {
                                var sum = 0f
                                for (c in 0 until channelCount) {
                                    val s16 = outputBuffer.short
                                    sum += s16 / 32768.0f
                                }
                                monoFloatList.add((sum / channelCount).coerceIn(-1.0f, 1.0f))
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            isOutputEOS = true
                        }
                    }
                }
            }
        } finally {
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            codec.release()
            extractor.release()
        }

        if (monoFloatList.isEmpty()) return false

        // 重采样至目标采样率 (16000Hz)
        val dstRate = if (targetSampleRate > 0) targetSampleRate else 16000
        val resampled: FloatArray = if (sampleRate == dstRate) {
            monoFloatList.toFloatArray()
        } else {
            val ratio = sampleRate.toDouble() / dstRate.toDouble()
            val outLen = floor(monoFloatList.size / ratio).toInt()
            if (outLen <= 0) return false
            val out = FloatArray(outLen)
            val halfWin = max(1, floor(ratio * 0.5).toInt())
            val maxIdx = monoFloatList.size - 1
            for (i in 0 until outLen) {
                if (ratio > 1.5) {
                    val center = (i * ratio).roundToInt()
                    val s = max(0, center - halfWin)
                    val e = min(maxIdx, center + halfWin)
                    var sum = 0f
                    for (k in s..e) sum += monoFloatList[k]
                    out[i] = sum / (e - s + 1)
                } else {
                    val pos = i * ratio
                    val idx0 = floor(pos).toInt()
                    val idx1 = min(idx0 + 1, maxIdx)
                    val frac = (pos - idx0).toFloat()
                    out[i] = monoFloatList[idx0] * (1f - frac) + monoFloatList[idx1] * frac
                }
            }
            out
        }

        // 直流偏置消除与弱信号归一化
        var mean = 0.0
        for (v in resampled) mean += v
        mean /= resampled.size
        var peak = 0f
        var sumSq = 0.0
        for (i in resampled.indices) {
            val v = (resampled[i] - mean.toFloat())
            resampled[i] = v
            val av = abs(v)
            if (av > peak) peak = av
            sumSq += v * v
        }
        val rms = sqrt(sumSq / resampled.size)
        if (peak > 0.002f && rms > 0.0003 && peak < 0.65f) {
            val gain = min(0.85f / peak, 25.0f)
            for (i in resampled.indices) {
                resampled[i] = (resampled[i] * gain).coerceIn(-1.0f, 1.0f)
            }
        }

        // 写入标准 16-bit 单声道 WAV 文件
        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()
        val dataBytes = resampled.size * 2
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(36 + dataBytes)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(1) // Mono
        header.putInt(dstRate)
        header.putInt(dstRate * 2)
        header.putShort(2)
        header.putShort(16)
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataBytes)

        RandomAccessFile(outFile, "rw").use { raf ->
            raf.setLength(0)
            raf.write(header.array())
            val pcmBuf = ByteBuffer.allocate(min(dataBytes, 65536)).order(ByteOrder.LITTLE_ENDIAN)
            for (v in resampled) {
                if (pcmBuf.remaining() < 2) {
                    raf.write(pcmBuf.array(), 0, pcmBuf.position())
                    pcmBuf.clear()
                }
                val s16 = (v.coerceIn(-1.0f, 1.0f) * 32767.0f).roundToInt().toShort()
                pcmBuf.putShort(s16)
            }
            if (pcmBuf.position() > 0) {
                raf.write(pcmBuf.array(), 0, pcmBuf.position())
            }
        }
        return true
    }
}
