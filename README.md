# Claire

Voice AI agent for Claude. Real-time voice conversations with echo cancellation, on-device VAD, and streaming TTS.

## What It Does

Talk to Claude naturally. Claire captures your voice through the SMPL audio front-end (echo cancellation + noise suppression), segments speech with SegVox VAD, transcribes via Parakeet STT, generates responses with Claude, synthesizes speech with Kokoro TTS, and plays it back through the Zipper SDK — all with barge-in support.

## Architecture

```
Client (macOS / iOS)                    Server (DGX Spark)
┌────────────────────┐               ┌────────────────────────┐
│ Mic                │               │                        │
│  ↓                 │               │                        │
│ SMPL AFE (AEC+NS)  │               │                        │
│  ↓                 │  WebSocket    │                        │
│ SegVox VAD         │──────────────→│ Parakeet STT (GPU)     │
│  ↓                 │  PCM 16kHz    │  ↓                     │
│ Zipper SDK         │               │ Claude Haiku (API)     │
│  (encode+segment)  │               │  ↓                     │
│                    │←──────────────│ Kokoro TTS (GPU)       │
│ Zipper SDK         │  PCM 24kHz    │  streaming sentences   │
│  (playout+AEC ref) │               │                        │
│  ↓                 │               │                        │
│ Speaker            │               │                        │
└────────────────────┘               └────────────────────────┘
```

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
| Ktor WebSocket | 8080 | Orchestrates STT → LLM → TTS pipeline |
| Parakeet v2 (NeMo) | 1236 | GPU speech-to-text |
| Kokoro-82M | 1238 | GPU text-to-speech, streaming |
| Claude Haiku | — | Fast conversational AI |

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

# STT
cd stt-server && pip install -r requirements.txt
python -m uvicorn server:app --port 1236

# TTS
cd tts-server && pip install -r requirements.txt
python -m uvicorn server:app --port 1238

# Realtime server
cd server && ../gradlew run
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | Required |
| `CLAIRE_MODEL` | `claude-haiku-4-5-20251001` | Claude model |
| `CLAIRE_VOICE` | `af_heart` | Kokoro voice |
| `PORT` | `8080` | Server port |

## Status

Working end-to-end:
- Voice capture with SMPL AFE echo cancellation
- SegVox VAD speech detection
- Parakeet STT transcription
- Claude Haiku responses
- Kokoro TTS with sentence-level streaming
- Zipper SDK playout with AEC reference
- Barge-in support
- Text chat alongside voice
- Conversation history

## License

Private — demo project.
