package com.claire.routing

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.websocket.*
import org.koin.core.scope.Scope
import java.time.Duration

fun Application.configureRouting(scope: Scope) {
    install(WebSockets) {
        pingPeriod = Duration.ofSeconds(30)
        timeout = Duration.ofSeconds(120)  // Long timeout — TTS can take 10+ seconds
        maxFrameSize = Long.MAX_VALUE
        masking = false
    }

    routing {
        get("/") {
            call.respondText("Claire Server", ContentType.Text.Plain)
        }

        get("/ping") {
            call.respondText("pong", ContentType.Text.Plain)
        }

        get("/health") {
            call.respondText("ok", ContentType.Text.Plain)
        }

        val unifiedRoute = UnifiedRoute(scope)
        webSocket("/unified/{id?}", handler = unifiedRoute.route())
    }
}
