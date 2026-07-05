#!/usr/bin/env python3
"""Yappy TTS helper: loads a Kokoro TTS model once, then serves synthesis
requests over stdio. One JSON object per line on stdin:
  {"text": "...", "voice": "af_heart", "out": "/path/out.wav", "pad_start": false}
One JSON reply per line on stdout:
  {"ok": true, "out": "...", "secs": 1.23, "duration": 4.56}  or  {"ok": false, "error": "..."}
A first line {"ready": true, "load_secs": ...} is emitted once the model is loaded.
"""
import json
import os
import re
import sys
import time

# Kokoro's English G2P (misaki) falls back to espeak-ng for out-of-dictionary
# words; phonemizer needs to be pointed at the Homebrew dylib since it isn't on
# the default search path. Set before importing mlx_audio.
if "PHONEMIZER_ESPEAK_LIBRARY" not in os.environ:
    for _lib in ("/opt/homebrew/lib/libespeak-ng.dylib", "/usr/local/lib/libespeak-ng.dylib"):
        if os.path.exists(_lib):
            os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = _lib
            break

# The protocol channel is a private dup of the original stdout; fd 1 is then
# pointed at stderr so library prints (progress bars, banners) can never
# corrupt the JSON-lines protocol.
_proto = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = os.fdopen(1, "w", buffering=1)


def emit(obj):
    _proto.write(json.dumps(obj) + "\n")
    _proto.flush()


import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from scipy.io import wavfile  # noqa: E402

# mlx-audio's Kokoro iSTFTNet vocoder intermittently raises a harmonic-source
# broadcast mismatch (the harmonic tensor comes out a few hundred samples longer
# than the audio) for certain (voice, text) durations. It's deterministic per
# input and independent of quantization. A tiny speed jitter shifts every
# predicted duration and reliably dodges the bad length while staying
# prosodically natural; the values below were proven to clear a 24-voice x
# 5-text matrix (120/120). Splitting on sentence boundaries is the last resort.
_SPEED_JITTERS = (1.0, 1.03, 0.97, 1.06, 0.94, 1.09, 0.91)


def _generate_once(model, text, voice, speed):
    segments = []
    sample_rate = 24000
    for result in model.generate(text=text, voice=voice, speed=speed):
        segments.append(result.audio)
        sample_rate = getattr(result, "sample_rate", sample_rate) or sample_rate
    if not segments:
        raise ValueError("no audio produced")
    audio = mx.concatenate(segments) if len(segments) > 1 else segments[0]
    return audio, sample_rate


def trim_silence(arr, sample_rate, threshold=0.01, margin_ms=20):
    """Trim leading/trailing near-silence Kokoro pads onto each clip (~0.3s), so
    the first word starts sooner and consecutive chunks play gaplessly. Keeps a
    small margin so a soft onset is never clipped; a fully silent clip is left
    untouched."""
    if arr.size == 0:
        return arr
    loud = np.nonzero(np.abs(arr) > threshold)[0]
    if loud.size == 0:
        return arr
    margin = int(sample_rate * margin_ms / 1000)
    start = max(0, int(loud[0]) - margin)
    end = min(arr.shape[-1], int(loud[-1]) + margin + 1)
    return arr[start:end]


def synth_audio(model, text, voice, allow_split=True):
    last = None
    for speed in _SPEED_JITTERS:
        try:
            return _generate_once(model, text, voice, speed)
        except (ValueError, AssertionError) as e:
            # Jitter dodges two mlx-audio Kokoro vocoder glitches: the harmonic
            # source broadcast mismatch (ValueError) and a stray zero-sample
            # segment (AssertionError "No audio generated", kokoro.py). Anything
            # else — including our own "no audio produced" for empty input — is a
            # real error and surfaces immediately instead of retrying seven times.
            retryable = isinstance(e, AssertionError) or "broadcast" in str(e)
            if not retryable:
                raise
            last = e
    if allow_split:
        parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()]
        if len(parts) > 1:
            chunks, sample_rate = [], 24000
            for part in parts:
                audio, sample_rate = synth_audio(model, part, voice, allow_split=False)
                chunks.append(audio)
            return mx.concatenate(chunks), sample_rate
    raise last


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Kokoro-82M-8bit"
    t0 = time.time()
    from mlx_audio.tts.utils import load_model
    model = load_model(model_id)
    load_secs = round(time.time() - t0, 2)

    # The first generate() call compiles MLX's compute graph — ~1.3s, independent
    # of text or voice — while every call after is ~0.1s. Pay that cost here so a
    # Fn-down prewarm absorbs it during the model's research, and the first real
    # answer chunk plays almost immediately instead of stalling ~1.3s. The graph
    # is voice-independent, so warming any voice makes all of them fast.
    t_warm = time.time()
    try:
        synth_audio(model, "Ready.", "af_heart")
    except Exception:  # noqa: BLE001 - warmup is best-effort; never block readiness
        pass

    emit({"ready": True, "load_secs": load_secs, "warm_secs": round(time.time() - t_warm, 2)})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            t1 = time.time()
            audio, sample_rate = synth_audio(model, req["text"], req.get("voice") or "af_heart")
            arr = np.array(audio, copy=False).astype(np.float32)
            # Drop Kokoro's ~0.3s of leading/trailing padding so the first word
            # starts sooner and chunks are gapless.
            arr = trim_silence(arr, sample_rate)
            # Prepend a little silence on the opening clip so the audio output
            # device warms up on silence instead of clipping the first word.
            if req.get("pad_start"):
                pad = np.zeros(int(sample_rate * 0.28), dtype=arr.dtype)
                arr = np.concatenate([pad, arr])
            wavfile.write(req["out"], int(sample_rate), arr)
            dur = float(arr.shape[-1]) / float(sample_rate)
            emit({"ok": True, "out": req["out"], "secs": round(time.time() - t1, 2),
                  "duration": round(dur, 2)})
        except Exception as e:  # noqa: BLE001 - report everything to the caller
            emit({"ok": False, "error": f"{type(e).__name__}: {e}"[:300]})


if __name__ == "__main__":
    main()
