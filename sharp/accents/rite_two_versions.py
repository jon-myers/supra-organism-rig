#!/usr/bin/env python3
"""rite_two_versions.py (2026-10-03, Jon: "can we make sure to only have no more than 2 versions of the rite of spring during the end?")
Rebuilds the TORNADO's Rite snatches (live/live.json "snatch", kinds rite_open / rite_mid) from TWO renders only, instead of the
8 export_live.py drew from: Jon's favourite, the octave-down mic-everything p20 (his pick for the opening), and its 1x sibling,
mic-everything p10. Openings (first 10 s) + middles; same 10-s whole stretches, 1.5-s / 2-s fades, RMS 0.05. Phantom Pain kept.
"""
import os, json, numpy as np, soundfile as sf
from export_live import fades, w, SR, LIVE
CC = "/Users/jon/Documents/2026/MIT/projects/supra-organism/concatenator-corpus/out"
FAV = f"{CC}/listen-rite1929half/mic-everything__rite1929half300__part1000_pd0.50_t200_p20__norm.wav"
SIB = f"{CC}/listen-rite1929/mic-everything__rite1929first150__part1000_pd0.50_t200_p10__norm.wav"
norm = lambda y: y / (np.sqrt((y ** 2).mean()) + 1e-9) * 0.05
man = json.load(open(os.path.join(LIVE, "live.json")))
keep = [s for s in man["snatch"] if s[0] == "pp"]
new = []
for i, (f, a, kind) in enumerate([(FAV, 0.0, "rite_open"), (SIB, 0.0, "rite_open"), (FAV, 40.0, "rite_mid"), (FAV, 75.0, "rite_mid"), (SIB, 40.0, "rite_mid")]):
    info = sf.info(f); y, sr = sf.read(f, dtype="float32", always_2d=True, start=int(a * info.samplerate), frames=int(10 * info.samplerate))
    if sr != SR:
        import librosa; y = librosa.resample(y.T, orig_sr=sr, target_sr=SR).T
    y = np.repeat(y, 2, 1) if y.shape[1] == 1 else y[:, :2]
    new.append([kind, w(os.path.join(LIVE, "snatch", f"rite2_{i:02d}.wav"), norm(fades(y, 1.5, 2.0)))])
    print(kind, os.path.basename(f), f"from {a:.0f} s")
man["snatch"] = new + keep
json.dump(man, open(os.path.join(LIVE, "live.json"), "w"))
print("snatch pool:", [s[0] for s in man["snatch"]])
