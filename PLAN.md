# Claire Server — Implementation Plan

## Overview

Build the server component for Claire (Voice AI agent for Claude) in caminojc/claire. The server runs on a DGX and orchestrates the STT -> Claude API -> TTS pipeline over WebSocket, maintaining protocol compatibility with the Atria client transport layer.

## Architecture

```
Claire Server (DGX)
├── Realtime Server (Kotlin/Ktor, port 8080)
│   ├── /unified WebSocket endpoint
│   ├── AnthropicClient (Claude Messages API, streaming)
│   ├── SttServerClient (HTTP to local STT)
│   └── TtsServerClient (WebSocket to local TTS)
├── STT Server (Python/FastAPI, port 1236)
│   └── Parakeet v2 (NeMo, GPU-accelerated)
└── TTS Server (Python/FastAPI, port 1238)
    └── Kokoro-82M (local, GPU)
```

**No llama.cpp** — Claude is the only LLM.
**No native libs** — STT is handled by the Python server, not whisper.cpp JNI.
**No database server** — telemetry can be added later.
**No ElevenLabs fallback** — Kokoro only for v1.
**No tool execution** — no weather/time tools for v1.

## Protocol Compatibility

The client (Atria native transport) speaks:
- **Config:** `UnifiedRequest.Config` (JSON text frame)
- **Payload:** `PayloadRequestMessage` (protobuf binary frame) with mel-encoded audio + chat history
- **Responses:** `UnifiedResponse.SttTextResult` (JSON), `UnifiedResponse.LlmCompletionResult` (JSON), `TtsResponseMessage` (protobuf binary)

We must maintain this protocol exactly. We include `atria-kotlin` as a submodule for the shared data classes.

## Implementation Steps

### Phase 1: Project Scaffolding
1. Initialize Kotlin/Ktor Gradle project in `claire/server/`
2. Add `atria-kotlin` as a git submodule for shared data models
3. Set up `build.gradle.kts` with dependencies:
   - Ktor Server (Netty, WebSocket, Content Negotiation)
   - Ktor Client (OkHttp, WebSocket, Content Negotiation)
   - Kotlinx Serialization (JSON + Protobuf)
   - Koin (DI)
   - Same versions as atria-server: Kotlin 2.0.20, Ktor 2.3.12, Koin 3.4.0
4. Create `settings.gradle.kts` including the atria-kotlin submodule

### Phase 2: Core Server
5. `Application.kt` — Ktor Netty server on port 8080, module init, no native lib loading
6. `Koin.kt` — DI setup: AnthropicClient, SttServerClient, TtsServerClient, Json, HttpClient
7. `Routing.kt` — `/unified` WebSocket route, `/ping`, `/health`
8. Basic auth middleware (simplified)

### Phase 3: Claude LLM Integration
9. `AnthropicClient.kt` — wraps Claude Messages API via Ktor HTTP client
   - POST to `https://api.anthropic.com/v1/messages` with streaming
   - Convert `List<Message>` (OpenAI format from client) -> Claude messages format
   - Stream response chunks and emit as `OpenAiChatCompletionChunk` (for protocol compat with client)
   - Claire system prompt: conversational, warm, phone-call persona
   - API key from `ANTHROPIC_API_KEY` env var
   - Model: `claude-sonnet-4-20250514` (fast, capable)

### Phase 4: Unified WebSocket Route
10. `UnifiedRoute.kt` — simplified from atria-server's 1196-line version:
    - Handle `UnifiedRequest.Config` — store session prefs, respond with `UnifiedResponse.Config`
    - Handle `UnifiedRequest.Payload` (JSON) and `PayloadRequestMessage` (protobuf) — extract audio + chat history
    - **STT phase:** Forward audio to STT server (PCM or mel), get text, emit `SttTextResult`
    - **LLM phase:** Send conversation to Claude via AnthropicClient, stream tokens, emit `LlmCompletionResult`, feed into TTS text filter
    - **TTS phase:** Consume text chunks from `TtsChunkedTextFilter`, send to Kokoro TTS server, emit `TtsResponseMessage` (protobuf binary)
    - Support barge-in: track `latestUnifiedRequestPayloadUuid`, cancel in-flight processing on new payload
    - Single output dispatcher for WebSocket frame ordering

### Phase 5: STT Server (Python)
11. Port `realtime-server/sttServer/server.py` to `claire/stt-server/`
    - FastAPI + uvicorn on port 1236
    - Parakeet v2 model (NeMo)
    - POST `/transcribe` — accepts PCM 16kHz 16-bit mono, returns text
    - Health endpoint
    - CUDA/GPU inference

### Phase 6: TTS Server (Python)
12. Port `realtime-server/ttsServer/server.py` to `claire/tts-server/`
    - FastAPI + uvicorn on port 1238
    - Kokoro-82M model
    - WebSocket streaming protocol (same as atria: config -> text chunks -> audio chunks -> done)
    - Output: PCM 24kHz or Opus OGG
    - Voice: `af_heart` (default Claire voice)
    - Health endpoint

### Phase 7: Docker & Deployment
13. `Dockerfile` — multi-stage build:
    - Stage 1: Build Kotlin server (Gradle shadowJar)
    - Stage 2: Runtime with CUDA 12.4.1, Python venvs for STT/TTS
14. `supervisord.conf` — 3 processes: realtime-server, stt-server, tts-server
15. `docker-compose.yml` — single container, GPU passthrough, ports 8080/1236/1238
16. `.env.example` — ANTHROPIC_API_KEY, PORT

### Phase 8: Claire Persona
17. System prompt for Claire:
    - Warm, conversational, natural phone-call style
    - Powered by Claude — knowledgeable, helpful, honest
    - Concise responses suited for voice (not walls of text)
    - Name: Claire

## File Structure

```
claire/
├── server/                          # Kotlin realtime server
│   ├── build.gradle.kts
│   ├── src/main/kotlin/com/claire/
│   │   ├── Application.kt
│   │   ├── Koin.kt
│   │   ├── routing/
│   │   │   ├── Routing.kt
│   │   │   └── UnifiedRoute.kt
│   │   ├── llm/
│   │   │   └── AnthropicClient.kt
│   │   ├── stt/
│   │   │   └── SttServerClient.kt
│   │   └── tts/
│   │       └── TtsServerClient.kt
│   └── src/main/resources/
├── stt-server/                      # Python STT
│   ├── server.py
│   └── requirements.txt
├── tts-server/                      # Python TTS
│   ├── server.py
│   └── requirements.txt
├── submodules/
│   └── atria-kotlin/                # Shared data models
├── settings.gradle.kts
├── build.gradle.kts                 # Root build
├── Dockerfile
├── docker-compose.yml
├── supervisord.conf
├── .env.example
└── PLAN.md
```

## Key Decisions

1. **Protocol compat over simplicity** — We use atria-kotlin's exact data classes so the Atria native transport works unchanged on the client side.
2. **Claude responses as OpenAI chunks** — The client expects `OpenAiChatCompletionChunk` format. We wrap Claude's streaming response in this format so the client protocol doesn't need changes.
3. **No whisper.cpp native** — Unlike atria-server which loads whisper.cpp via JNI for mel-codec STT, we route all STT through the Python server. The server will need to handle mel decoding if the client sends mel-encoded audio (or we configure the client to send PCM/Opus instead).
4. **Start with Kotlin server + Python STT/TTS** — Match the proven atria-server architecture. Can simplify to pure Python later if needed.

## Open Questions

- **Mel codec on server:** atria-server uses native whisper.cpp to decode mel-encoded audio directly. If we skip native libs, do we configure the client to send PCM16 or Opus instead of mel? Or do we port the mel decoder to the Python STT server?
- **DGX access:** Need SSH access / Docker setup details for deployment.
