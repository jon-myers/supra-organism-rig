#!/usr/bin/env python3
"""features.py (2026-10-02) -- spectral features for OCEAN matching in breath36's PULSE.

The pulse decides WHEN a voice breathes; OCEAN decides WHICH of that voice's breaths: the one whose spectrum is closest to an
ocean recording at that moment. Features (numpy only):
  shape   24 log-mel bands (40 Hz .. 16 kHz), mean removed -> spectral SHAPE, independent of level
  rms     dB
Breath segments: every voice's 1x breath render (morph step 0 = breath), cut at the same onsets breath36 plays
(sharp/onsets.json; segment j = [ons[j], ons[j+1]] with ons = [0] + onsets), measured over the first 0.4 s (the attack -- PULSE
gates breaths short). Ocean: 100-ms windows every 50 ms.
  out: features_voices.json  {"voices": {"<orig voice no>": [[t0, dur, shape24, rmsdB], ...]}}
       ocean_<name>.json     {"hop": 0.05, "dur": s, "shape": [[24], ...], "rms": [dB, ...]}
"""
import json, os, numpy as np, soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__)); RIG = os.path.abspath(os.path.join(HERE, "..", ".."))
VOX = os.path.join(RIG, "breath36_voices"); CC = os.path.join(RIG, "..", "concatenator-corpus")
NB, FMIN, FMAX, NFFT = 24, 40.0, 16000.0, 4096

def melbank(sr):
    mel = lambda f: 2595 * np.log10(1 + f / 700); imel = lambda m: 700 * (10 ** (m / 2595) - 1)
    edges = imel(np.linspace(mel(FMIN), mel(FMAX), NB + 2)); f = np.fft.rfftfreq(NFFT, 1 / sr); W = np.zeros((NB, len(f)))
    for b in range(NB):
        lo, mid, hi = edges[b], edges[b + 1], edges[b + 2]
        W[b] = np.clip(np.minimum((f - lo) / (mid - lo), (hi - f) / (hi - mid)), 0, 1)
    return W

def feat(x, sr, W):
    if len(x) < 256: x = np.pad(x, (0, 256 - len(x)))
    hop = 1024; frames = [x[i:i + NFFT] for i in range(0, max(1, len(x) - NFFT + 1), hop)] or [x]
    P = np.mean([np.abs(np.fft.rfft(np.pad(fr, (0, NFFT - len(fr))) * np.hanning(NFFT))) ** 2 for fr in frames], 0)
    m = np.log10(W @ P + 1e-12); shape = m - m.mean()
    rms = 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-9)
    return [round(float(v), 4) for v in shape], round(float(rms), 2)

def voices():
    meta = json.load(open(os.path.join(VOX, "voices.json"))); ons = json.load(open(os.path.join(RIG, "sharp", "onsets.json")))["voices"]
    out = {}
    for v in meta["voices"]:
        orig = int(v["voice"]); x, sr = sf.read(os.path.join(VOX, v["files"][0]), dtype="float64"); x = x.mean(1) if x.ndim > 1 else x
        W = melbank(sr); o = [0.0] + [float(t) for t in ons[orig - 1]]; total = len(x) / sr; segs = []
        for j, t0 in enumerate(o):
            t1 = o[j + 1] if j + 1 < len(o) else total; a = int(t0 * sr); b = int(min(t1, t0 + 0.4) * sr)
            sh, r = feat(x[a:b], sr, W); segs.append([round(t0, 3), round(t1 - t0, 3), sh, r])
        out[str(orig)] = segs
    json.dump({"bands": NB, "fmin": FMIN, "fmax": FMAX, "voices": out}, open(os.path.join(HERE, "features_voices.json"), "w"))
    print("voices:", len(out), "segments:", sum(len(s) for s in out.values()))

def ocean(name, path, ambix=False):
    x, sr = sf.read(path, dtype="float64"); x = x[:, 0] if ambix else (x.mean(1) if x.ndim > 1 else x)   # ambiX: W = omni
    W = melbank(sr); hop, win = int(0.05 * sr), int(0.1 * sr); sh, rm = [], []
    for i in range(0, len(x) - win, hop):
        s_, r = feat(x[i:i + win], sr, W); sh.append(s_); rm.append(r)
    json.dump({"hop": 0.05, "dur": round(len(x) / sr, 3), "path": path, "shape": sh, "rms": rm}, open(os.path.join(HERE, f"ocean_{name}.json"), "w"))
    print(f"ocean {name}: {len(sh)} frames, {len(x) / sr:.1f} s, rms {min(rm):.1f}..{max(rm):.1f} dB")

if __name__ == "__main__":
    voices()
    ocean("waves5min", os.path.join(CC, "targets", "ocean_waves_first5min.wav"))
    ocean("215", os.path.join(CC, "out", "ocean215", "ocean215_original_ambiX.wav"), ambix=True)
