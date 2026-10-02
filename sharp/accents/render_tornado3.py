#!/usr/bin/env python3
"""render_tornado3.py (2026-10-02 evening, Jon: "more like 3 minutes ... starting too slow ... even faster and faster at the very end"
+ "can we also add in some harmonium sounds") -- the 3-min additive tornado (tornado/forann_line/out_additive3, rendered by
forann_additive.py with FA_D=180 FA_IV0=1.5 FA_IV1=0.12 FA_CURVE=1.6 FA_SP1=0.33 FA_STAGES=0,0.12,0.25,0.38,0.5 FA_TAIL=0 FA_CUT=0.2)
+ the percussion accents (render_accents.py's rules, re-timed) + a HARMONIUM layer, all ending in one cut.

Driver: today's last 3 min before the unplug, 12:55:30-12:58:30. Re-timed accent layers (x = 0..1 over 3 min):
  klatter from 0 / thud from 0.15 / boom from 0.3 / kick heartbeat from 0.25, 1.5 s -> 0.12 s apart (piling into the end) /
  Articulation phrases from 0.15, one per ~25 s -> ~3 s / motion-scaled swarm 0.5 -> 15 per s
HARMONIUM (v7-harmonium-all: 24 stereo takes -- notes, a pentatonic chord, oscillations, build-ups -- and 33 chromatic notes F2-A4):
  swells   4-9 s excerpts of the chord / build-up takes, wide, from x 0.12, one per ~18 s -> ~3 s, getting louder
  ladder   short notes climbing the chromatic notes F2 -> A4 with the piece, from x 0.3, 1.2 s -> 0.15 s apart
  stabs    0.25-0.5 s chord cuts on the strongest jolts, from x 0.6
Out (out/): tornado3_* : ambiX, BINAURAL, QUAD (decoded, ch 1 FL 2 FR 3 BR 4 BL, wav) + harmonium-only and accents-only quads.
"""
import os, glob, re, numpy as np, soundfile as sf, datetime as dt
import render_accents as ra
HERE = ra.HERE; OUT = ra.OUT; SR, FS = ra.SR, ra.FS; D = 180.0
TORN = os.path.join(ra.SO, "tornado", "forann_line", "out_additive3", "forann_additive_ambiX.wav")
HARM = os.path.join(ra.SO, "concatenator-corpus", "corpus", "v7-harmonium-all")
# PROFILE (env T3_PROFILE): "flat" = the first 3-min render; "steep" (2026-10-02, Jon: "the temporal density of percussion stuff
# doesn't build up big enough ... stays a bit too flat") = jolts turn into rolls, the swarm and heartbeat pile into the end,
# phrases overlap, a steeper crescendo, and the percussion ends ABOVE the tornado
STEEP = os.environ.get("T3_PROFILE", "steep") == "steep"
rng = np.random.default_rng(23); EVENTS = []   # (time, layer) of every event, for the timeline page
NOTE = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}

def driver():
    d = np.load(os.path.join(ra.SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    idx = lambda h, m, s: int((dt.datetime(2026, 10, 2, h, m, s).timestamp() - t0) * FS)
    def fill(a):
        a = a.copy()
        for k in range(a.shape[1]):
            m = np.isfinite(a[:, k]); i = np.where(m, np.arange(len(a)), 0); np.maximum.accumulate(i, out=i); a[:, k] = a[i, k] if m.any() else 0
        return np.nan_to_num(a)
    run = fill(X[idx(11, 47, 0):idx(13, 4, 0), 7:]); seg = fill(X[idx(12, 55, 30):idx(12, 55, 30) + int(D * FS), 7:])
    thr = np.percentile(np.abs(np.diff(run, axis=0)), 99, 0)
    jolt = np.vstack([np.zeros((1, 7)), np.abs(np.diff(seg, axis=0))]) / np.maximum(thr, 1e-6)
    act = np.convolve(np.sqrt((seg[:, :6] ** 2).mean(1)), np.ones(int(2 * FS)) / (2 * FS), "same"); act = act / (np.percentile(act, 95) + 1e-9)
    hits = []
    for k in range(7):
        last = -1.0
        for i in np.where((jolt[1:, k] > 1) & (jolt[:-1, k] <= 1))[0] + 1:
            t = i / FS
            if t - last >= 0.12: hits.append((t, k, float(jolt[i, k]))); last = t
    return sorted(hits), act

def harm_sources():
    chords, notes = [], []
    for f in sorted(glob.glob(os.path.join(HARM, "*.wav"))):
        x, sr = sf.read(f, dtype="float32", always_2d=True)
        if x.shape[1] == 1: x = np.repeat(x, 2, 1)
        m = re.search(r"_([A-G][#b]?)(\d)\.wav$", f)
        if m: notes.append((12 * int(m.group(2)) + NOTE[m.group(1)], x))
        else: chords.append((os.path.basename(f), x))
    notes.sort(key=lambda p: p[0]); return chords, notes

def excerpt(x, L, fi, fo):
    if len(x) <= int(L * SR): y = x.copy()
    else: a = rng.integers(0, len(x) - int(L * SR)); y = x[a:a + int(L * SR)].copy()
    fi, fo = min(int(fi * SR), len(y) // 2), min(int(fo * SR), len(y) // 2)
    y[:fi] *= np.linspace(0, 1, fi)[:, None]; y[-fo:] *= np.linspace(1, 0, fo)[:, None]
    return y / (np.sqrt((y ** 2).mean()) + 1e-9) * 0.05

def render():
    cats = ra.load_bank(); hits, act = driver(); n = int(D * SR)
    A = np.zeros((n, 4), np.float32); H = np.zeros((n, 4), np.float32); cnt = {}
    def place(buf, y, t, az, gain, width=0.8):
        i = int(t * SR); m = min(len(y), n - i)
        if m > 0: buf[i:i + m] += ra.enc(y[:m] * gain, az, width)
    def place2(buf, y, t, az, gain, spread=0.52):
        i = int(t * SR); m = min(len(y), n - i)
        if m > 0:
            for c, off in ((0, spread), (1, -spread)): buf[i:i + m] += ra.enc(y[:m, c] * gain, az + off)
    pick = lambda names: (lambda pool: pool[rng.integers(len(pool))])([y for c in names for y in cats.get(c, [])])
    cres = (lambda x: 10 ** ((-22 + 22 * x ** 1.5) / 20)) if STEEP else (lambda x: 10 ** ((-10 + 10 * x) / 20))
    inc = lambda k, t: (cnt.__setitem__(k, cnt.get(k, 0) + 1), EVENTS.append((round(float(t), 3), k)))
    chords, notes = harm_sources()
    for t, k, st in hits:
        x = t / D; az = np.radians(k * 60 + rng.uniform(-15, 15)) if k < 6 else rng.uniform(0, 2 * np.pi); v = min(1.0, 0.45 + 0.25 * st)
        if rng.random() < ((0.15 + 0.85 * x) if STEEP else (0.4 + 0.6 * x)):
            reps = 1 + (rng.poisson(7 * x ** 2.2) if STEEP else 0)          # late jolts become flams and rolls
            for r in range(reps):
                tt = t + r * rng.uniform(0.018, 0.055); place(A, pick(["klatter_hi", "klatter_mid", "art_klatter", "boops"]), tt, az + rng.uniform(-0.2, 0.2), 0.5 * v * cres(x) * (0.85 ** r)); inc("klatter", tt)
        if x >= 0.15 and st > 1.3 and rng.random() < 0.6: place(A, pick(["thud", "art_thud", "fry"]), t + 0.004, az, 0.6 * v * cres(x)); inc("thud", t)
        if x >= 0.3 and (st > (1.4 if STEEP else 1.8) or k == 6) and rng.random() < 0.35 + 0.65 * x: place(A, pick(["art_boom", "art_boom", "kick"]), t, az, 0.8 * v * cres(x), 0.3); inc("boom", t)
        if x >= 0.6 and st > 2.2 and rng.random() < 0.5:
            nm, cx = chords[rng.integers(len(chords))]; place2(H, excerpt(cx, rng.uniform(0.25, 0.5), 0.004, 0.08), t, az, 1.1 * cres(x)); inc("h_stab", t)
    t = 0.25 * D                                                        # kick heartbeat, accelerating hardest at the end
    while t < D - 0.2:
        x = t / D; place(A, pick(["kick", "art_boom"]), t, rng.uniform(0, 2 * np.pi), 0.7 * cres(x), 0.2); inc("pulse", t)
        y = (x - 0.25) / 0.75; t += 1.5 * ((0.07 if STEEP else 0.12) / 1.5) ** (y ** 1.6) * rng.uniform(0.92, 1.08)
    t = 0.15 * D                                                        # Articulation phrases
    while t < D - 1.5:
        x = t / D; ph = cats["art_phrase"][rng.integers(len(cats["art_phrase"]))]; place2(A, ph, t, rng.uniform(0, 2 * np.pi), 0.45 * cres(x)); inc("phrase", t)
        t += (30 * ((1.1 / 30) ** (((x - 0.15) / 0.85) ** 1.3)) if STEEP else 25 * (0.12 ** ((x - 0.15) / 0.85))) * rng.uniform(0.7, 1.3)
    t = 0.0                                                             # motion-scaled klatter swarm
    while t < D - 0.3:
        x = t / D; a = act[min(int(t * FS), len(act) - 1)]
        if rng.random() < min(1.0, 0.35 + a): place(A, pick(["klatter_hi", "klatter_mid", "boops", "art_klatter"]), t, rng.uniform(0, 2 * np.pi), 0.3 * cres(x)); inc("swarm", t)
        t += rng.exponential(1.0 / ((0.2 * 200 ** (x ** 1.7)) if STEEP else (0.5 * 30 ** (x ** 1.3))))
    t = 0.12 * D                                                        # harmonium chord swells
    while t < D - 2:
        x = t / D; nm, cx = chords[rng.integers(len(chords))]; L = rng.uniform(4, 9) * (1 - 0.5 * x)
        place2(H, excerpt(cx, L, 1.2 * (1 - 0.6 * x), 1.8 * (1 - 0.6 * x)), t, rng.uniform(0, 2 * np.pi), 0.8 * cres(x), 0.7); inc("h_swell", t)
        t += 18 * ((3 / 18) ** ((x - 0.12) / 0.88)) * rng.uniform(0.7, 1.3)
    t = 0.3 * D                                                         # harmonium ladder: climbing the chromatic notes
    while t < D - 0.3:
        x = t / D; y = (x - 0.3) / 0.7; i = min(len(notes) - 1, int(y * len(notes) + rng.integers(-2, 3)))
        i = max(0, i); place2(H, excerpt(notes[i][1], rng.uniform(0.35, 1.2) * (1 - 0.6 * y), 0.01, 0.15), t, rng.uniform(0, 2 * np.pi), 0.6 * cres(x), 0.4); inc("h_ladder", t)
        t += 1.2 * (0.15 / 1.2) ** (y ** 1.3) * rng.uniform(0.85, 1.15)
    f = np.ones(n, np.float32); m = int(0.2 * SR); f[-m:] = np.linspace(1, 0, m); A *= f[:, None]; H *= f[:, None]   # the cut
    print("events:", cnt, "| motion hits:", len(hits)); return A, H

if __name__ == "__main__":
    A, H = render(); n = len(A)
    T, sr = sf.read(TORN, dtype="float32"); T = T[:n]; Tb = np.stack([T[:, 0] / np.sqrt(2), T[:, 3], T[:, 1], T[:, 2]], 1)
    rms = lambda Y: np.sqrt((Y[-int(40 * SR):, 0] ** 2).mean()) + 1e-9
    if STEEP: A *= (np.sqrt((Tb[-int(20 * SR):, 0] ** 2).mean()) / (np.sqrt((A[-int(20 * SR):, 0] ** 2).mean()) + 1e-9)) * 10 ** (1 / 20)   # last 20 s: percussion 1 dB OVER the tornado
    else: A *= rms(Tb) / rms(A) * 10 ** (-2 / 20)                                                                                      # last 40 s: 2 dB under
    H *= rms(Tb) / rms(H) * 10 ** (-5 / 20)
    tag = "tornado3b" if STEEP else "tornado3"
    ra.decode_write(Tb + A + H, f"{tag}_full", n); ra.decode_write(H, f"{tag}_harmonium_only", n); ra.decode_write(A, f"{tag}_accents_only", n)
    lv = lambda Y: [round(float(20 * np.log10(np.sqrt((Y[i * SR * 30:(i + 1) * SR * 30, 0] ** 2).mean()) + 1e-9)), 1) for i in range(6)]
    print("full mix dB per 30 s:", lv(Tb + A + H))
