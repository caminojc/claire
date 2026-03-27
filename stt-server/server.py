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


whisper_model = None

@app.on_event("startup")
async def load_whisper():
    """Load whisper model for mel-encoded audio at startup."""
    global whisper_model
    try:
        from faster_whisper import WhisperModel
        logger.info("Loading faster-whisper large-v3 for mel transcription...")
        whisper_model = WhisperModel("large-v3", device="cuda", compute_type="float16")
        logger.info(f"Whisper loaded: n_mels={whisper_model.model.n_mels}")
    except Exception as e:
        logger.warning(f"Whisper load failed (mel path unavailable): {e}")
        try:
            logger.info("Trying whisper small.en on CPU...")
            whisper_model = WhisperModel("small.en", device="cpu")
            logger.info("Whisper small.en loaded on CPU")
        except Exception as e2:
            logger.error(f"All whisper models failed: {e2}")


@app.post("/transcribe_mel")
async def transcribe_mel(request: Request):
    """
    Transcribe mel-encoded audio from SMPL Zipper SDK.
    Pipeline: smpl_mel_dec → 80-band mel spectrogram → whisper generate → text
    """
    body = await request.body()
    if len(body) == 0:
        return PlainTextResponse("")

    codec = get_mel_codec()
    if codec is None:
        raise HTTPException(status_code=503, detail="Mel codec not available")
    if whisper_model is None:
        raise HTTPException(status_code=503, detail="Whisper model not loaded")

    try:
        import ctypes, time
        t0 = time.time()

        # Decode mel payload → mel spectrogram (80 bands, transposed for whisper)
        N_MELS = 80
        max_frames = 3000  # 30 seconds max
        mel_size = N_MELS * max_frames
        mel_buf = (ctypes.c_float * mel_size)()

        # transposed_out=1 gives us [n_mels, n_frames] layout (whisper format)
        err = codec.smpl_mel_dec(body, len(body), mel_buf, 1)
        if err != 0:
            logger.error(f"Mel decode error: {err}")
            raise HTTPException(status_code=400, detail=f"Mel decode error: {err}")

        t_dec = time.time()

        # Convert to numpy and find actual frame count
        mel_array = np.ctypeslib.as_array(mel_buf, shape=(mel_size,))
        # Find last non-zero element to determine actual length
        nonzero_idx = np.flatnonzero(mel_array)
        if len(nonzero_idx) == 0:
            return PlainTextResponse("")

        actual_len = nonzero_idx[-1] + 1
        n_frames = actual_len // N_MELS
        if n_frames == 0:
            return PlainTextResponse("")

        # Reshape to [n_mels, n_frames] then add batch dim [1, n_mels, n_frames]
        mel_spec = mel_array[:N_MELS * n_frames].reshape(N_MELS, n_frames)

        # Pad to whisper's expected chunk length (3000 frames = 30s)
        if n_frames < max_frames:
            padded = np.zeros((N_MELS, max_frames), dtype=np.float32)
            padded[:, :n_frames] = mel_spec
            mel_spec = padded

        mel_batch = np.expand_dims(mel_spec, 0)  # [1, 80, 3000]

        t_reshape = time.time()

        # Transcribe using CTranslate2 whisper
        import ctranslate2
        features = ctranslate2.StorageView.from_array(mel_batch)

        # Whisper prompts: SOT token, language, transcribe task
        tokenizer = whisper_model.hf_tokenizer
        sot = tokenizer.encode("<|startoftranscript|>")
        lang = tokenizer.encode("<|en|>")
        task = tokenizer.encode("<|transcribe|>")
        notimestamps = tokenizer.encode("<|notimestamps|>")
        prompts = [sot + lang + task + notimestamps]

        results = whisper_model.model.generate(features, prompts, beam_size=1, max_length=224)
        tokens = results[0].sequences_ids[0]
        text = tokenizer.decode(tokens).strip()

        t_transcribe = time.time()

        logger.info(f"Mel STT: {len(body)}B → {n_frames} frames → '{text[:80]}' "
                     f"(dec={t_dec-t0:.0f}ms reshape={t_reshape-t_dec:.0f}ms whisper={t_transcribe-t_reshape:.0f}ms)")

        return PlainTextResponse(text)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Mel transcription error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=1236)
