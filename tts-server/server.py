"""
Claire TTS Server — Kokoro text-to-speech on GPU.
Port of atria-server's ttsServer/server.py (simplified for Claire).
WebSocket streaming protocol compatible with Atria client.
"""

import asyncio
import base64
import json
import logging
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse

logger = logging.getLogger("claire-tts")

app = FastAPI(title="Claire TTS Server")

# Model loaded at startup
tts_model = None
SAMPLE_RATE = 24000


@app.on_event("startup")
async def load_model():
    global tts_model
    try:
        from kokoro import KPipeline
        logger.info("Loading Kokoro TTS model...")
        tts_model = KPipeline(lang_code="a")  # American English
        logger.info("Kokoro TTS model loaded successfully")
    except Exception as e:
        logger.error(f"Failed to load TTS model: {e}")
        logger.info("TTS server running without model — will return errors on TTS requests")


@app.get("/health")
async def health():
    if tts_model is None:
        return PlainTextResponse("model not loaded", status_code=503)
    return PlainTextResponse("ok")


@app.websocket("/ws")
async def websocket_tts(websocket: WebSocket):
    await websocket.accept()

    voice = "af_heart"
    speed = 1.0
    output_format = "pcm"

    try:
        while True:
            data = await websocket.receive_text()
            msg = json.loads(data)

            if "model" in msg:
                # Config message
                voice = msg.get("voice", voice)
                speed = msg.get("speed", speed)
                output_format = msg.get("output_format", output_format)
                logger.info(f"TTS config: voice={voice}, speed={speed}, format={output_format}")
                continue

            msg_type = msg.get("type", "")

            if msg_type == "text":
                text = msg.get("text", "").strip()
                if not text:
                    continue

                if tts_model is None:
                    await websocket.send_text(json.dumps({
                        "type": "error",
                        "message": "TTS model not loaded"
                    }))
                    continue

                try:
                    # Generate audio
                    generator = tts_model(text, voice=voice, speed=speed)

                    for i, (gs, ps, audio) in enumerate(generator):
                        if audio is None:
                            continue

                        # Convert to int16 PCM bytes
                        audio_np = audio.numpy() if hasattr(audio, "numpy") else np.array(audio)
                        audio_int16 = (audio_np * 32767).astype(np.int16)
                        audio_bytes = audio_int16.tobytes()

                        audio_b64 = base64.b64encode(audio_bytes).decode("utf-8")

                        await websocket.send_text(json.dumps({
                            "type": "audio",
                            "audio_base64": audio_b64,
                            "is_final": False,
                            "text_segment": text,
                            "duration_ms": int(len(audio_int16) / SAMPLE_RATE * 1000),
                        }))

                except Exception as e:
                    logger.error(f"TTS generation error: {e}")
                    await websocket.send_text(json.dumps({
                        "type": "error",
                        "message": str(e)
                    }))

            elif msg_type == "end":
                await websocket.send_text(json.dumps({"type": "done"}))
                break

    except WebSocketDisconnect:
        logger.info("TTS WebSocket disconnected")
    except Exception as e:
        logger.error(f"TTS WebSocket error: {e}")


@app.post("/synthesize")
async def synthesize(request: Request):
    """Simple HTTP TTS: POST text, get back PCM audio bytes."""
    body = await request.json()
    text = body.get("text", "").strip()
    voice_name = body.get("voice", "af_heart")
    speed_val = body.get("speed", 1.0)

    if not text or tts_model is None:
        return PlainTextResponse("no text or model", status_code=400)

    try:
        all_audio = []
        generator = tts_model(text, voice=voice_name, speed=speed_val)
        for i, (gs, ps, audio) in enumerate(generator):
            if audio is None:
                continue
            audio_np = audio.numpy() if hasattr(audio, "numpy") else np.array(audio)
            audio_int16 = (audio_np * 32767).astype(np.int16)
            all_audio.append(audio_int16.tobytes())

        pcm_bytes = b"".join(all_audio)
        import base64
        audio_b64 = base64.b64encode(pcm_bytes).decode("utf-8")

        return {"audio_base64": audio_b64, "sample_rate": SAMPLE_RATE, "format": "pcm_int16"}

    except Exception as e:
        logger.error(f"Synthesize error: {e}")
        return PlainTextResponse(str(e), status_code=500)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=1238)
