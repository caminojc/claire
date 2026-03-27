package com.claire.stt

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import logging.SLog

/**
 * Client for the local STT (Parakeet) server running on port 1236.
 */
class SttServerClient(
    private val httpClient: HttpClient,
) {
    private val sttServerUrl: String = System.getenv("STT_SERVER_URL") ?: "http://localhost:1236"

    /**
     * Transcribe audio to text. Supports PCM and mel-encoded payloads.
     */
    suspend fun transcribe(audioData: ByteArray, codec: String = "pcm16_16kHz"): String {
        val endpoint = if (codec == "smpl-mel") "/transcribe_mel" else "/transcribe"
        return try {
            SLog.i("STT: $endpoint (${audioData.size} bytes)")
            val response = httpClient.post("$sttServerUrl$endpoint") {
                contentType(ContentType.Application.OctetStream)
                setBody(audioData)
            }
            if (response.status == HttpStatusCode.OK) {
                response.bodyAsText().trim()
            } else {
                SLog.e("STT server error: ${response.status}")
                ""
            }
        } catch (e: Exception) {
            SLog.e("STT server connection failed: ${e.message}")
            ""
        }
    }

    suspend fun healthCheck(): Boolean {
        return try {
            val response = httpClient.get("$sttServerUrl/health")
            response.status == HttpStatusCode.OK
        } catch (e: Exception) {
            false
        }
    }
}
