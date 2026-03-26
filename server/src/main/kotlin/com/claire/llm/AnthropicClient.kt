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
    private val model: String = System.getenv("CLAIRE_MODEL") ?: "claude-sonnet-4-20250514"
    private val apiUrl = "https://api.anthropic.com/v1/messages"

    companion object {
        const val CLAIRE_SYSTEM_PROMPT = """You are Claire, a warm and engaging voice AI companion powered by Claude. You're having a natural phone conversation.

Keep your responses concise and conversational — you're speaking, not writing. Aim for 1-3 sentences unless the topic needs more depth. Use natural speech patterns.

Be helpful, honest, and friendly. You have Claude's full intelligence but express it in a natural, spoken way. Avoid bullet points, markdown, or anything that doesn't sound natural when spoken aloud.

If you don't know something, say so naturally rather than hedging with caveats."""
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

        val requestBody = buildJsonObject {
            put("model", model)
            put("max_tokens", 1024)
            put("system", system)
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
