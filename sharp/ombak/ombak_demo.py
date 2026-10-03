#!/usr/bin/env python3
"""ombak_demo.py (2026-10-02 night, Jon: an "ombak"-type effect for Wall of Sound -- "map an audio file ... to a copy of itself, offset in
frequency by a certain amount ... when there is a bigger spike in activity, that will lead to faster ombak")

OMBAK = the beating of a paired gamelan instrument tuned a few Hz apart. Here: a stem mixed with a copy of itself FREQUENCY-SHIFTED by
df Hz (single-sideband: every partial moves up by the same df, unlike a pitch shift, which multiplies), so every partial beats at
exactly df per second. Shift = Re( analytic(x) * exp(i * 2 pi * integral df dt) ), analytic via the Hilbert transform -- the same thing
SuperCollider's FreqShift UGen does in real time.
  out/ombak_calibration.wav    one Wall of Sound dyad, df stepping 0.5 / 1 / 2 / 4 / 8 Hz, 6 s each (then the dry dyad, for reference)
  out/ombak_wall_data.wav      four dyads, each one's df driven by ITS dancer (sensors 1-4) over today's 12:56:00-12:58:00: activity
                               = AC RMS over 0.5 s / that sensor's 95th percentile in the run; df = 0.5 + 9.5 * act^2 (0.5 .. 10 Hz),
                               rising fast (0.12 s) and relaxing slowly (1.5 s) -- spikes = sudden fast ombak
  out/ombak_wall_data.png      df per dyad over the two minutes
"""
import os, glob, numpy as np, soundfile as sf, datetime as dt
from scipy.signal import hilbert, resample_poly
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)
SO = os.path.abspath(os.path.join(HERE, "..", "..", "..")); SR = 48000; FS = 50.0
STEMS = sorted(glob.glob(os.path.join(SO, "wall_of_sound", "stems", "*.wav")))

def load(f, secs):
    x, sr = sf.read(f, dtype="float64", always_2d=True); x = resample_poly(x, SR, sr, axis=0) if sr != SR else x
    n = int(secs * SR); reps = int(np.ceil(n / len(x))) + 1; xf = int(0.5 * SR)
    out = x.copy()
    for _ in range(reps - 1):                                       # loop with 0.5-s crossfades
        a = out[-xf:] * np.linspace(1, 0, xf)[:, None] + x[:xf] * np.linspace(0, 1, xf)[:, None]; out = np.vstack([out[:-xf], a, x[xf:]])
    return out[:n] / (np.sqrt((out[:n] ** 2).mean()) + 1e-9) * 0.05
def shift(x, df):                                                   # df: Hz per sample (array) -> frequency-shifted copy
    ph = 2 * np.pi * np.cumsum(df) / SR
    return np.stack([np.real(hilbert(x[:, c]) * np.exp(1j * ph)) for c in range(x.shape[1])], 1)
def lagud(v, up, down):
    bu, bd = np.exp(np.log(0.001) / (up * SR)), np.exp(np.log(0.001) / (down * SR)); y = np.empty_like(v); acc = v[0]
    for i, s in enumerate(v): b = bu if s > acc else bd; acc = b * acc + (1 - b) * s; y[i] = acc
    return y
def norm(y): return y * (10 ** (-1 / 20) / np.abs(y).max())

if __name__ == "__main__":
    # ---- 1. calibration: one dyad, 0.5 / 1 / 2 / 4 / 8 Hz ----
    steps = [0.5, 1, 2, 4, 8]; seg = 6.0; x = load(STEMS[4], seg * (len(steps) + 1))
    df = np.concatenate([np.full(int(seg * SR), f) for f in steps] + [np.zeros(int(seg * SR))])
    wet = shift(x, df); mix = 0.5 * (x + wet); mix[-int(seg * SR):] = x[-int(seg * SR):]   # last 6 s dry
    sf.write(os.path.join(OUT, "ombak_calibration.wav"), norm(mix).astype(np.float32), SR, subtype="PCM_24")
    print("calibration:", ", ".join(f"{f} Hz" for f in steps), "then dry,", seg, "s each")
    # ---- 2. data-driven: four dyads, one per sensor ----
    d = np.load(os.path.join(SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    idx = lambda h, m, s: int((dt.datetime(2026, 10, 2, h, m, s).timestamp() - t0) * FS)
    ac = np.clip(np.nan_to_num(X[:, 7:]), -1, 1)
    run = ac[idx(11, 47, 0):idx(13, 4, 0)]; win = ac[idx(12, 56, 0):idx(12, 58, 0)]; secs = len(win) / FS
    rms = lambda a: np.sqrt(np.convolve(a ** 2, np.ones(25) / 25, "same"))      # 0.5-s RMS
    p95 = [np.percentile(rms(run[:, k]), 95) for k in range(4)]
    t50 = np.arange(len(win)) / FS; ta = np.arange(int(secs * SR)) / SR
    layers, dfs = [], []
    for k, stem in enumerate([STEMS[i] for i in (2, 7, 12, 18)]):
        act = np.clip(rms(win[:, k]) / p95[k], 0, 1.5); target = np.clip(0.5 + 9.5 * act ** 2, 0.5, 10)
        dfk = lagud(np.interp(ta, t50, target), 0.12, 1.5); dfs.append(dfk)
        xk = load(stem, secs); pan = [-0.8, -0.3, 0.3, 0.8][k]
        y = 0.5 * (xk + shift(xk, dfk)); y = y.mean(1)
        layers.append(np.stack([y * np.sqrt((1 - pan) / 2), y * np.sqrt((1 + pan) / 2)], 1))
        print(f"dyad {os.path.basename(stem)} <- sensor {k + 1}: df median {np.median(dfk):.1f} Hz, max {dfk.max():.1f} Hz")
    out = sum(layers); sf.write(os.path.join(OUT, "ombak_wall_data.wav"), norm(out).astype(np.float32), SR, subtype="PCM_24")
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    fig, ax = plt.subplots(4, 1, figsize=(14, 7), sharex=True)
    for k in range(4):
        ax[k].plot(ta[::480], dfs[k][::480], lw=1); ax[k].set_ylabel(f"sensor {k + 1}\nHz"); ax[k].set_ylim(0, 10.5); ax[k].grid(alpha=.3)
    ax[-1].set_xlabel("seconds from 12:56:00 (ombak rate = beats per second, per dyad)"); plt.tight_layout(); plt.savefig(os.path.join(OUT, "ombak_wall_data.png"), dpi=70)
    print("wrote", OUT)
