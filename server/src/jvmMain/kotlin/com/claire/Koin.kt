package com.claire

import com.claire.llm.AnthropicClient
import com.claire.llm.LocalLlmClient
import com.claire.stt.SttServerClient
import com.claire.tts.TtsServerClient
import kotlinx.serialization.json.Json
import org.koin.core.context.startKoin
import org.koin.core.scope.Scope
import org.koin.core.qualifier.named
import org.koin.dsl.module
import io.ktor.client.*
import io.ktor.client.engine.okhttp.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.websocket.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.coroutines.CoroutineScope
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import org.koin.dsl.koinApplication
import java.util.concurrent.TimeUnit

fun initKoin() = koinApplication {
    allowOverride(false)
    modules(globalModule)
}

val globalModule = module {
    single { computeScope }
    single(named("background")) { backgroundScope }
    single(named("background")) { backgroundDispatcher }
    single {
        Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
        }
    }
    single {
        OkHttpClient.Builder()
            .connectionPool(
                ConnectionPool(
                    maxIdleConnections = 5,
                    keepAliveDuration = 15,
                    timeUnit = TimeUnit.SECONDS
                )
            )
            .build()
    }
    single {
        val okHttpClient: OkHttpClient = get()
        HttpClient(OkHttp) {
            engine {
                preconfigured = okHttpClient
            }
            install(ContentNegotiation) {
                json(get())
            }
            install(WebSockets) {
                pingInterval = 10_000
            }
            defaultRequest {
                contentType(ContentType.Application.Json)
            }
        }
    }
    single {
        com.claire.stt.SttNativeProcessor().also { processor ->
            try {
                val modelDir = System.getenv("WHISPER_MODEL_DIR") ?: "models"
                processor.init(modelDir)
            } catch (e: Exception) {
                logging.SLog.e("Native STT init skipped: ${e.message}")
            }
        }
    }
    single { AnthropicClient(get(), get()) }
    single { LocalLlmClient(get(), get()) }
    single { SttServerClient(get()) }
    single { TtsServerClient(get()) }
}
