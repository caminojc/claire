package com.claire.tts

import io.ktor.client.*
import io.ktor.client.plugins.websocket.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.websocket.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import logging.SLog

/**
 * Client for the local TTS (Kokoro) server running on port 1238.
 * Uses WebSocket streaming protocol matching atria-server's TtsServerRepository.
 */
class TtsServerClient(
    private val httpClient: HttpClient,
) {
    private val ttsServerUrl: String = System.getenv("TTS_SERVER_URL") ?: "ws://localhost:1238"
    private val defaultVoice: String = System.getenv("CLAIRE_VOICE") ?: "af_heart"

    data class TtsAudioChunk(
        val audio: ByteArray,
        val isEnd: Boolean,
        val textSegment: String = "",
    )

    /**
     * Stream TTS audio for the given text.
     * Sends text to Kokoro via WebSocket, receives audio chunks.
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
            SLog.i("TTS client: connecting to $ttsServerUrl/ws for '${text.take(30)}'")
            httpClient.webSocket(host = "localhost", port = 1238, path = "/ws") {
                SLog.i("TTS client: connected, sending config+text")
                // Send config
                val config = buildJsonObject {
                    put("model", "kokoro")
                    put("voice", voice)
                    put("output_format", outputFormat)
                    put("sample_rate", sampleRate)
                    put("speed", speed)
                }
                send(Frame.Text(config.toString()))

                // Send text
                val textMessage = buildJsonObject {
                    put("type", "text")
                    put("text", text)
                    put("flush", true)
                    put("try_trigger_generation", true)
                }
                send(Frame.Text(textMessage.toString()))

                // Send end signal
                val endMessage = buildJsonObject {
                    put("type", "end")
                }
                send(Frame.Text(endMessage.toString()))

                // Receive audio chunks
                SLog.i("TTS client: waiting for audio chunks...")
                for (frame in incoming) {
                    when (frame) {
                        is Frame.Text -> {
                            val frameText = frame.readText()
                            val response = Json.parseToJsonElement(frameText).jsonObject
                            val type = response["type"]?.jsonPrimitive?.content

                            when (type) {
                                "audio" -> {
                                    val audioBase64 = response["audio_base64"]?.jsonPrimitive?.content ?: continue
                                    val audioBytes = java.util.Base64.getDecoder().decode(audioBase64)
                                    SLog.i("TTS client: got audio chunk ${audioBytes.size} bytes")

                                    outputChannel.send(TtsAudioChunk(
                                        audio = audioBytes,
                                        isEnd = false,
                                        textSegment = response["text_segment"]?.jsonPrimitive?.content ?: "",
                                    ))
                                }
                                "done" -> {
                                    SLog.i("TTS client: done")
                                    outputChannel.send(TtsAudioChunk(
                                        audio = ByteArray(0),
                                        isEnd = true,
                                    ))
                                    break
                                }
                                "error" -> {
                                    SLog.e("TTS server error: ${response["message"]?.jsonPrimitive?.content}")
                                    break
                                }
                                else -> {
                                    SLog.i("TTS client: unknown type '$type'")
                                }
                            }
                        }
                        else -> {
                            SLog.i("TTS client: non-text frame: ${frame.frameType}")
                        }
                    }
                }
                SLog.i("TTS client: stream ended")
            }
        } catch (e: Exception) {
            SLog.e("TTS streaming error: ${e.message}")
            outputChannel.send(TtsAudioChunk(audio = ByteArray(0), isEnd = true))
        }
    }

    suspend fun healthCheck(): Boolean {
        return try {
            val healthUrl = ttsServerUrl.replace("ws://", "http://").replace("wss://", "https://")
            val response = httpClient.get("$healthUrl/health")
            response.status == HttpStatusCode.OK
        } catch (e: Exception) {
            false
        }
    }
}
