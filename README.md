# Claire

Voice AI agent for Claude. Phone-call style voice conversations powered by Claude's intelligence, the SMPL Atria audio stack, and self-hosted STT/TTS on NVIDIA DGX.

## Architecture

```
Claire Client (macOS / iOS)              Claire Server (DGX)
┌──────────────────────┐             ┌──────────────────────────┐
│ Mic → SMPL AFE →     │  WebSocket  │ Realtime Server (Ktor)   │
│ Mel Encode → ────────┼────────────→│   ├── STT (Parakeet)     │
│                      │             │   ├── LLM (Claude API)   │
│ Speaker ← Decode ←───┼────────────←│   └── TTS (Kokoro)       │
└──────────────────────┘             └──────────────────────────┘
```

### Server Components

| Component | Stack | Port | Purpose |
|-----------|-------|------|---------|
| Realtime Server | Kotlin/Ktor | 8080 | WebSocket hub, orchestrates STT → Claude → TTS |
| STT Server | Python/FastAPI | 1236 | Parakeet speech-to-text (GPU) |
| TTS Server | Python/FastAPI | 1238 | Kokoro text-to-speech (GPU) |

### Client Components (planned)

Porting the SMPL Atria voice stack (C++) for native macOS + iOS:
- Zipper SDK — VAD, segmentation, mel encoding, playout with barge-in
- SmplCoreAudioEngine — CoreAudio I/O (no WebRTC)
- Native transport — WebSocket + protobuf
- SwiftUI app — minimal phone-call UI

## Quick Start

### Prerequisites
- NVIDIA GPU with CUDA 12.4+
- Docker with NVIDIA runtime
- Anthropic API key

### Run with Docker

```bash
cp .env.example .env
# Edit .env with your ANTHROPIC_API_KEY

docker compose up --build
```

### Run Locally (Development)

```bash
# Terminal 1: STT server
cd stt-server && pip install -r requirements.txt
python -m uvicorn server:app --host 0.0.0.0 --port 1236

# Terminal 2: TTS server
cd tts-server && pip install -r requirements.txt
python -m uvicorn server:app --host 0.0.0.0 --port 1238

# Terminal 3: Realtime server
cd server && ./gradlew run
```

### WebSocket Protocol

Connect to `ws://host:8080/unified` and send:

1. **Config** (JSON): session preferences (codec, TTS voice, etc.)
2. **Payload** (protobuf or JSON): audio + chat history

Server streams back: STT text → LLM tokens → TTS audio chunks.

Protocol is compatible with the Atria native transport client.

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | Claude API key (required) |
| `PORT` | 8080 | Realtime server port |
| `STT_SERVER_URL` | `http://localhost:1236` | STT server URL |
| `TTS_SERVER_URL` | `ws://localhost:1238` | TTS server WebSocket URL |
| `CLAIRE_MODEL` | `claude-sonnet-4-20250514` | Claude model ID |
| `CLAIRE_VOICE` | `af_heart` | Kokoro TTS voice |

## Project Structure

```
claire/
├── server/              # Kotlin realtime server (Ktor + WebSocket)
├── stt-server/          # Python STT server (Parakeet)
├── tts-server/          # Python TTS server (Kokoro)
├── submodules/
│   └── atria-kotlin/    # Shared data models (protocol compat)
├── docker-compose.yml
├── supervisord.conf
└── PLAN.md              # Detailed implementation plan
```

## License

Private — demo project.
