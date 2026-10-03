#!/usr/bin/env python3
"""ombak_wall_combined.py (2026-10-02 night, Jon: "use it to make a combined harmonium and voice wall of sound instance")

A Wall of Sound instance of 2 min with the dancers' beating: 4 harmonium dyads (wall_of_sound/stems) + the 4 Aug 28 voices (their
usable segments from wall_of_sound/analysis/live_assets.json, chained with 0.3-s crossfades, 80 Hz high-pass as live), each element
mixed with an OFFSET COPY of itself whose offset follows one dancer over today's 12:56:00-12:58:00:
  dyads 1-4 <- sensors 1-4      voice 1 <- sensor 5   voice 2 <- sensor 6   voice 3 <- central (7)   voice 4 <- the ensemble (mean of 1-6)
Two versions of the offset, same activity curve:
  pitch  naive pitch shift (Rubber Band pitch map), 3 .. 50 cents: higher partials beat faster (chorus-like)
  freq   frequency shift (Hilbert / FreqShift), 0.5 .. 10 Hz: every partial beats at the same rate (ombak)
Voices sit 1 dB over the dyads (bell.py), everything spread across the stereo field.
  out/combined_{pitch,freq,dry}.wav  +  out/combined_page.json (offset curves every 0.1 s, envelopes)
"""
import os, json, subprocess, tempfile, numpy as np, soundfile as sf, datetime as dt
from scipy.signal import butter, sosfilt, resample_poly
import ombak_demo as om
SR, FS, OUT = om.SR, om.FS, om.OUT
WOS = os.path.join(om.SO, "wall_of_sound")

def voice(vid, secs, seed):
    a = json.load(open(os.path.join(WOS, "analysis", "live_assets.json")))["voices"][vid]; rng = np.random.default_rng(seed)
    x, sr = sf.read(a["file"], dtype="float64", always_2d=True); x = x.mean(1)
    segs = a["segments"]; order = list(rng.permutation(len(segs))); out = np.zeros(0); xf = int(0.3 * SR)
    while len(out) < secs * SR + SR:
        s0, s1 = segs[order[0]]; order = order[1:] + order[:1]
        y = resample_poly(x[int(s0 * sr):int(s1 * sr)], SR, sr) if sr != SR else x[int(s0 * sr):int(s1 * sr)]
        if len(out) == 0: out = y
        else: out = np.concatenate([out[:-xf], out[-xf:] * np.linspace(1, 0, xf) + y[:xf] * np.linspace(0, 1, xf), y[xf:]])
    out = sosfilt(butter(2, 80, "hp", fs=SR, output="sos"), out[:int(secs * SR)])
    return out / (np.sqrt((out ** 2).mean()) + 1e-9) * 0.05 * 10 ** (1 / 20)

def pitch_copy(x, cents):
    with tempfile.TemporaryDirectory() as tmp:
        fi, fo, fm = (os.path.join(tmp, n) for n in ("in.wav", "out.wav", "map.txt"))
        sf.write(fi, x.astype(np.float32), SR, subtype="FLOAT")
        with open(fm, "w") as f:
            for i in range(0, len(cents), 1024): f.write(f"{i} {cents[i] / 100:.5f}\n")
        subprocess.run(["rubberband", "-3", "-q", "--pitchmap", fm, fi, fo], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        y, _ = sf.read(fo, dtype="float64"); y = y[:len(x)]
        return np.concatenate([y, np.zeros(len(x) - len(y))]) if len(y) < len(x) else y

if __name__ == "__main__":
    d = np.load(os.path.join(om.SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    idx = lambda h, m, s: int((dt.datetime(2026, 10, 2, h, m, s).timestamp() - t0) * FS)
    ac = np.clip(np.nan_to_num(X[:, 7:]), -1, 1); run = ac[idx(11, 47, 0):idx(13, 4, 0)]; win = ac[idx(12, 56, 0):idx(12, 58, 0)]
    secs = len(win) / FS; rms = lambda a: np.sqrt(np.convolve(a ** 2, np.ones(25) / 25, "same"))
    drivers = [win[:, k] for k in range(7)]; run_d = [run[:, k] for k in range(7)]
    ens = lambda a: np.sqrt((a[:, :6] ** 2).mean(1)); drivers.append(ens(win)); run_d.append(ens(run))
    t50 = np.arange(len(win)) / FS; ta = np.arange(int(secs * SR)) / SR
    elements = [("dyad " + os.path.basename(om.STEMS[i]), lambda i=i: om.load(om.STEMS[i], secs).mean(1), k) for k, i in enumerate((2, 7, 12, 18))]
    elements += [(f"voice {v}", lambda v=v, j=j: voice(v, secs, 40 + j), drv) for j, (v, drv) in enumerate([("01", 4), ("02", 5), ("03", 6), ("04", 7)])]
    pans = [-0.9, -0.35, 0.25, 0.8, -0.6, 0.6, 0.0, -0.1]
    mixes = {"pitch": 0, "freq": 0, "dry": 0}; page = dict(dur=secs, clock0="12:56:00", hop=0.1, elements=[])
    drvname = ["sensor 1", "sensor 2", "sensor 3", "sensor 4", "sensor 5", "sensor 6", "central (7)", "ensemble"]
    for (name, get, drv), pan in zip(elements, pans):
        p95 = np.percentile(rms(run_d[drv]), 95); act = np.clip(rms(drivers[drv]) / p95, 0, 1.5)
        cents = om.lagud(np.interp(ta, t50, np.clip(3 + 47 * act ** 2, 3, 50)), 0.12, 1.5)
        hz = om.lagud(np.interp(ta, t50, np.clip(0.5 + 9.5 * act ** 2, 0.5, 10)), 0.12, 1.5)
        x = get(); ph = 2 * np.pi * np.cumsum(hz) / SR
        from scipy.signal import hilbert
        versions = {"pitch": 0.5 * (x + pitch_copy(x, cents)), "freq": 0.5 * (x + np.real(hilbert(x) * np.exp(1j * ph))), "dry": x}
        for kname, y in versions.items(): mixes[kname] = mixes[kname] + np.stack([y * np.sqrt((1 - pan) / 2), y * np.sqrt((1 + pan) / 2)], 1)
        h = int(0.1 * SR); m = len(ta) // h
        page["elements"].append(dict(name=name, driver=drvname[drv], cents=[round(float(v), 1) for v in cents[::h][:m]], hz=[round(float(v), 2) for v in hz[::h][:m]]))
        print(f"{name:14s} <- {drvname[drv]:12s} cents median {np.median(cents):4.0f}  Hz median {np.median(hz):4.1f}")
    g = 10 ** (-1 / 20) / max(np.abs(v).max() for v in mixes.values())
    def env(Y): h = int(0.1 * SR); m = len(Y) // h; return [round(float(v), 3) for v in np.abs(Y[:m * h]).max(1).reshape(m, h).max(1)]
    page["env"] = {}
    for kname, Y in mixes.items():
        sf.write(os.path.join(OUT, f"combined_{kname}.wav"), (Y * g).astype(np.float32), SR, subtype="PCM_24"); page["env"][kname] = env(Y * g)
    json.dump(page, open(os.path.join(OUT, "combined_page.json"), "w")); print("wrote combined_{pitch,freq,dry}.wav")
