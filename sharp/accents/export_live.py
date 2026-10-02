#!/usr/bin/env python3
"""export_live.py (2026-10-02) -- the material and the constants for the LIVE tornado (rig/dev/tornado_engine.scd), from the same
sources and balance as the 3c render (render_tornado4.py):
  live/lines/<material>/x<speed>/NN.wav   the For Ann line renders, pitch-preserving speed versions 1.0 / 0.64 / 0.4 / 0.33 (from
                                          tornado/forann_line/additive_cache), RMS 0.05 like the render
  live/harm_notes/NN.wav                  ladder notes, semitones above F2 (0..56 = F2..A6), 1.5 s, stereo
  live/harm_swell/NNN.wav                 60 swell excerpts (4-9 s, stereo, fades baked in) -- first 30 from the original chords,
                                          the rest from the higher (+7 / +12 / +19) versions
  live/harm_cluster/NN.wav                24 high (+19) chord excerpts, 3-6 s, for the climax cluster
  live/harm_stab/NN.wav                   40 short chord cuts (0.25-0.5 s), half original, half high
  live/snatch/NN.wav                      10-s whole snatches (Rite openings, Rite middles, Phantom Pain reconstruct), fades baked in
  (hits, phrases and birds are read straight from bank/)
  live/live.json                          file lists per category + the gains that reproduce the render's balance + the per-sensor
                                          jolt thresholds and the activity scale from today's run
"""
import os, glob, json, re, shutil, numpy as np, soundfile as sf
import render_accents as ra, render_tornado3 as r3, render_tornado4 as r4
HERE = ra.HERE; LIVE = os.path.join(HERE, "live"); SR = ra.SR; rng = np.random.default_rng(99)
CACHE = os.path.join(ra.SO, "tornado", "forann_line", "additive_cache"); SPEEDS = [1.0, 0.64, 0.4, 0.33]; LINE_S = 43.7
MATS = ["voice", "breath", "fry", "harmonium", "mixed"]
def w(path, y): os.makedirs(os.path.dirname(path), exist_ok=True); sf.write(path, y.astype(np.float32), SR, subtype="FLOAT"); return os.path.relpath(path, HERE)
def fades(y, fi, fo):
    y = y.copy(); fi, fo = min(int(fi * SR), len(y) // 2), min(int(fo * SR), len(y) // 2)
    sh = (slice(None),) + ((None,) if y.ndim > 1 else ())
    y[:fi] *= np.linspace(0, 1, fi)[sh]; y[-fo:] *= np.linspace(1, 0, fo)[sh]; return y

if __name__ == "__main__":
    if os.path.isdir(LIVE): shutil.rmtree(LIVE)
    man = {"lines": {}, "speeds": SPEEDS}
    for m in MATS:                                     # lines, exactly as forann_additive.load() prepares them
        man["lines"][m] = {}
        for sp in SPEEDS:
            lst = []
            for k, f in enumerate(sorted(glob.glob(os.path.join(CACHE, m, f"*__x{sp}.wav")))):
                y, _ = sf.read(f, dtype="float32"); y = y.mean(1) if y.ndim > 1 else y; y = y[:int(LINE_S * sp * SR)]
                y = y / (np.sqrt((y ** 2).mean()) + 1e-12) * 0.05; y = fades(y, 0.5 * sp, 0.5 * sp)
                lst.append(w(os.path.join(LIVE, "lines", m, f"x{sp}", f"{k:02d}.wav"), y))
            man["lines"][m][str(sp)] = lst
    chords, notes0 = r3.harm_sources(); hi_notes, hi_chords = r4.harm_hi()
    ladder = sorted([(p - 41, y) for p, y in notes0] + hi_notes, key=lambda q: q[0]); man["harm_notes"] = []
    for p, y in ladder: man["harm_notes"].append([int(p), w(os.path.join(LIVE, "harm_notes", f"{p:02d}_{len(man['harm_notes'])}.wav"), fades(y[:int(1.5 * SR)], 0.01, 0.15))])
    ex = lambda x, L: (lambda a: x[a:a + int(L * SR)])(rng.integers(0, max(1, len(x) - int(L * SR))))
    norm = lambda y: y / (np.sqrt((y ** 2).mean()) + 1e-9) * 0.05
    man["harm_swell"] = [w(os.path.join(LIVE, "harm_swell", f"{i:03d}.wav"), norm(fades(ex((chords[rng.integers(len(chords))][1] if i < 30 else hi_chords[rng.integers(len(hi_chords))][1]), rng.uniform(4, 9)), 1.0, 1.6))) for i in range(60)]
    hi19 = [c for s, c in hi_chords if s == 19]
    man["harm_cluster"] = [w(os.path.join(LIVE, "harm_cluster", f"{i:02d}.wav"), norm(fades(ex(hi19[rng.integers(len(hi19))], rng.uniform(3, 6)), 1.0, 1.5))) for i in range(24)]
    man["harm_stab"] = [w(os.path.join(LIVE, "harm_stab", f"{i:02d}.wav"), norm(fades(ex((chords[rng.integers(len(chords))][1] if i < 20 else hi_chords[rng.integers(len(hi_chords))][1]), rng.uniform(0.25, 0.5)), 0.004, 0.08))) for i in range(40)]
    sn = []
    for i, (f, a) in enumerate([(f, 0.0) for f in r4.RITE[:: max(1, len(r4.RITE) // 6)][:6]] + [(r4.RITE[3], 40.0), (r4.RITE[9], 70.0)] + [(r4.PPR, a) for a in (30.0, 95.0, 160.0, 230.0)]):
        info = sf.info(f); y, sr = sf.read(f, dtype="float32", always_2d=True, start=int(a * info.samplerate), frames=int(10 * info.samplerate))
        if sr != SR:
            import librosa; y = librosa.resample(y.T, orig_sr=sr, target_sr=SR).T
        y = np.repeat(y, 2, 1) if y.shape[1] == 1 else y[:, :2]
        sn.append([("pp" if f == r4.PPR else ("rite_open" if a == 0 else "rite_mid")), w(os.path.join(LIVE, "snatch", f"{i:02d}.wav"), norm(fades(y, 1.5, 2.0)))])
    man["snatch"] = sn
    bank = json.load(open(os.path.join(ra.BANK, "bank.json"))); man["hits"] = {}
    for e in bank: man["hits"].setdefault(e["cat"], []).append(os.path.relpath(os.path.join(ra.BANK, e["file"]), HERE))
    man["birds"] = [os.path.relpath(os.path.join(ra.BANK, e["file"]), HERE) for e in json.load(open(os.path.join(ra.BANK, "bio", "bio.json")))]
    # ---- the render's balance, as absolute gains: the tornado file was peak-normalised (g_t); the layers were scaled against it ----
    import importlib, sys
    os.environ.update(FA_D="180", FA_HOLD="20", FA_IV0="1.5", FA_IV1="0.12", FA_CURVE="1.6", FA_SP1="0.33", FA_STAGES="0,0.12,0.25,0.38,0.5", FA_TAIL="0", FA_CUT="0.2", FA_OUT="out_additive3hold")
    sys.path.insert(0, os.path.join(ra.SO, "tornado")); fa = importlib.import_module("forann_additive")
    stems = fa.render(fa.load()); Bt = sum(stems.values())
    amb = np.stack([Bt[:, 0] * np.sqrt(2), Bt[:, 2], Bt[:, 3], Bt[:, 1]], 1); g_t = float(10 ** (-1 / 20) / np.abs(amb).max())
    Tb, A, H, B, Rt = r4.mixes(); A0, H0, B0, Rt0 = r4.render()       # same seeds -> the unscaled layers
    sc = lambda Y, Y0: float(np.sqrt((Y[:, 0] ** 2).mean()) / (np.sqrt((Y0[:, 0] ** 2).mean()) + 1e-12))
    man["gains"] = dict(lines=g_t, perc=sc(A, A0), harm=sc(H, H0), birds=sc(B, B0), snatch_db_under_lines=-10.0)
    # ---- sensor constants from today's run (11:47-13:04), as the live bus sees them (AC clipped +-1) ----
    d = np.load(os.path.join(ra.SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    import datetime as dt
    i0 = int((dt.datetime(2026, 10, 2, 11, 47).timestamp() - t0) * 50); i1 = int((dt.datetime(2026, 10, 2, 13, 4).timestamp() - t0) * 50)
    ac = np.clip(np.nan_to_num(X[i0:i1, 7:]), -1, 1)
    man["jolt_thr"] = [round(float(v), 4) for v in np.percentile(np.abs(np.diff(ac, axis=0)), 99, 0)]
    act = np.convolve(np.sqrt((ac[:, :6] ** 2).mean(1)), np.ones(100) / 100, "same"); man["act95"] = round(float(np.percentile(act, 95)), 4)
    json.dump(man, open(os.path.join(LIVE, "live.json"), "w"), indent=0)
    tot = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(LIVE) for f in fs)
    print("gains", man["gains"], "| jolt_thr", man["jolt_thr"], "act95", man["act95"], f"| live bank {tot / 1e6:.0f} MB")
