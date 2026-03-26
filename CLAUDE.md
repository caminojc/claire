# Claire — Voice AI Agent for Claude

## Project Overview

Claire is a voice AI demo app — phone-call style voice conversations with Claude. "Claire" is a play on Claude's name (female companion).

## Architecture

### Server (Kotlin/Ktor + Python, runs on DGX)
- `server/` — Kotlin realtime server, WebSocket hub on port 8080
  - `/unified` endpoint orchestrates STT → Claude → TTS pipeline
  - `AnthropicClient` wraps Claude Messages API with SSE streaming
  - Emits OpenAI-compatible chunks for protocol compatibility with Atria client
- `stt-server/` — Python/FastAPI, Parakeet STT on GPU (port 1236)
- `tts-server/` — Python/FastAPI, Kokoro TTS on GPU (port 1238)
- `submodules/atria-kotlin/` — shared data models for WebSocket protocol

### Client (Swift/SwiftUI, macOS + iOS)
- `client/Claire/` — SwiftUI app with phone-call UI
- Will integrate Atria C++ stack: Zipper SDK, SMPL AFE, CoreAudio engine, mel codec
- Currently uses Swift-native WebSocket and AVAudioEngine (placeholders)

## Key Commands

```bash
# Build server
cd server && ../gradlew shadowJar

# Run server locally
cd server && ../gradlew run

# Run STT server
cd stt-server && python -m uvicorn server:app --port 1236

# Run TTS server
cd tts-server && python -m uvicorn server:app --port 1238

# Docker build
docker compose up --build
```

## Environment Variables

- `ANTHROPIC_API_KEY` — required, Claude API key
- `CLAIRE_MODEL` — default `claude-sonnet-4-20250514`
- `CLAIRE_VOICE` — default `af_heart` (Kokoro voice)
- `PORT` — default `8080`
- `STT_SERVER_URL` — default `http://localhost:1236`
- `TTS_SERVER_URL` — default `ws://localhost:1238`

## Protocol

WebSocket at `/unified` — protocol-compatible with Atria native transport:
- Client sends `UnifiedRequest.Config` (JSON) then `PayloadRequestMessage` (protobuf)
- Server streams `SttTextResult`, `LlmCompletionResult`, `TtsResponseMessage`
- See `submodules/atria-kotlin/` for exact data class definitions

## Reference Repos

- `smplrtc/atria` — client voice stack (Zipper SDK, CoreAudio, AFE, mel codec)
- `smplrtc/atria-server` — server reference (full pipeline with OpenAI/llama.cpp)
- `smplrtc/atria-kotlin` — shared protocol data models (submodule)

## Style

- Kotlin server follows atria-server patterns (Koin DI, Ktor, coroutine-based)
- Swift client follows SwiftUI patterns with MVVM (CallManager as ObservableObject)
- Keep it simple — this is a demo app
