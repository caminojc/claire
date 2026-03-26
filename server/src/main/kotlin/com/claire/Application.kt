package com.claire

import com.claire.routing.configureRouting
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import kotlinx.coroutines.*
import logging.SLog
import org.koin.core.scope.Scope
import java.util.concurrent.Executors

val coroutineExceptionHandler = CoroutineExceptionHandler { _, exception ->
    SLog.e("Caught top level coroutine exception", exception)
}

val computeDispatcher = Dispatchers.Default
val computeScope = CoroutineScope(SupervisorJob() + computeDispatcher + coroutineExceptionHandler)
val backgroundThreadCount = (Runtime.getRuntime().availableProcessors() * 2).coerceAtLeast(4)
val backgroundDispatcher = Executors.newFixedThreadPool(backgroundThreadCount).asCoroutineDispatcher()
val backgroundScope = CoroutineScope(SupervisorJob() + backgroundDispatcher + coroutineExceptionHandler)

fun getPort(): Int = System.getenv("PORT")?.toInt() ?: 8080

fun main() {
    embeddedServer(
        factory = Netty,
        port = getPort(),
        module = Application::module,
    )
        .start(wait = true)
}

fun Application.module() {
    SLog.init(
        enableLogging = true,
        enableFatalSoftCrashes = false,
        recordCrashlyticsException = {},
        recordCrashlyticsLog = {},
    )
    val koinApplication = initKoin()
    val scope = koinApplication.koin.createScope<Application>()
    configureRouting(scope)
    SLog.i("Claire server started on port ${getPort()}")
}
