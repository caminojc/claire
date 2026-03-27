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
 * Local LLM client via llama.cpp server (OpenAI-compatible API).
 * Used for fast initial acknowledgment while Claude generates the full response.
 */
class LocalLlmClient(
    private val httpClient: HttpClient,
    private val json: Json,
) {
    private val serverUrl: String = System.getenv("LOCAL_LLM_URL") ?: "http://localhost:1234"

    companion object {
        const val LOCAL_SYSTEM_PROMPT = "You are Claire, a voice assistant. Give a brief 1-sentence acknowledgment or short answer. Be natural and conversational. No markdown."
    }

    /**
     * Quick response from local model — just 1-2 sentences.
     * Returns null if local LLM is unavailable.
     */
    suspend fun quickResponse(userMessage: String): String? {
        return try {
            val requestBody = buildJsonObject {
                put("model", "local")
                put("max_tokens", 50)
                put("temperature", 0.7)
                putJsonArray("messages") {
                    addJsonObject {
                        put("role", "system")
                        put("content", LOCAL_SYSTEM_PROMPT)
                    }
                    addJsonObject {
                        put("role", "user")
                        put("content", userMessage)
                    }
                }
            }

            val response = httpClient.post("$serverUrl/v1/chat/completions") {
                contentType(ContentType.Application.Json)
                setBody(requestBody.toString())
            }

            if (response.status == HttpStatusCode.OK) {
                val body = json.parseToJsonElement(response.bodyAsText()).jsonObject
                val content = body["choices"]?.jsonArray?.firstOrNull()
                    ?.jsonObject?.get("message")?.jsonObject?.get("content")?.jsonPrimitive?.content
                SLog.i("Local LLM response: '${content?.take(80)}'")
                content
            } else {
                SLog.e("Local LLM error: ${response.status}")
                null
            }
        } catch (e: Exception) {
            SLog.e("Local LLM unavailable: ${e.message}")
            null
        }
    }

    suspend fun healthCheck(): Boolean {
        return try {
            val response = httpClient.get("$serverUrl/health")
            response.status == HttpStatusCode.OK
        } catch (e: Exception) {
            false
        }
    }
}
