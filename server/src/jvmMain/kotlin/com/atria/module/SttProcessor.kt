package com.atria.module

/**
 * JNI bridge to native whisper.cpp + mel codec.
 * Package must be com.atria.module to match native JNI symbol names.
 * Same class as atria-server's SttProcessor.
 */
class SttProcessor {
    external fun initSttProcessorContext(modelDir: String, instances: IntArray)
    external fun pcmTranscribe(audioData: FloatArray, sampleRate: Int): String
    external fun decMelTranscribe(melData: ByteArray): String
}
