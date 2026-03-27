package com.claire.routing

import TtsChunkedTextFilter
import TtsResponseMessage
import ProtobufTtsResponseVersion
import com.claire.backgroundDispatcher
import com.claire.backgroundScope
import com.claire.llm.AnthropicClient
import com.claire.stt.SttServerClient
import com.claire.tts.TtsServerClient
import io.ktor.server.websocket.*
import io.ktor.websocket.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.decodeFromByteArray
import kotlinx.serialization.encodeToByteArray
import kotlinx.serialization.json.*
import kotlinx.serialization.protobuf.ProtoBuf
import logging.SLog
import module.*
import openai.*
import schemas.*
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

typealias WebSocketHandler = suspend DefaultWebSocketServerSession.() -> Unit

interface WebSocketRoute {
    fun route(): WebSocketHandler
}

/**
 * Claire's unified WebSocket endpoint.
 * Handles the STT -> Claude -> TTS pipeline.
 * Simplified from atria-server's UnifiedRoute (1196 lines -> ~200 lines).
 */
class UnifiedRoute(scope: org.koin.core.scope.Scope) : WebSocketRoute {

    private val anthropicClient: AnthropicClient = scope.get()
    private val localLlmClient: com.claire.llm.LocalLlmClient = scope.get()
    private val sttServerClient: SttServerClient = scope.get()
    private val sttNativeProcessor: com.claire.stt.SttNativeProcessor = scope.get()
    private val ttsServerClient: TtsServerClient = scope.get()
    private val json: Json = scope.get()
    private val useLocalLlm: Boolean = System.getenv("USE_LOCAL_LLM")?.toBoolean() ?: false

    private val singleDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    @OptIn(ExperimentalSerializationApi::class)
    override fun route(): WebSocketHandler = {
        val session = this
        var enabledLlm = true
        var enabledTts = true
        var codecUpstream = UpstreamCodecOption.PCM16_16KHZ.persistedValue
        var ttsProtobufVersion = -1
        var payloadProtobufVersion = -1
        var llmPrompt: String? = null
        val latestPayloadUuid = AtomicReference("")

        val outputChannel = Channel<Frame>(capacity = 100)

        // Single writer coroutine for ordered WebSocket output
        val outputJob = launch(singleDispatcher) {
            for (frame in outputChannel) {
                try {
                    session.send(frame)
                } catch (e: Exception) {
                    SLog.e("Error sending frame: ${e.message}")
                    break
                }
            }
        }

        try {
            for (frame in incoming) {
                when (frame) {
                    is Frame.Text -> {
                        val text = frame.readText()
                        try {
                            // First try to parse as raw JSON (Claire client sends base64 payload)
                            val jsonElement = json.parseToJsonElement(text).jsonObject
                            val type = jsonElement["type"]?.jsonPrimitive?.content

                            if (type == "payload_request") {
                                // Claire client sends payload as base64 string — handle manually
                                val uuid = jsonElement["uuid"]?.jsonPrimitive?.content ?: ""
                                val payloadB64 = jsonElement["payload"]?.jsonPrimitive?.content ?: ""
                                val audioPayload = java.util.Base64.getDecoder().decode(payloadB64)
                                val timeMs = (jsonElement["time_ms"]?.jsonPrimitive?.long?.rem(Int.MAX_VALUE))?.toInt() ?: 0

                                // Extract messages from chat_completion_request
                                val messagesJson = jsonElement["chat_completion_request"]
                                    ?.jsonObject?.get("messages")?.jsonArray ?: JsonArray(emptyList())
                                val messages = messagesJson.map { msgEl ->
                                    val msgObj = msgEl.jsonObject
                                    val role = msgObj["role"]?.jsonPrimitive?.content ?: "user"
                                    val content = msgObj["content"]?.jsonPrimitive?.content ?: ""
                                    Message(
                                        role = when (role) {
                                            "system" -> OpenAiRole.SYSTEM
                                            "assistant" -> OpenAiRole.ASSISTANT
                                            "prompt" -> OpenAiRole.PROMPT
                                            else -> OpenAiRole.USER
                                        },
                                        content = content
                                    )
                                }

                                SLog.i("Payload received: ${audioPayload.size} bytes, ${messages.size} messages")
                                latestPayloadUuid.set(uuid)
                                launch(backgroundDispatcher) {
                                    handlePayload(
                                        uuid = uuid,
                                        messages = messages,
                                        audioPayload = audioPayload,
                                        deviceStartTime = timeMs,
                                        clientTimingId = "",
                                        enabledLlm = enabledLlm,
                                        enabledTts = enabledTts,
                                        ttsProtobufVersion = ttsProtobufVersion,
                                        llmPrompt = llmPrompt,
                                        codecUpstream = codecUpstream,
                                        latestPayloadUuid = latestPayloadUuid,
                                        outputChannel = outputChannel,
                                    )
                                }
                            } else {
                                // Standard deserialization for config/echo/etc
                                val request = json.decodeFromString(UnifiedRequest.serializer(), text)
                                when (request) {
                                    is UnifiedRequest.Config -> {
                                        enabledLlm = request.enableLlm
                                        enabledTts = request.enableTts
                                        codecUpstream = request.codecUpstream
                                        ttsProtobufVersion = request.ttsProtobufVersion
                                        payloadProtobufVersion = request.payloadProtobufVersion
                                        llmPrompt = request.llmPrompt

                                        if (request.respondBack) {
                                            val configResponse = json.encodeToString(
                                                UnifiedResponse.serializer(),
                                                UnifiedResponse.Config(
                                                    uuid = request.uuid,
                                                    format = request.ttsPrefs.format,
                                                )
                                            )
                                            outputChannel.send(Frame.Text(configResponse))
                                        }
                                        SLog.i("Session configured: codec=$codecUpstream, llm=$enabledLlm, tts=$enabledTts")
                                    }

                                    is UnifiedRequest.Payload -> {
                                        latestPayloadUuid.set(request.uuid)
                                        launch(backgroundDispatcher) {
                                            handlePayload(
                                                uuid = request.uuid,
                                                messages = request.chatCompletionRequest.messages.map {
                                                    Message(
                                                        role = it.role,
                                                        content = (it.content as? TextContent)?.content ?: ""
                                                    )
                                                },
                                                audioPayload = request.payload,
                                                deviceStartTime = request.timeMs,
                                                clientTimingId = request.clientTimingId ?: "",
                                                enabledLlm = enabledLlm,
                                                enabledTts = enabledTts,
                                                ttsProtobufVersion = ttsProtobufVersion,
                                                llmPrompt = llmPrompt,
                                                codecUpstream = codecUpstream,
                                                latestPayloadUuid = latestPayloadUuid,
                                                outputChannel = outputChannel,
                                            )
                                        }
                                    }

                                    is UnifiedRequest.Echo -> {
                                        val echoResponse = json.encodeToString(
                                            UnifiedResponse.serializer(),
                                            UnifiedResponse.Echo(uuid = request.uuid, content = request.content)
                                        )
                                        outputChannel.send(Frame.Text(echoResponse))
                                    }

                                    is UnifiedRequest.ChatCompletion -> {
                                        // Direct chat completion without audio — not needed for v1
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            SLog.e("Error processing text frame: ${e.message}\nJSON input: ${text.take(200)}")
                        }
                    }

                    is Frame.Binary -> {
                        // Handle protobuf PayloadRequestMessage
                        try {
                            val payloadMsg = ProtoBuf.decodeFromByteArray<PayloadRequestMessage>(frame.readBytes())
                            latestPayloadUuid.set(payloadMsg.uuid)
                            launch(backgroundDispatcher) {
                                handlePayload(
                                    uuid = payloadMsg.uuid,
                                    messages = payloadMsg.messages,
                                    audioPayload = payloadMsg.payload,
                                    deviceStartTime = payloadMsg.deviceStartTime,
                                    clientTimingId = payloadMsg.clientTimingId ?: "",
                                    enabledLlm = enabledLlm,
                                    enabledTts = enabledTts,
                                    ttsProtobufVersion = ttsProtobufVersion,
                                    llmPrompt = llmPrompt,
                                    codecUpstream = codecUpstream,
                                    latestPayloadUuid = latestPayloadUuid,
                                    outputChannel = outputChannel,
                                )
                            }
                        } catch (e: Exception) {
                            SLog.e("Error processing binary frame: ${e.message}")
                        }
                    }

                    else -> {}
                }
            }
        } finally {
            outputChannel.close()
            outputJob.cancel()
        }
    }

    /**
     * Core pipeline: STT -> LLM -> TTS
     */
    @OptIn(ExperimentalSerializationApi::class)
    private suspend fun handlePayload(
        uuid: String,
        messages: List<Message>,
        audioPayload: ByteArray,
        deviceStartTime: Int,
        clientTimingId: String,
        enabledLlm: Boolean,
        enabledTts: Boolean,
        ttsProtobufVersion: Int,
        llmPrompt: String?,
        codecUpstream: String,
        latestPayloadUuid: AtomicReference<String>,
        outputChannel: Channel<Frame>,
    ) {
        // Check if this request is still the latest (barge-in support)
        fun isStale() = latestPayloadUuid.get() != uuid

        try {
            val updatedMessages: List<Message>

            if (audioPayload.isEmpty()) {
                // Text-only request — skip STT, use messages directly
                SLog.i("Text-only payload, skipping STT. Messages: ${messages.size}")
                updatedMessages = messages
                if (!enabledLlm) return
            } else {
                // === Phase 1: STT ===
                SLog.i("Transcribing ${audioPayload.size} bytes (codec=$codecUpstream)...")
                val sttText = if (codecUpstream == "smpl-mel" && sttNativeProcessor.isAvailable) {
                    // Native mel → whisper.cpp (GPU, direct mel path)
                    sttNativeProcessor.transcribeMel(audioPayload)
                } else {
                    // PCM → Parakeet (GPU, HTTP) or fallback for mel
                    sttServerClient.transcribe(audioPayload, codecUpstream)
                }
                SLog.i("STT result: '$sttText'")
                if (sttText.isBlank() || isStale()) return

                // Send STT result to client
                val sttResponse = json.encodeToString(
                    UnifiedResponse.serializer(),
                    UnifiedResponse.SttTextResult(
                        uuid = uuid,
                        text = sttText,
                        deviceStartTime = deviceStartTime,
                        clientTimingId = clientTimingId,
                    )
                )
                outputChannel.send(Frame.Text(sttResponse))

                if (!enabledLlm) return
                updatedMessages = messages + Message(role = OpenAiRole.USER, content = sttText)
            }

            // === Phase 2: Try local LLM first, fall back to Claude ===
            val ttsTextChannel = Channel<String>(capacity = 20)
            val completionId = "claire-${System.currentTimeMillis()}"

            // Try local LLM for fast response (if available)
            if (useLocalLlm) {
                val userText = updatedMessages.lastOrNull { it.role == OpenAiRole.USER }?.content ?: ""
                val localResponse = localLlmClient.quickResponse(userText)
                if (localResponse != null && localResponse.isNotBlank()) {
                    SLog.i("Local LLM responded: '${localResponse.take(80)}'")

                    // Send as LLM completion to client
                    val localChunk = OpenAiChatCompletionChunk(
                        id = completionId,
                        created = (System.currentTimeMillis() / 1000).toInt(),
                        model = OpenAiModelId("local"),
                        choices = listOf(OpenAiChatChunk(
                            index = 0,
                            delta = OpenAiChatDelta(content = localResponse),
                            finishReason = OpenAiFinishReason.Stop,
                        )),
                    )
                    val llmResponse = json.encodeToString(
                        UnifiedResponse.serializer(),
                        UnifiedResponse.LlmCompletionResult(
                            uuid = uuid,
                            chatCompletionChunk = localChunk,
                            deviceStartTime = deviceStartTime,
                            clientTimingId = clientTimingId,
                        )
                    )
                    outputChannel.send(Frame.Text(llmResponse))

                    // TTS the local response immediately
                    if (enabledTts) {
                        val audioChannel = Channel<TtsServerClient.TtsAudioChunk>(capacity = 50)
                        backgroundScope.launch {
                            ttsServerClient.streamTts(text = localResponse, outputChannel = audioChannel)
                        }
                        for (audioChunk in audioChannel) {
                            if (audioChunk.audio.isEmpty() || audioChunk.isEnd) break
                            val audioB64 = java.util.Base64.getEncoder().encodeToString(audioChunk.audio)
                            val ttsJson = buildJsonObject {
                                put("type", "tts_audio_result_response")
                                put("uuid", uuid)
                                put("audio_base64", audioB64)
                                put("is_end", false)
                                put("format", "pcm_int16_24000")
                            }
                            outputChannel.send(Frame.Text(ttsJson.toString()))
                        }
                    }

                    // If local response seems complete (not a deferral), skip Claude
                    val isSimple = localResponse.length < 100 &&
                        !localResponse.contains("let me") && !localResponse.contains("I'll")
                    if (isSimple) {
                        SLog.i("Local LLM sufficient, skipping Claude")
                        return
                    }
                    SLog.i("Local LLM gave preliminary response, continuing to Claude for detail")
                }
            }

            // LLM streaming task — feeds text into TTS channel
            val llmJob = backgroundScope.launch {
                val textBuffer = StringBuilder()
                try {
                    anthropicClient.streamCompletion(
                        messages = updatedMessages,
                        systemPrompt = llmPrompt ?: AnthropicClient.CLAIRE_SYSTEM_PROMPT,
                    ).collect { chunk ->
                        if (isStale()) {
                            cancel()
                            return@collect
                        }

                        // Send LLM chunk to client
                        val llmResponse = json.encodeToString(
                            UnifiedResponse.serializer(),
                            UnifiedResponse.LlmCompletionResult(
                                uuid = uuid,
                                chatCompletionChunk = chunk,
                                deviceStartTime = deviceStartTime,
                                clientTimingId = clientTimingId,
                            )
                        )
                        outputChannel.send(Frame.Text(llmResponse))

                        // Buffer text for TTS — batch 1-2 sentences together
                        val text = chunk.choices.firstOrNull()?.delta?.content
                        if (text != null && enabledTts) {
                            textBuffer.append(text)
                            val buf = textBuffer.toString()
                            // Only flush when we have enough text (50+ chars with sentence end)
                            // This prevents "Hey!" from being sent alone
                            val lastSentenceEnd = maxOf(
                                buf.lastIndexOf(". "), buf.lastIndexOf("! "),
                                buf.lastIndexOf("? "), buf.lastIndexOf(".\n"),
                            )
                            if (lastSentenceEnd >= 0 && buf.length >= 50) {
                                val toSend = buf.substring(0, lastSentenceEnd + 1).trim()
                                if (toSend.isNotBlank()) {
                                    SLog.i("TTS batch: '${toSend.take(100)}'")
                                    ttsTextChannel.send(toSend)
                                }
                                textBuffer.delete(0, lastSentenceEnd + 2)
                            }
                        }
                    }
                    // Flush remaining text
                    if (textBuffer.isNotEmpty()) {
                        val remaining = textBuffer.toString().trim()
                        if (remaining.isNotBlank()) {
                            SLog.i("TTS flush: '${remaining.take(60)}'")
                            ttsTextChannel.send(remaining)
                        }
                    }
                } finally {
                    ttsTextChannel.close()
                }
            }

            // TTS streaming task — consumes text, sends audio to client
            if (enabledTts) {
                val ttsJob = backgroundScope.launch {
                    for (textChunk in ttsTextChannel) {
                        if (isStale()) break
                        SLog.i("TTS: requesting audio for '${textChunk.take(50)}'")

                        val audioChannel = Channel<TtsServerClient.TtsAudioChunk>(capacity = 50)

                        // Request TTS audio
                        launch {
                            try {
                                ttsServerClient.streamTts(
                                    text = textChunk,
                                    outputChannel = audioChannel,
                                )
                            } catch (e: Exception) {
                                SLog.e("TTS streaming error: ${e.message}")
                                audioChannel.send(TtsServerClient.TtsAudioChunk(ByteArray(0), true))
                            }
                        }

                        // Forward audio chunks to client
                        for (audioChunk in audioChannel) {
                            if (isStale()) break
                            if (audioChunk.audio.isEmpty() || audioChunk.isEnd) break

                            SLog.i("Sending TTS audio to client: ${audioChunk.audio.size} bytes")

                            // Send as simple JSON with base64 audio (efficient, easy to parse)
                            val audioB64 = java.util.Base64.getEncoder().encodeToString(audioChunk.audio)
                            val ttsJson = buildJsonObject {
                                put("type", "tts_audio_result_response")
                                put("uuid", uuid)
                                put("audio_base64", audioB64)
                                put("is_end", audioChunk.isEnd)
                                put("format", "pcm_int16_24000")
                            }
                            outputChannel.send(Frame.Text(ttsJson.toString()))

                            if (false) {
                                // Original protobuf path (for future Atria client compat)
                                val ttsResponse = json.encodeToString(
                                    UnifiedResponse.serializer(),
                                    UnifiedResponse.TtsAudioResult(
                                        uuid = uuid,
                                        llmCompletionId = completionId,
                                        ttsAudioResult = elevenlabs.ElevenLabsRepository.WebsocketAudioResult(
                                            text = "",
                                            byteArray = audioChunk.audio,
                                            isEnd = audioChunk.isEnd,
                                            alignment = null,
                                        ),
                                        deviceStartTime = deviceStartTime,
                                        clientTimingId = clientTimingId,
                                    )
                                )
                                outputChannel.send(Frame.Text(ttsResponse))
                            }
                        }
                    }
                }
                // LLM must finish first (it feeds text to TTS channel)
                llmJob.join()
                // Then wait for TTS to drain all remaining chunks
                ttsJob.join()
                SLog.i("Pipeline complete for $uuid")
            } else {
                llmJob.join()
            }

        } catch (e: Exception) {
            SLog.e("Pipeline error for $uuid: ${e.message}")
            val errorResponse = json.encodeToString(
                UnifiedResponse.serializer(),
                UnifiedResponse.ErrorResult(
                    uuid = uuid,
                    errorSource = UnifiedResponse.ErrorResult.ErrorSource.UNKNOWN,
                    message = e.message ?: "Unknown error",
                )
            )
            outputChannel.send(Frame.Text(errorResponse))
        }
    }
}
