# Claire

Voice AI agent for Claude. Real-time voice conversations with echo cancellation, on-device VAD, and streaming TTS.

## What It Does

Talk to Claude naturally. Claire captures your voice through the SMPL audio front-end (echo cancellation + noise suppression), segments speech with SegVox VAD, transcribes via Parakeet STT, generates responses with a dual LLM system, synthesizes speech with Kokoro TTS, and plays it back through the Zipper SDK — all with barge-in support.

## Architecture

```
Client (macOS / iOS)                    Server (DGX Spark)
┌────────────────────┐               ┌────────────────────────────┐
│ Mic                │               │                            │
│  ↓                 │               │                            │
│ SMPL AFE (AEC+NS)  │               │                            │
│  ↓                 │  WebSocket    │                            │
│ SegVox VAD         │──────────────→│ Parakeet STT (GPU, ~80ms)  │
│  ↓                 │               │  ↓                         │
│ Zipper SDK         │               │ ┌─ Local 3B (~100ms TTFT)  │
│                    │               │ │  "Sure!" → TTS → play    │
│                    │               │ └─ Claude Haiku (~1s TTFT)  │
│ Zipper SDK         │←──────────────│    [full response] → TTS   │
│  (playout+AEC ref) │               │                            │
│  ↓                 │               │ Kokoro TTS (GPU, ~50ms)    │
│ Speaker            │               │                            │
└────────────────────┘               └────────────────────────────┘
```

### Dual LLM Strategy

Simple queries stay local. Complex queries go to Claude.

| Query | LLM | TTFT | Example |
|-------|-----|------|---------|
| Simple | Local 3B (Qwen) | ~100ms | "How are you?" → "I'm great!" |
| Complex | Claude Haiku | ~1s | "Explain AEC" → [detailed response] |
| Hybrid | Both | ~100ms + ~1s | Local ack plays while Claude thinks |

The local model handles greetings, acknowledgments, and simple questions without any network round-trip. Claude handles everything that needs real intelligence.

### Client
| Component | What It Does |
|-----------|-------------|
| SmplAFELib (1.8MB) | Echo cancellation, noise suppression, AGC |
| SegVox VAD | On-device voice activity detection |
| Zipper SDK | Audio pipeline: capture → AFE → VAD → encode → playout |
| PortAudio | macOS CoreAudio I/O |
| SwiftUI | Conversation UI with audio energy visualization |

### Server
| Component | Port | What It Does |
|-----------|------|-------------|
| Ktor WebSocket | 8080 | Orchestrates STT → LLM → TTS |
| Parakeet v2 (NeMo) | 1236 | GPU speech-to-text (~80ms) |
| Kokoro-82M | 1238 | GPU text-to-speech (~50ms/sentence) |
| llama.cpp (Qwen 3B) | 1234 | Local fast LLM (~100ms TTFT) |
| Claude Haiku | — | Cloud LLM for complex queries |

### RTT Budget

| Step | Time |
|------|------|
| Zipper VAD + encode | ~200ms |
| STT (Parakeet) | ~80ms |
| Local LLM (simple) | ~100ms |
| TTS (Kokoro) | ~50ms |
| **Simple query total** | **~430ms** |
| Claude Haiku (complex) | ~1100ms |
| **Complex query total** | **~1430ms** |

## Setup

### Client (macOS)

```bash
git submodule update --init --recursive

# Build C++ audio library
cd client/native && ./build-ios.sh

# Open and run
open client/Claire.xcodeproj
# Select Claire_macOS → Run
```

### Server (DGX / GPU)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export USE_LOCAL_LLM=true  # Enable dual LLM

# Local LLM
~/llama.cpp/build/bin/llama-server \
  -m ~/models/qwen2.5-3b-instruct-q8_0.gguf \
  -c 4096 --port 1234 --host 0.0.0.0

# STT
cd stt-server && source venv/bin/activate
python -m uvicorn server:app --port 1236

# TTS
cd tts-server && source venv/bin/activate
python -m uvicorn server:app --port 1238

# Realtime server
cd server && ../gradlew run
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | Required for Claude |
| `USE_LOCAL_LLM` | `false` | Enable local 3B for fast responses |
| `LOCAL_LLM_URL` | `http://localhost:1234` | llama.cpp server |
| `CLAIRE_MODEL` | `claude-haiku-4-5-20251001` | Claude model |
| `CLAIRE_VOICE` | `af_heart` | Kokoro voice |
| `PORT` | `8080` | Server port |

## Status

Working end-to-end:
- Voice capture with SMPL AFE echo cancellation
- SegVox VAD speech detection
- Parakeet STT transcription (~80ms)
- Dual LLM: local Qwen 3B + Claude Haiku
- Kokoro TTS with sentence-level streaming
- Zipper SDK playout with AEC reference
- Barge-in support
- Text chat alongside voice
- Prompt caching for faster Claude responses

## License

Private — demo project.
