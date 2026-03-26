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
     * Transcribe PCM audio (16kHz, 16-bit mono) to text.
     */
    suspend fun transcribe(pcmAudio: ByteArray): String {
        return try {
            val response = httpClient.post("$sttServerUrl/transcribe") {
                contentType(ContentType.Application.OctetStream)
                setBody(pcmAudio)
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
