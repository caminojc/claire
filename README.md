# Claire

Voice AI agent for Claude. Real-time voice conversations powered by Claude's intelligence, the SMPL audio stack (AFE, Zipper SDK, SegVox VAD), and self-hosted STT/TTS on NVIDIA DGX.

## What It Does

You talk. Claire listens (with echo cancellation), transcribes your speech, sends it to Claude, converts the response to speech, and plays it back — all in real time. Full duplex voice with barge-in support.

## Architecture

```
Client (macOS / iOS)                    Server (DGX Spark)
┌────────────────────┐               ┌────────────────────────┐
│ Mic → SMPL AFE ──→ │  WebSocket    │ Realtime Server (Ktor) │
│   PortAudio        │──────────────→│  ├─ STT (Parakeet)     │
│   SegVox VAD       │               │  ├─ LLM (Claude API)   │
│   PCM16 encoder    │               │  └─ TTS (Kokoro)       │
│                    │←──────────────│                        │
│ ←─ AVAudioPlayer   │  WebSocket    │  Streaming sentences   │
│   Zipper playout   │               │  Base64 PCM chunks     │
└────────────────────┘               └────────────────────────┘
```

### Client Stack
- **SMPL Zipper SDK** — audio pipeline: capture, AFE, VAD, segmentation, playout
- **SmplAFELib** — echo cancellation + noise suppression (NEON-optimized)
- **SegVox VAD** — fast on-device voice activity detection
- **PortAudio** — macOS audio I/O (CoreAudio backend)
- **SwiftUI** — modern phone-call UI with animated audio energy background

### Server Stack
- **Kotlin/Ktor** — WebSocket hub on port 8080
- **Parakeet v2** (NeMo) — GPU-accelerated speech-to-text on port 1236
- **Kokoro-82M** — GPU-accelerated text-to-speech on port 1238
- **Claude API** — Haiku for fast response, streaming tokens

## Quick Start

### Prerequisites
- macOS 14+ with Xcode 16+
- NVIDIA GPU server (DGX Spark or similar) with Docker or Python
- Anthropic API key

### Build Client
```bash
# Init submodules (Atria audio stack + shared models)
git submodule update --init --recursive

# Build native C++ audio library
cd client/native && ./build-ios.sh

# Open in Xcode
open client/Claire.xcodeproj
# Select Claire_macOS scheme, Build & Run
```

### Run Server
```bash
# On your GPU server:
export ANTHROPIC_API_KEY=sk-ant-...

# STT server
cd stt-server && pip install -r requirements.txt
python -m uvicorn server:app --port 1236

# TTS server
cd tts-server && pip install -r requirements.txt
python -m uvicorn server:app --port 1238

# Realtime server
cd server && ../gradlew run
```

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | Required |
| `CLAIRE_MODEL` | `claude-haiku-4-5-20251001` | Claude model |
| `CLAIRE_VOICE` | `af_heart` | Kokoro TTS voice |
| `PORT` | `8080` | WebSocket server port |
| `STT_SERVER_URL` | `http://localhost:1236` | STT endpoint |
| `TTS_SERVER_URL` | `http://localhost:1238` | TTS endpoint |

## Project Structure

```
claire/
├── client/                    # macOS/iOS SwiftUI app
│   ├── Claire/Sources/
│   │   ├── Views/            # UI (ContentView)
│   │   ├── Models/           # CallManager, ChatMessage
│   │   ├── Network/          # WebSocket client
│   │   ├── Audio/            # AudioManager (fallback)
│   │   └── Native/           # ObjC++ bridge to Zipper SDK
│   ├── native/               # CMake build for C++ audio lib
│   └── Frameworks/           # SMPLAudioProcessing.xcframework
├── server/                    # Kotlin realtime server
├── stt-server/                # Python Parakeet STT
├── tts-server/                # Python Kokoro TTS
├── submodules/
│   ├── atria/                # SMPL audio stack (C++)
│   └── atria-kotlin/         # Shared protocol models
└── PLAN.md
```

## License

Private — demo project.
