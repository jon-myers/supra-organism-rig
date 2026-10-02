#!/usr/bin/env python3
"""render_mixes.py (2026-10-02) -- LISTENING MIXES for the FOLLOW MIX: renders played together, their shares driven by a stretch
of yesterday's run (follow_study.engine, equal-power gains), written as headphone files so the variants can be compared by ear.
All mixes in one set share one normalisation, so loudness differences are real. A 2-minute run-in before the data window lets the
lag settle, as it would live.
  out/tornado_*.wav   the five microtonal tornado sets (breath, sung, fry, harmonium, mixed; BINAURAL), 17:22-17:26 of the run
  out/rite_*.wav      the eight octave-down Rite renders (stereo), 16:58-17:03 of the run
"""
import os, numpy as np, soundfile as sf
import follow_study as fs
SO = fs.SO; OUT = fs.OUT
TOR = os.path.join(SO, "tornado", "forann_line", "out_mic"); TSETS = ["breath", "sung", "fry", "harmonium", "mixed"]
RITE = os.path.join(SO, "concatenator-corpus", "out", "listen-rite1929half")
RNAMES = ["mic-everything__rite1929half300__part1000_pd0.50_t200_p10", "mic-harmonium__rite1929half300__part1000_pd0.95_t50_p5",
          "mic-aeolian__rite1929half300__part1000_pd0.95_t50_p5", "mic-voicebreath__rite1929half300__part1000_pd0.50_t200_p5",
          "mic-perc__rite1929half300__part1000_pd0.50_t200_p5", "mic-fry__rite1929half300__part1000_pd0.50_t200_p5",
          "mic-whoosh__rite1929half300__part1000_pd0.95_t50_p5", "mic-everything__rite1929half300__part1000_pd0.50_t200_p20"]
VAR = {"equal": None,
       "ACactivity_lag60to10_by7": ("ACact", dict(tau7=(60.0, 10.0), gamma=2.5)),
       "ACactivity_lag60": ("ACact", dict(tau=60.0, gamma=2.5)),
       "DC_lag30": ("DC", dict(tau=30.0, gamma=2.5))}

def shares(start, secs, n, var):
    if var is None: return np.full((int(secs * fs.FS), n), 1.0 / n)
    kind, kw = var; a = fs.idx(start) - int(120 * fs.FS); b = fs.idx(start) + int(secs * fs.FS)
    feats = {k: fs.features(a, b, k) for k in ("ACact", kind)}
    w, _ = fs.engine(feats[kind], n, cfeat=feats["ACact"], **kw); return w[int(120 * fs.FS):]

def render(tag, files, start, secs):
    xs = [sf.read(f, dtype="float32", always_2d=True) for f in files]; sr = xs[0][1]
    L = min(min(len(x) for x, _ in xs), int(secs * sr)); xs = [x[:L] for x, _ in xs]
    mixes = {}
    for name, var in VAR.items():
        w = shares(start, L / sr, len(files), var); tw = np.arange(len(w)) / fs.FS; ta = np.arange(L) / sr
        y = np.zeros((L, xs[0].shape[1]), np.float32)
        for i, x in enumerate(xs): y += x * np.sqrt(np.interp(ta, tw, w[:, i]))[:, None].astype(np.float32)
        mixes[name] = (y, w)
    peak = max(np.abs(y).max() for y, _ in mixes.values()); g = 10 ** (-1 / 20) / peak
    for name, (y, w) in mixes.items():
        p = os.path.join(OUT, f"{tag}_{name}.wav"); sf.write(p, y * g, sr, subtype="PCM_24")
        lead = np.bincount(np.argmax(w, 1), minlength=len(files)) / len(w)
        print(f"{p}: {L / sr:.0f} s, time each source leads {np.round(lead, 2).tolist()}")

if __name__ == "__main__":
    render("tornado", [os.path.join(TOR, f"forann_mic-{s}_tornado_BINAURAL.wav") for s in TSETS], "17:22:00", 240)
    render("rite", [os.path.join(RITE, n + "__norm.wav") for n in RNAMES], "16:58:00", 300)
