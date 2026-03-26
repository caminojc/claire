package com.claire.tts

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import logging.SLog

/**
 * Client for the local TTS (Kokoro) server running on port 1238.
 * Uses simple HTTP POST /synthesize endpoint.
 */
class TtsServerClient(
    private val httpClient: HttpClient,
) {
    private val ttsServerUrl: String = System.getenv("TTS_SERVER_URL")?.replace("ws://", "http://")?.replace("wss://", "https://") ?: "http://localhost:1238"
    private val defaultVoice: String = System.getenv("CLAIRE_VOICE") ?: "af_heart"

    data class TtsAudioChunk(
        val audio: ByteArray,
        val isEnd: Boolean,
        val textSegment: String = "",
    )

    /**
     * Synthesize TTS audio for the given text via HTTP POST.
     * Simpler and more reliable than WebSocket streaming.
     */
    suspend fun streamTts(
        text: String,
        outputChannel: Channel<TtsAudioChunk>,
        voice: String = defaultVoice,
        outputFormat: String = "pcm",
        sampleRate: Int = 24000,
        speed: Float = 1.0f,
    ) {
        try {
            SLog.i("TTS: synthesizing '${text.take(50)}'")

            val response = httpClient.post("$ttsServerUrl/synthesize") {
                contentType(ContentType.Application.Json)
                setBody("""{"text":"${text.replace("\"", "\\\"")}","voice":"$voice","speed":$speed}""")
            }

            if (response.status == HttpStatusCode.OK) {
                val body = response.bodyAsText()
                val jsonResponse = Json.parseToJsonElement(body).jsonObject
                val audioBase64 = jsonResponse["audio_base64"]?.jsonPrimitive?.content

                if (audioBase64 != null) {
                    val audioBytes = java.util.Base64.getDecoder().decode(audioBase64)
                    SLog.i("TTS: got ${audioBytes.size} bytes of audio")

                    outputChannel.send(TtsAudioChunk(
                        audio = audioBytes,
                        isEnd = false,
                        textSegment = text,
                    ))
                }
            } else {
                SLog.e("TTS: HTTP ${response.status}")
            }

            // Signal end
            outputChannel.send(TtsAudioChunk(audio = ByteArray(0), isEnd = true))

        } catch (e: Exception) {
            SLog.e("TTS error: ${e.message}")
            outputChannel.send(TtsAudioChunk(audio = ByteArray(0), isEnd = true))
        }
    }

    suspend fun healthCheck(): Boolean {
        return try {
            val response = httpClient.get("$ttsServerUrl/health")
            response.status == HttpStatusCode.OK
        } catch (e: Exception) {
            false
        }
    }
}
