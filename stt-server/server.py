"""
Claire STT Server — Parakeet speech-to-text on GPU.
Port of atria-server's sttServer/server.py (simplified for Claire).
"""

import io
import numpy as np
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import PlainTextResponse
import logging

logger = logging.getLogger("claire-stt")

app = FastAPI(title="Claire STT Server")

# Model loaded at startup
stt_model = None


@app.on_event("startup")
async def load_model():
    global stt_model
    try:
        import nemo.collections.asr as nemo_asr
        logger.info("Loading Parakeet STT model...")
        stt_model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v2")
        stt_model.eval()
        logger.info("Parakeet STT model loaded successfully")
    except Exception as e:
        logger.error(f"Failed to load STT model: {e}")
        logger.info("STT server running without model — will return errors on transcribe requests")


@app.get("/health")
async def health():
    if stt_model is None:
        return PlainTextResponse("model not loaded", status_code=503)
    return PlainTextResponse("ok")


@app.post("/transcribe")
async def transcribe(request: Request):
    """
    Transcribe PCM audio (16kHz, 16-bit mono little-endian) to text.
    """
    if stt_model is None:
        raise HTTPException(status_code=503, detail="STT model not loaded")

    body = await request.body()
    if len(body) == 0:
        return PlainTextResponse("")

    try:
        # Convert raw PCM bytes to float32 numpy array
        audio_int16 = np.frombuffer(body, dtype=np.int16)
        audio_float32 = audio_int16.astype(np.float32) / 32768.0

        # Transcribe
        transcriptions = stt_model.transcribe([audio_float32])

        if isinstance(transcriptions, list) and len(transcriptions) > 0:
            # Handle different return types from NeMo
            text = transcriptions[0]
            if hasattr(text, "text"):
                text = text.text
            return PlainTextResponse(str(text).strip())
        else:
            return PlainTextResponse("")

    except Exception as e:
        logger.error(f"Transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=1236)
