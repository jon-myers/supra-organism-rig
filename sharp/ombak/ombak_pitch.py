#!/usr/bin/env python3
"""ombak_pitch.py (2026-10-02 night, Jon: "can I hear what it's like just shifted a bit ... the naive way, of actually pitch shift,
rather than freq offset", with a graph of the offset at each frame)

The same four Wall of Sound dyads and the same dancers (sensors 1-4, today 12:56:00-12:58:00) as ombak_demo.py, but the copy is
PITCH-shifted (Rubber Band R3 with a pitch map: timing kept, every frequency MULTIPLIED by 2^(cents/1200)). A partial at f then beats
at f * (2^(c/1200) - 1): higher partials beat faster than lower ones -- a chorus-like shimmer rather than the even ombak beat.
  cents = 3 + 47 * act^2 (3 .. 50 cents), rising fast (0.12 s), relaxing slowly (1.5 s); act as in ombak_demo.py
  out/pitch_wall_data.wav   the four dyads + their pitch-shifted copies           out/dry_wall.wav   the four dyads alone
  out/page_data.json        per-dyad offsets (cents, and the ombak version's Hz) every 0.1 s, waveform envelopes, for the page
"""
import os, json, subprocess, tempfile, numpy as np, soundfile as sf, datetime as dt
import ombak_demo as om
SR, FS, OUT = om.SR, om.FS, om.OUT

if __name__ == "__main__":
    d = np.load(os.path.join(om.SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    idx = lambda h, m, s: int((dt.datetime(2026, 10, 2, h, m, s).timestamp() - t0) * FS)
    ac = np.clip(np.nan_to_num(X[:, 7:]), -1, 1); run = ac[idx(11, 47, 0):idx(13, 4, 0)]; win = ac[idx(12, 56, 0):idx(12, 58, 0)]
    secs = len(win) / FS; rms = lambda a: np.sqrt(np.convolve(a ** 2, np.ones(25) / 25, "same"))
    p95 = [np.percentile(rms(run[:, k]), 95) for k in range(4)]; t50 = np.arange(len(win)) / FS; ta = np.arange(int(secs * SR)) / SR
    pitch, dry, freq = [], [], []; page = dict(dur=secs, clock0="12:56:00", hop=0.1, dyads=[])
    for k, stem in enumerate([om.STEMS[i] for i in (2, 7, 12, 18)]):
        act = np.clip(rms(win[:, k]) / p95[k], 0, 1.5)
        cents = om.lagud(np.interp(ta, t50, np.clip(3 + 47 * act ** 2, 3, 50)), 0.12, 1.5)
        hz = om.lagud(np.interp(ta, t50, np.clip(0.5 + 9.5 * act ** 2, 0.5, 10)), 0.12, 1.5)
        xk = om.load(stem, secs); pan = [-0.8, -0.3, 0.3, 0.8][k]
        with tempfile.TemporaryDirectory() as tmp:
            fi, fo, fm = os.path.join(tmp, "in.wav"), os.path.join(tmp, "out.wav"), os.path.join(tmp, "map.txt")
            sf.write(fi, xk.astype(np.float32), SR, subtype="FLOAT")
            with open(fm, "w") as f:
                for i in range(0, len(cents), 1024): f.write(f"{i} {cents[i] / 100:.5f}\n")
            subprocess.run(["rubberband", "-3", "-q", "--pitchmap", fm, fi, fo], check=True)
            ys, _ = sf.read(fo, dtype="float64", always_2d=True); ys = ys[:len(xk)]
            if len(ys) < len(xk): ys = np.vstack([ys, np.zeros((len(xk) - len(ys), ys.shape[1]))])
        place = lambda y: np.stack([y * np.sqrt((1 - pan) / 2), y * np.sqrt((1 + pan) / 2)], 1)
        pitch.append(place((0.5 * (xk + ys)).mean(1))); dry.append(place(xk.mean(1)))
        h = int(0.1 * SR); m = len(cents) // h
        page["dyads"].append(dict(name=os.path.basename(stem), sensor=k + 1, cents=[round(float(v), 1) for v in cents[::h][:m]], hz=[round(float(v), 2) for v in hz[::h][:m]]))
        print(f"dyad {os.path.basename(stem)} <- sensor {k + 1}: cents median {np.median(cents):.0f}, max {cents.max():.0f}")
    P, Dr = sum(pitch), sum(dry); g = 10 ** (-1 / 20) / max(np.abs(P).max(), np.abs(Dr).max())
    sf.write(os.path.join(OUT, "pitch_wall_data.wav"), (P * g).astype(np.float32), SR, subtype="PCM_24"); sf.write(os.path.join(OUT, "dry_wall.wav"), (Dr * g).astype(np.float32), SR, subtype="PCM_24")
    F, _ = sf.read(os.path.join(OUT, "ombak_wall_data.wav"), dtype="float64")
    def env(Y): h = int(0.1 * SR); m = len(Y) // h; return [round(float(v), 3) for v in np.abs(Y[:m * h]).max(1).reshape(m, h).max(1)]
    page["env"] = dict(pitch=env(P * g), freq=env(F), dry=env(Dr * g))
    json.dump(page, open(os.path.join(OUT, "page_data.json"), "w")); print("wrote pitch_wall_data.wav, dry_wall.wav, page_data.json")
