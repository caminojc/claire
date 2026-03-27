package com.claire.stt

import com.atria.module.SttProcessor
import logging.SLog

/**
 * Wraps atria's SttProcessor (JNI → whisper.cpp + mel codec on GPU).
 */
class SttNativeProcessor {

    private var processor: SttProcessor? = null

    fun init(modelDir: String) {
        try {
            processor = SttProcessor()
            val instances = intArrayOf(0, 0, 1, 0) // 1x small model
            processor!!.initSttProcessorContext(modelDir, instances)
            SLog.i("Native mel STT initialized (whisper.cpp GPU, models=$modelDir)")
        } catch (e: Exception) {
            SLog.e("Native mel STT init failed: ${e.message}")
            processor = null
        }
    }

    val isAvailable: Boolean get() = processor != null

    suspend fun transcribeMel(melData: ByteArray): String {
        val p = processor ?: return ""
        return try {
            p.decMelTranscribe(melData)
        } catch (e: Exception) {
            SLog.e("Mel transcription error: ${e.message}")
            ""
        }
    }
}
