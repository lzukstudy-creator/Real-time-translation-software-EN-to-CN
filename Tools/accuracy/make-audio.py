#!/usr/bin/env python3
"""Synthesise lecture audio with several macOS voices, then simulate a classroom:
far-field room reverb, background noise and a quiet lecturer.

Usage: make-audio.py OUTPUT_DIR
Writes <text>-<voice>-<condition>.wav (16 kHz mono) and refs.json.
"""
import json, subprocess, sys
from pathlib import Path
import numpy as np
from scipy.io import wavfile
from scipy.signal import fftconvolve

here = Path(__file__).resolve().parent
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
voices = {"daniel": ("Daniel", 180), "karen": ("Karen", 185), "moira": ("Moira", 175), "rishi": ("Rishi", 180)}
texts = {"lecture": here / "lecture-reference.txt", "challenge": here / "challenge-reference.txt"}
rng = np.random.default_rng(7)

def room(rt60=0.7, sr=16000):
    n = int(rt60 * sr)
    t = np.arange(n) / sr
    tail = rng.standard_normal(n) * np.exp(-6.9 * t / rt60)
    tail[: int(0.012 * sr)] = 0           # direct path arrives first, reflections after 12 ms
    ir = tail * 0.35; ir[0] = 1.0
    return ir / np.sqrt(np.sum(ir ** 2))

def pink(n):
    spectrum = np.fft.rfft(rng.standard_normal(n))
    spectrum /= np.sqrt(np.maximum(np.arange(len(spectrum)), 1))
    noise = np.fft.irfft(spectrum, n)
    return noise / np.std(noise)

refs = {}
for tname, tpath in texts.items():
    for vname, (voice, rate) in voices.items():
        stem = out / f"{tname}-{vname}"
        aiff = stem.with_suffix(".aiff")
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-f", str(tpath), "-o", str(aiff)], check=True)
        clean_wav = out / f"{tname}-{vname}-clean.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(clean_wav)], check=True)
        aiff.unlink()
        sr, x = wavfile.read(clean_wav); x = x.astype(np.float64) / 32768
        speech_rms = np.sqrt(np.mean(x[np.abs(x) > 1e-3] ** 2))
        # Classroom: reverberant room, ventilation/chatter noise at 12 dB SNR, quiet capture (-26 dBFS speech).
        y = fftconvolve(x, room(), mode="full")[: len(x)]
        y = y / np.sqrt(np.mean(y[np.abs(x) > 1e-3] ** 2)) * speech_rms
        noise = pink(len(y)) * speech_rms / (10 ** (12 / 20))
        y = y + noise
        y = y / np.sqrt(np.mean(y ** 2)) * 10 ** (-26 / 20)
        wavfile.write(out / f"{tname}-{vname}-classroom.wav", sr, np.clip(y * 32767, -32768, 32767).astype(np.int16))
        for cond in ("clean", "classroom"):
            refs[f"{tname}-{vname}-{cond}.wav"] = tpath.read_text()
(out / "refs.json").write_text(json.dumps(refs, indent=1))
print(len(refs), "files in", out)
