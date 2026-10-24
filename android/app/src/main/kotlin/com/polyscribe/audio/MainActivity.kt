package com.polyscribe.audio

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.polyscribe.audio/native_audio"
        private const val KEEP_ALIVE_CHANNEL = "com.polyscribe.audio/keep_alive"
    }

    private var wakeLock: PowerManager.WakeLock? = null

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
                            } catch (t: Throwable) {
                                runOnUiThread {
                                    result.success(
                                        mapOf(
                                            "success" to false,
                                            "error" to (t.message ?: "Unknown decode error")
                                        )
                                    )
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 注册移动端后台保活与唤醒锁通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireWakeLock" -> {
                        try {
                            if (wakeLock == null) {
                                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                                wakeLock = pm.newWakeLock(
                                    PowerManager.PARTIAL_WAKE_LOCK,
                                    "PolyScribe::AudioTranscriptionWakeLock"
                                ).apply {
                                    setReferenceCounted(false)
                                }
                            }
                            if (wakeLock?.isHeld == false) {
                                wakeLock?.acquire(4 * 60 * 60 * 1000L) // 最长 4 小时保护
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "releaseWakeLock" -> {
                        try {
                            if (wakeLock?.isHeld == true) {
                                wakeLock?.release()
                            }
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    "startForegroundService", "stopForegroundService" -> {
                        result.success(true)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                                if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                        data = Uri.parse("package:$packageName")
                                    }
                                    startActivity(intent)
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    /**
     * 使用 Android 原生 MediaExtractor + MediaCodec 流式将任意格式音频
     * (m4a, mp3, aac, flac, ogg, wav, amr, opus...) 解码并实时重采样为标准 16kHz 单声道 16-bit PCM WAV 文件。
     * 采用 64KB 恒定内存滑动窗口流式直写磁盘，彻底杜绝 ArrayList<Float> 装箱导致的 OOM 闪退。
     */
    private fun decodeAudioFileTo16kMonoWav(
        inputPath: String,
        outputPath: String,
        targetSampleRate: Int
    ): Boolean {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputPath)
        } catch (e: Exception) {
            return false
        }

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
        val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: run {
            extractor.release()
            return false
        }

        // 请求解码器优先输出 16-bit PCM
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                trackFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            } catch (_: Exception) {
            }
        }

        var sampleRate = if (trackFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
            trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else {
            16000
        }
        var channelCount = if (trackFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            max(1, trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
        } else {
            1
        }
        var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(trackFormat, null, null, 0)
        codec.start()

        val dstRate = if (targetSampleRate > 0) targetSampleRate else 16000
        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()

        var totalOutSamples = 0L
        var sumVal = 0.0
        var sumSq = 0.0
        var peak = 0f

        // 流式重采样状态变量 (抗混叠均值抽取 + 线性插值)
        var resamplerAccumSum = 0.0
        var resamplerAccumCount = 0
        var srcCursor = 0.0
        var nextDstAtSrc = 0.0
        var prevMonoSample = 0f

        val bufferInfo = MediaCodec.BufferInfo()
        var isInputEOS = false
        var isOutputEOS = false

        RandomAccessFile(outFile, "rw").use { raf ->
            raf.setLength(0)
            // 先写入 44 字节 WAV 头部占位
            raf.write(ByteArray(44))

            val pcmOutBuf = ByteBuffer.allocate(65536).order(ByteOrder.LITTLE_ENDIAN)

            fun emitTargetSample(s: Float) {
                val clamped = s.coerceIn(-1.0f, 1.0f)
                val absV = abs(clamped)
                if (absV > peak) peak = absV
                sumVal += clamped
                sumSq += (clamped * clamped).toDouble()
                totalOutSamples++

                if (pcmOutBuf.remaining() < 2) {
                    raf.write(pcmOutBuf.array(), 0, pcmOutBuf.position())
                    pcmOutBuf.clear()
                }
                val s16 = (clamped * 32767.0f).roundToInt().coerceIn(-32768, 32767).toShort()
                pcmOutBuf.putShort(s16)
            }

            fun feedSourceMonoSample(mono: Float, currentSrcRate: Int) {
                if (currentSrcRate <= 0 || currentSrcRate == dstRate) {
                    emitTargetSample(mono)
                    return
                }
                val step = currentSrcRate.toDouble() / dstRate.toDouble()
                if (step >= 1.0) {
                    // 下采样 (例如 48000 -> 16000 或 44100 -> 16000)：抗混叠盒式滤波累加
                    resamplerAccumSum += mono
                    resamplerAccumCount++
                    srcCursor += 1.0
                    if (srcCursor >= nextDstAtSrc + step) {
                        val avg = (resamplerAccumSum / max(1, resamplerAccumCount)).toFloat()
                        emitTargetSample(avg)
                        resamplerAccumSum = 0.0
                        resamplerAccumCount = 0
                        nextDstAtSrc += step
                    }
                } else {
                    // 上采样 (例如 8000 -> 16000)：线性插值
                    while (nextDstAtSrc <= srcCursor + 1.0) {
                        val frac = (nextDstAtSrc - srcCursor).coerceIn(0.0, 1.0).toFloat()
                        val interp = prevMonoSample * (1.0f - frac) + mono * frac
                        emitTargetSample(interp)
                        nextDstAtSrc += step
                    }
                    prevMonoSample = mono
                    srcCursor += 1.0
                }
            }

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
                                sampleRate = max(8000, newFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE))
                            }
                            if (newFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                channelCount = max(1, newFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                                newFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)
                            ) {
                                pcmEncoding = newFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            }
                        }
                        outIndex >= 0 -> {
                            val outputBuffer = codec.getOutputBuffer(outIndex)
                            if (outputBuffer != null && bufferInfo.size > 0) {
                                outputBuffer.position(bufferInfo.offset)
                                outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                outputBuffer.order(ByteOrder.LITTLE_ENDIAN)

                                val ch = max(1, channelCount)
                                if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                                    val floatCount = outputBuffer.remaining() / 4
                                    val frameCount = floatCount / ch
                                    for (f in 0 until frameCount) {
                                        var sum = 0f
                                        for (c in 0 until ch) {
                                            val v = outputBuffer.float
                                            if (!v.isNaN() && !v.isInfinite()) {
                                                sum += v
                                            }
                                        }
                                        feedSourceMonoSample((sum / ch).coerceIn(-1.0f, 1.0f), sampleRate)
                                    }
                                } else if (pcmEncoding == AudioFormat.ENCODING_PCM_8BIT) {
                                    val byteCount = outputBuffer.remaining()
                                    val frameCount = byteCount / ch
                                    for (f in 0 until frameCount) {
                                        var sum = 0f
                                        for (c in 0 until ch) {
                                            val u8 = outputBuffer.get().toInt() and 0xFF
                                            sum += (u8 - 128) / 128.0f
                                        }
                                        feedSourceMonoSample((sum / ch).coerceIn(-1.0f, 1.0f), sampleRate)
                                    }
                                } else {
                                    // 默认 16-bit PCM
                                    val shortCount = outputBuffer.remaining() / 2
                                    val frameCount = shortCount / ch
                                    for (f in 0 until frameCount) {
                                        var sum = 0f
                                        for (c in 0 until ch) {
                                            val s16 = outputBuffer.short
                                            sum += s16 / 32768.0f
                                        }
                                        feedSourceMonoSample((sum / ch).coerceIn(-1.0f, 1.0f), sampleRate)
                                    }
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
                try {
                    codec.release()
                } catch (_: Exception) {
                }
                try {
                    extractor.release()
                } catch (_: Exception) {
                }
            }

            if (resamplerAccumCount > 0) {
                emitTargetSample((resamplerAccumSum / resamplerAccumCount).toFloat())
            }
            if (pcmOutBuf.position() > 0) {
                raf.write(pcmOutBuf.array(), 0, pcmOutBuf.position())
                pcmOutBuf.clear()
            }

            if (totalOutSamples <= 0L) {
                return false
            }

            // 若检测到弱音信号，使用固定 64KB 缓冲在磁盘上原地进行直流偏置消除与自适应增益放大
            val mean = (sumVal / totalOutSamples).toFloat()
            val rms = sqrt(sumSq / totalOutSamples)
            if (peak > 0.002f && rms > 0.0003 && peak < 0.65f) {
                val gain = min(0.85f / peak, 20.0f)
                val ioBuf = ByteArray(65536)
                var pos = 44L
                val fileEnd = 44L + totalOutSamples * 2L
                while (pos < fileEnd) {
                    raf.seek(pos)
                    val toRead = min(ioBuf.size.toLong(), fileEnd - pos).toInt() and 0xFFFE
                    if (toRead <= 0) break
                    val readBytes = raf.read(ioBuf, 0, toRead)
                    if (readBytes <= 1) break
                    val aligned = readBytes and 0xFFFE
                    val bb = ByteBuffer.wrap(ioBuf, 0, aligned).order(ByteOrder.LITTLE_ENDIAN)
                    for (i in 0 until aligned step 2) {
                        val raw = bb.getShort(i) / 32768.0f
                        val boosted = ((raw - mean) * gain).coerceIn(-1.0f, 1.0f)
                        val newS16 = (boosted * 32767.0f).roundToInt().coerceIn(-32768, 32767).toShort()
                        bb.putShort(i, newS16)
                    }
                    raf.seek(pos)
                    raf.write(ioBuf, 0, aligned)
                    pos += aligned
                }
            }

            // 回填标准 RIFF WAVE 44 字节文件头
            val dataBytes = (totalOutSamples * 2L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
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

            raf.seek(0)
            raf.write(header.array())
        }

        return totalOutSamples > 0L
    }
}
