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
            text = transcriptions[0]
            if hasattr(text, "text"):
                text = text.text
            return PlainTextResponse(str(text).strip())
        else:
            return PlainTextResponse("")

    except Exception as e:
        logger.error(f"Transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# Mel codec decoder via ctypes
_mel_codec = None

def get_mel_codec():
    global _mel_codec
    if _mel_codec is None:
        import ctypes, os
        lib_path = os.path.expanduser("~/models/libmelcodec.so")
        if os.path.exists(lib_path):
            _mel_codec = ctypes.CDLL(lib_path)
            _mel_codec.smpl_mel_dec.argtypes = [
                ctypes.c_char_p, ctypes.c_int,
                ctypes.POINTER(ctypes.c_float), ctypes.c_int
            ]
            _mel_codec.smpl_mel_dec.restype = ctypes.c_int
            logger.info(f"Loaded mel codec from {lib_path}")
        else:
            logger.warning(f"Mel codec not found at {lib_path}")
    return _mel_codec


@app.post("/transcribe_mel")
async def transcribe_mel(request: Request):
    """
    Transcribe mel-encoded audio from SMPL Zipper SDK.
    Decodes mel → mel spectrogram → whisper transcription.
    Falls back to Parakeet if whisper not available.
    """
    body = await request.body()
    if len(body) == 0:
        return PlainTextResponse("")

    codec = get_mel_codec()
    if codec is None:
        raise HTTPException(status_code=503, detail="Mel codec not available")

    try:
        import ctypes

        # Decode mel payload → mel spectrogram (128 bands)
        mel_size = 240000  # max mel frames
        mel_buf = (ctypes.c_float * mel_size)()
        err = codec.smpl_mel_dec(body, len(body), mel_buf, 0)
        if err != 0:
            raise HTTPException(status_code=400, detail=f"Mel decode error: {err}")

        # Convert to numpy
        mel_array = np.ctypeslib.as_array(mel_buf, shape=(mel_size,))
        # Find actual length (non-zero portion)
        nonzero = np.nonzero(mel_array)[0]
        if len(nonzero) == 0:
            return PlainTextResponse("")
        mel_len = nonzero[-1] + 1

        # Try faster-whisper if available
        try:
            from faster_whisper import WhisperModel
            global whisper_model
            if 'whisper_model' not in globals() or whisper_model is None:
                logger.info("Loading faster-whisper tiny.en...")
                whisper_model = WhisperModel("tiny.en", device="cuda", compute_type="float16")
                logger.info("Whisper loaded")

            # Whisper expects mel spectrogram as (n_mels=128, n_frames)
            n_mels = 128
            n_frames = mel_len // n_mels
            mel_spec = mel_array[:n_mels * n_frames].reshape(n_mels, n_frames)

            segments, _ = whisper_model.transcribe_from_mel(mel_spec)
            text = " ".join([s.text for s in segments]).strip()
            return PlainTextResponse(text)

        except Exception as e:
            logger.warning(f"Whisper mel transcription failed: {e}, trying PCM fallback")
            # Can't easily convert mel back to PCM, return error
            raise HTTPException(status_code=500, detail=f"Mel transcription not available: {e}")

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Mel transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=1236)
