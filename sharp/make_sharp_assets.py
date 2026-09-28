"""
make_sharp_assets.py -- assets for the breath "sharpness" work (2026-09-26).

1. Per-voice nCVI inter-onset sequences for breath36_sharp.scd:
   sharp/iois.json = { "ncvi_levels": [...], "n": 128, "voices": [[seq per level] x 36] },
   each seq 128 IOIs with mean 1.0, made with Jon's rhythmic_sequence_maker (accelerando/ncvi.py),
   own seed per voice so no two voices share a rhythm.
2. Rhythmic-noise TARGETS for the concatenator experiment (option 3):
   ../concatenator-corpus/targets/ncvi_noise_<level>.wav, 60 s mono 44.1 kHz: pink-noise bursts with
   percussive envelopes at nCVI-50 onsets. Three sharpness levels (mean IOI / burst length):
   soft 1.0 s / 250 ms, mid 0.5 s / 120 ms, sharp 0.25 s / 60 ms.
   Plus targets/2020_60s.wav (60 s from 2:00 of Jon's 2020.mp3).
"""
import sys, json, os, numpy as np, soundfile as sf, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "accelerando"))
from ncvi import rhythmic_sequence_maker, nCVI

HERE = os.path.dirname(os.path.abspath(__file__)); CC = os.path.join(HERE, "..", "..", "concatenator-corpus", "targets")
LEVELS = [0, 10, 20, 35, 50, 70]; N = 128; NV = 36
out = {"ncvi_levels": LEVELS, "n": N, "voices": []}
for v in range(NV):
    np.random.seed(1000 + v); per = []
    for lv in LEVELS:
        d = np.asarray(rhythmic_sequence_maker(N, lv), dtype=float); d = d / d.mean()
        per.append([round(float(x), 5) for x in d])
    out["voices"].append(per)
json.dump(out, open(os.path.join(HERE, "iois.json"), "w"))
print("iois.json:", NV, "voices x", len(LEVELS), "levels; measured nCVI of voice 0:", [round(nCVI(np.array(s)), 1) for s in out["voices"][0]])

sr = 44100; T = 60.0; np.random.seed(7)
def pink(n):
    w = np.random.randn(n); f = np.fft.rfft(w); f /= np.maximum(1, np.arange(len(f))) ** 0.5; x = np.fft.irfft(f, n); return x / np.abs(x).max()
for name, ioi, blen in [("soft", 1.0, 0.25), ("mid", 0.5, 0.12), ("sharp", 0.25, 0.06)]:
    n_ev = int(T / ioi); d = np.asarray(rhythmic_sequence_maker(n_ev, 50), dtype=float); d = d / d.sum() * T
    onsets = np.concatenate([[0], np.cumsum(d)[:-1]]); y = np.zeros(int(T * sr))
    for t in onsets:
        L = int(sr * blen * np.exp(np.random.uniform(-0.4, 0.4))); env = np.exp(-np.linspace(0, 6, L)) * np.minimum(1, np.linspace(0, 1, L) * 50)
        a = np.random.uniform(0.4, 1.0); i0 = int(t * sr); seg = pink(L) * env * a; y[i0:i0 + L] += seg[:len(y) - i0]
    y /= np.abs(y).max() * 1.12; sf.write(os.path.join(CC, f"ncvi_noise_{name}.wav"), y, sr, subtype="PCM_24")
    print(name, n_ev, "bursts, nCVI", round(nCVI(d), 1))
subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-ss", "120", "-t", "60", "-i", "/Users/jon/Documents/pieces/2020.mp3", "-ac", "1", "-ar", "44100", os.path.join(CC, "2020_60s.wav")], check=True)
print("targets written to", os.path.abspath(CC))
