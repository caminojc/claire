package com.claire.tts

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.utils.io.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import logging.SLog

/**
 * TTS client using streaming HTTP endpoint for low latency.
 * Each audio chunk is sent to the client as soon as Kokoro generates it.
 */
class TtsServerClient(
    private val httpClient: HttpClient,
) {
    private val ttsServerUrl: String = System.getenv("TTS_SERVER_URL")
        ?.replace("ws://", "http://")?.replace("wss://", "https://")
        ?: "http://localhost:1238"
    private val defaultVoice: String = System.getenv("CLAIRE_VOICE") ?: "af_heart"

    data class TtsAudioChunk(
        val audio: ByteArray,
        val isEnd: Boolean,
        val textSegment: String = "",
    )

    suspend fun streamTts(
        text: String,
        outputChannel: Channel<TtsAudioChunk>,
        voice: String = defaultVoice,
        speed: Float = 1.0f,
    ) {
        try {
            SLog.i("TTS: streaming '${text.take(60)}'")

            // Use streaming endpoint — get chunks as they're generated
            httpClient.preparePost("$ttsServerUrl/synthesize_stream") {
                contentType(ContentType.Application.Json)
                setBody("""{"text":"${text.replace("\"", "\\\"").replace("\n", " ")}","voice":"$voice","speed":$speed}""")
            }.execute { response ->
                if (response.status != HttpStatusCode.OK) {
                    SLog.e("TTS stream: HTTP ${response.status}")
                    outputChannel.send(TtsAudioChunk(ByteArray(0), true))
                    return@execute
                }

                val channel = response.bodyAsChannel()
                while (!channel.isClosedForRead) {
                    val line = channel.readUTF8Line() ?: break
                    if (line.isBlank()) continue

                    try {
                        val json = Json.parseToJsonElement(line).jsonObject
                        val isLast = json["is_last"]?.jsonPrimitive?.boolean ?: false

                        if (isLast) {
                            SLog.i("TTS: stream complete")
                            break
                        }

                        val audioB64 = json["audio_base64"]?.jsonPrimitive?.content ?: continue
                        val audioBytes = java.util.Base64.getDecoder().decode(audioB64)
                        val chunkIdx = json["chunk"]?.jsonPrimitive?.int ?: 0

                        SLog.i("TTS: chunk $chunkIdx = ${audioBytes.size} bytes")
                        outputChannel.send(TtsAudioChunk(audio = audioBytes, isEnd = false, textSegment = text))

                    } catch (e: Exception) {
                        SLog.e("TTS: parse error: ${e.message}")
                    }
                }
            }

            outputChannel.send(TtsAudioChunk(ByteArray(0), true))

        } catch (e: Exception) {
            SLog.e("TTS error: ${e.message}")
            outputChannel.send(TtsAudioChunk(ByteArray(0), true))
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
