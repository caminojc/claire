package com.claire.llm

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.utils.io.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.*
import logging.SLog
import openai.*
import schemas.Message

/**
 * Claire's brain — wraps Claude Messages API with streaming.
 * Converts between OpenAI-format messages (from Atria client protocol)
 * and Anthropic API format.
 */
class AnthropicClient(
    private val httpClient: HttpClient,
    private val json: Json,
) {
    private val apiKey: String = System.getenv("ANTHROPIC_API_KEY") ?: ""
    private val model: String = System.getenv("CLAIRE_MODEL") ?: "claude-haiku-4-5-20251001"
    private val apiUrl = "https://api.anthropic.com/v1/messages"

    companion object {
        val CLAIRE_SYSTEM_PROMPT: String by lazy {
            try {
                val resource = AnthropicClient::class.java.classLoader.getResourceAsStream("claire-system-prompt.txt")
                resource?.bufferedReader()?.readText()
                    ?: DEFAULT_PROMPT
            } catch (e: Exception) {
                DEFAULT_PROMPT
            }
        }

        private const val DEFAULT_PROMPT = """You are Claire, a helpful voice agent. You communicate naturally and concisely, respecting that voice conversations should be efficient and clear. Lead with the answer, add one relevant supporting detail, and skip filler. Every word should earn its place."""
    }

    /**
     * Stream Claude's response as OpenAiChatCompletionChunk objects
     * for protocol compatibility with the Atria client.
     */
    fun streamCompletion(
        messages: List<Message>,
        systemPrompt: String? = null,
    ): Flow<OpenAiChatCompletionChunk> = flow {
        val system = systemPrompt ?: CLAIRE_SYSTEM_PROMPT

        // Convert messages to Anthropic format
        val anthropicMessages = buildJsonArray {
            for (msg in messages) {
                if (msg.role == OpenAiRole.SYSTEM || msg.role == OpenAiRole.PROMPT) continue
                addJsonObject {
                    put("role", when (msg.role) {
                        OpenAiRole.USER -> "user"
                        OpenAiRole.ASSISTANT -> "assistant"
                        else -> "user"
                    })
                    put("content", msg.content)
                }
            }
        }

        // Use system prompt with cache_control for prompt caching
        val systemArray = buildJsonArray {
            addJsonObject {
                put("type", "text")
                put("text", system)
                putJsonObject("cache_control") { put("type", "ephemeral") }
            }
        }

        val requestBody = buildJsonObject {
            put("model", model)
            put("max_tokens", 256)  // Voice responses should be short
            put("system", systemArray)
            put("messages", anthropicMessages)
            put("stream", true)
        }

        val response = httpClient.preparePost(apiUrl) {
            header("x-api-key", apiKey)
            header("anthropic-version", "2023-06-01")
            contentType(ContentType.Application.Json)
            setBody(requestBody.toString())
        }.execute { httpResponse ->
            if (httpResponse.status != HttpStatusCode.OK) {
                val errorBody = httpResponse.bodyAsText()
                SLog.e("Claude API error ${httpResponse.status}: $errorBody")
                return@execute
            }

            val channel = httpResponse.bodyAsChannel()
            val completionId = "claire-${System.currentTimeMillis()}"
            var buffer = ""

            while (!channel.isClosedForRead) {
                val line = channel.readUTF8Line() ?: break

                if (line.startsWith("data: ")) {
                    val data = line.removePrefix("data: ").trim()
                    if (data == "[DONE]") break

                    try {
                        val event = json.parseToJsonElement(data).jsonObject
                        val type = event["type"]?.jsonPrimitive?.content

                        when (type) {
                            "content_block_delta" -> {
                                val delta = event["delta"]?.jsonObject
                                val text = delta?.get("text")?.jsonPrimitive?.content
                                if (text != null) {
                                    emit(OpenAiChatCompletionChunk(
                                        id = completionId,
                                        created = (System.currentTimeMillis() / 1000).toInt(),
                                        model = OpenAiModelId(model),
                                        choices = listOf(
                                            OpenAiChatChunk(
                                                index = 0,
                                                delta = OpenAiChatDelta(
                                                    role = null,
                                                    content = text,
                                                ),
                                                finishReason = null,
                                            )
                                        ),
                                    ))
                                }
                            }
                            "message_stop" -> {
                                emit(OpenAiChatCompletionChunk(
                                    id = completionId,
                                    created = (System.currentTimeMillis() / 1000).toInt(),
                                    model = OpenAiModelId(model),
                                    choices = listOf(
                                        OpenAiChatChunk(
                                            index = 0,
                                            delta = OpenAiChatDelta(),
                                            finishReason = OpenAiFinishReason.Stop,
                                        )
                                    ),
                                ))
                            }
                        }
                    } catch (e: Exception) {
                        SLog.e("Error parsing Claude SSE: ${e.message}")
                    }
                }
            }
        }
    }
}
