package com.claire.stt

import logging.SLog

/**
 * Native whisper.cpp STT processor for mel-encoded audio.
 * Loads libembedded_dynamic.so which contains:
 * - smpl_mel_dec: decodes SMPL mel codec payload
 * - whisper.cpp: transcribes mel spectrogram on GPU
 *
 * Same code path as atria-server production.
 */
class SttNativeProcessor {

    private var initialized = false

    fun init(modelDir: String) {
        try {
            // instances: [tiny, basic, small, medium] - load one small instance
            val instances = intArrayOf(0, 0, 1, 0)
            initSttProcessorContext(modelDir, instances)
            initialized = true
            SLog.i("Native STT processor initialized (whisper.cpp + mel codec)")
        } catch (e: Exception) {
            SLog.e("Native STT init failed: ${e.message}")
        }
    }

    /**
     * Transcribe mel-encoded audio directly to text.
     * Decodes SMPL mel codec → feeds mel spectrogram to whisper.cpp → returns text.
     */
    suspend fun transcribeMel(melData: ByteArray): String {
        if (!initialized) return ""
        return try {
            decMelTranscribe(melData)
        } catch (e: Exception) {
            SLog.e("Mel transcription error: ${e.message}")
            ""
        }
    }

    /**
     * Transcribe raw PCM audio to text via whisper.cpp.
     */
    suspend fun transcribePcm(audioData: FloatArray, sampleRate: Int): String {
        if (!initialized) return ""
        return try {
            pcmTranscribe(audioData, sampleRate)
        } catch (e: Exception) {
            SLog.e("PCM transcription error: ${e.message}")
            ""
        }
    }

    // JNI methods — implemented in libembedded_dynamic.so
    private external fun initSttProcessorContext(modelDir: String, instances: IntArray)
    private external fun pcmTranscribe(audioData: FloatArray, sampleRate: Int): String
    private external fun decMelTranscribe(melData: ByteArray): String
}
