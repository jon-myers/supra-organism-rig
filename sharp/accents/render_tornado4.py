#!/usr/bin/env python3
"""render_tornado4.py (2026-10-02 evening) -- tornado "3c": the steep 3-min build (render_tornado3.py, profile steep) plus
Jon's next notes: "many harmonium pitches increasingly more as it goes on" / "that bioacoustic library ... randomly start to pull
in some of those sounds as the recording goes on" / "the very ending needs to be higher, certainly higher pitched harmonium" /
"it should climax at the end and pause, so I can then bring it down".

  HARMONIUM  ladder -> CHORDS: 1 note at first, stacks of up to 6 near the end, climbing from F2 through the original notes
             (to A4) and on through their +12 / +24 versions to A6 (bank/harm_hi, Rubber Band); swells switch to the higher
             chord versions (+7 / +12 / +19) as it goes; a CLIMAX CLUSTER of high chords (+19) piles up over the last 18 s
  RITE       10-s snatches of the Rite renders, mostly their openings, whole (see RITE below)
  BIRDS      Macaulay Library calls (bank/bio), from 0:18, one per ~20 s at first -> ~3 per s at the climax, anywhere in the circle
  CLIMAX + HOLD  the build peaks at 3:00, then HOLDS at full intensity for HOLD s (env T3_HOLD, default 20): the tornado lines keep
             running at their fastest (tornado/forann_line/out_additive3hold), the dancers' driver loops the peak of their frenzy
             (12:57:40-12:58:00), everything else stays at its climax rate -- room to fade it down by hand; then the cut.
             T3_HOLD=0: cut right at the climax.
Out (out/): tornado3c_* (hold) or tornado3c_cut_* : full / harmonium_only / accents_only / birds_only; ambiX, BINAURAL, decoded QUAD.
"""
import os, glob, re, numpy as np, soundfile as sf, json
import render_accents as ra, render_tornado3 as r3
SR, FS, D = ra.SR, ra.FS, 180.0; HOLD = float(os.environ.get("T3_HOLD", 20)); TOT = D + HOLD
TORN = os.path.join(ra.SO, "tornado", "forann_line", "out_additive3hold" if HOLD > 0 else "out_additive3", "forann_additive_ambiX.wav")
BANK = ra.BANK; rng = np.random.default_rng(31); EVENTS = []; SNATCH = []   # snatches: (start, stereo audio, azimuth), levelled in mixes()
# RITE SNATCHES (2026-10-02, Jon: "different snatches of these renderings of rite of spring ... especially the first 10 seconds ...
# play that ten seconds in full, don't chop it up"): 10-s stretches of the Rite renders (1x and octave down), 70 % of them the
# OPENING 10 s, each whole, with a 1.5-s fade in and a 2-s fade out, as a stereo pair somewhere in the circle; one per ~30 s from
# 0:18, one per ~6 s by the climax (they may overlap there)
RITE = sorted(glob.glob(os.path.join(ra.SO, "concatenator-corpus", "out", "listen-rite1929", "*__norm.wav")) +
              [f for f in glob.glob(os.path.join(ra.SO, "concatenator-corpus", "out", "listen-rite1929half", "*__norm.wav")) if not os.path.basename(f).startswith(("STEMS", "PREVIEW"))])
# ... and snatches of the LatentFT "reconstruct" Phantom Pain (Jon, same evening). Jon: "doesn't need to be super obvious, just a few
# times throughout": ~6-7 snatches in all, alternating Rite / Phantom Pain, never overlapping, 10 dB under the tornado
PPR = os.path.join(ra.SO, "song_deconstruct", "out", "latentft", "LISTEN_run10_FULLSONG_pieces", "phantom_pain_reconstruct_fullsong.wav")

def driver():
    hits, act = r3.driver()                                            # 12:55:30 + 180 s
    if HOLD > 0:                                                        # the hold: loop the peak of the frenzy, 12:57:40-12:58:00
        a0, a1 = 130.0, 150.0; base = [(t, k, s) for t, k, s in hits if a0 <= t < a1]; t0 = D
        while t0 < TOT:
            hits += [(t0 + (t - a0), k, s) for t, k, s in base if t0 + (t - a0) < TOT]; t0 += a1 - a0
        seg = act[int(a0 * FS):int(a1 * FS)]; act = np.concatenate([act, np.tile(seg, int(np.ceil(HOLD / (a1 - a0))))[: int(HOLD * FS)]])
    return sorted(hits), act

def harm_hi():
    notes, chords = [], []
    for f in sorted(glob.glob(os.path.join(BANK, "harm_hi", "*.wav"))):
        y, _ = sf.read(f, dtype="float32", always_2d=True); y = np.repeat(y, 2, 1) if y.shape[1] == 1 else y
        tag = os.path.basename(f).split("__")[0]; sh = int(re.search(r"__p(\d+)\.wav$", f).group(1))
        (chords if tag == "chord" else notes).append((sh if tag == "chord" else int(tag), y))
    return notes, chords

def render():
    SNATCH.clear(); cats = ra.load_bank(); hits, act = driver(); n = int(TOT * SR)
    A = np.zeros((n, 4), np.float32); H = np.zeros((n, 4), np.float32); B = np.zeros((n, 4), np.float32); Rt = np.zeros((n, 4), np.float32); cnt = {}
    X = lambda t: min(1.0, t / D)
    def place(buf, y, t, az, gain, width=0.8):
        i = int(t * SR); m = min(len(y), n - i)
        if m > 0: buf[i:i + m] += ra.enc(y[:m] * gain, az, width)
    def place2(buf, y, t, az, gain, spread=0.52):
        i = int(t * SR); m = min(len(y), n - i)
        if m > 0:
            for c, off in ((0, spread), (1, -spread)): buf[i:i + m] += ra.enc(y[:m, c] * gain, az + off)
    pick = lambda names: (lambda pool: pool[rng.integers(len(pool))])([y for c in names for y in cats.get(c, [])])
    cres = lambda x: 10 ** ((-22 + 22 * x ** 1.5) / 20)
    inc = lambda k, t: (cnt.__setitem__(k, cnt.get(k, 0) + 1), EVENTS.append((round(float(t), 3), k)))
    chords, notes0 = r3.harm_sources(); hi_notes, hi_chords = harm_hi()
    ladder = [(p - 41, y) for p, y in notes0] + hi_notes; ladder.sort(key=lambda q: q[0]); top = ladder[-1][0]   # semitones above F2
    bio = [sf.read(os.path.join(BANK, e["file"]), dtype="float32")[0] for e in json.load(open(os.path.join(BANK, "bio", "bio.json")))]
    ex = lambda x, L, fi, fo: r3.excerpt(x, L, fi, fo)
    # ---- percussion (the steep rules) ----
    for t, k, st in hits:
        x = X(t); az = np.radians(k * 60 + rng.uniform(-15, 15)) if k < 6 else rng.uniform(0, 2 * np.pi); v = min(1.0, 0.45 + 0.25 * st)
        if rng.random() < 0.15 + 0.85 * x:
            for r in range(1 + rng.poisson(7 * x ** 2.2)):
                tt = t + r * rng.uniform(0.018, 0.055); place(A, pick(["klatter_hi", "klatter_mid", "art_klatter", "boops"]), tt, az + rng.uniform(-0.2, 0.2), 0.5 * v * cres(x) * 0.85 ** r); inc("klatter", tt)
        if x >= 0.15 and st > 1.3 and rng.random() < 0.6: place(A, pick(["thud", "art_thud", "fry"]), t + 0.004, az, 0.6 * v * cres(x)); inc("thud", t)
        if x >= 0.3 and (st > 1.4 or k == 6) and rng.random() < 0.35 + 0.65 * x: place(A, pick(["art_boom", "art_boom", "kick"]), t, az, 0.8 * v * cres(x), 0.3); inc("boom", t)
        if x >= 0.6 and st > 2.2 and rng.random() < 0.5:
            pool = hi_chords if rng.random() < x else [(0, c) for _, c in chords]
            place2(H, ex(pool[rng.integers(len(pool))][1], rng.uniform(0.25, 0.5), 0.004, 0.08), t, az, 1.1 * cres(x)); inc("h_stab", t)
    t = 0.25 * D
    while t < TOT - 0.2:
        x = X(t); place(A, pick(["kick", "art_boom"]), t, rng.uniform(0, 2 * np.pi), 0.7 * cres(x), 0.2); inc("pulse", t)
        y = max(0.0, (x - 0.25) / 0.75); t += 1.5 * (0.07 / 1.5) ** (y ** 1.6) * rng.uniform(0.92, 1.08)
    t = 0.15 * D
    while t < TOT - 1.5:
        x = X(t); place2(A, cats["art_phrase"][rng.integers(len(cats["art_phrase"]))], t, rng.uniform(0, 2 * np.pi), 0.45 * cres(x)); inc("phrase", t)
        t += 30 * ((1.1 / 30) ** (max(0.0, (x - 0.15) / 0.85) ** 1.3)) * rng.uniform(0.7, 1.3)
    t = 0.0
    while t < TOT - 0.3:
        x = X(t); a = act[min(int(t * FS), len(act) - 1)]
        if rng.random() < min(1.0, 0.35 + a): place(A, pick(["klatter_hi", "klatter_mid", "boops", "art_klatter"]), t, rng.uniform(0, 2 * np.pi), 0.3 * cres(x)); inc("swarm", t)
        t += rng.exponential(1.0 / (0.2 * 200 ** (x ** 1.7)))
    # ---- harmonium: swells getting higher, a ladder of growing chords to A6, a climax cluster ----
    t = 0.12 * D
    while t < TOT - 2:
        x = X(t); hi = rng.random() < max(0.0, (x - 0.45) / 0.55)
        src = hi_chords[rng.integers(len(hi_chords))][1] if hi else chords[rng.integers(len(chords))][1]
        L = rng.uniform(4, 9) * (1 - 0.5 * x); place2(H, ex(src, L, 1.2 * (1 - 0.6 * x), 1.8 * (1 - 0.6 * x)), t, rng.uniform(0, 2 * np.pi), 0.8 * cres(x), 0.7); inc("h_swell", t)
        t += 18 * ((2 / 18) ** (max(0.0, (x - 0.12) / 0.88) ** 1.2)) * rng.uniform(0.7, 1.3)
    t = 0.3 * D
    while t < TOT - 0.3:
        x = X(t); y = max(0.0, (x - 0.3) / 0.7); target = top * y ** 1.15; size = 1 + int(5 * y ** 1.4 + rng.random())
        cand = [q for q in ladder if target - 9 <= q[0] <= target + 1] or [min(ladder, key=lambda q: abs(q[0] - target))]
        L = rng.uniform(0.35, 1.2) * (1 - 0.6 * y)
        for j in range(min(size, 6)):
            p, yy = cand[rng.integers(len(cand))]; place2(H, ex(yy, L, 0.01, 0.15), t + j * rng.uniform(0, 0.02), rng.uniform(0, 2 * np.pi), 0.6 * cres(x) / np.sqrt(size), 0.4)
        inc("h_ladder", t); t += 1.2 * (0.15 / 1.2) ** (y ** 1.3) * rng.uniform(0.85, 1.15)
    t = D - 18
    hi19 = [c for s, c in hi_chords if s == 19] or [c for _, c in hi_chords]
    while t < TOT - 1:                                                  # climax cluster: high chords piling up
        x = X(t); place2(H, ex(hi19[rng.integers(len(hi19))], rng.uniform(3, 6), 1.0, 1.5), t, rng.uniform(0, 2 * np.pi), 0.9 * cres(x), 0.8); inc("h_cluster", t)
        t += max(0.6, 2.5 * (1 - (t - (D - 18)) / 18)) if t < D else 0.6
    # ---- birds: more and more often ----
    t = 0.1 * D
    while t < TOT - 0.5:
        x = X(t); place(B, bio[rng.integers(len(bio))], t, rng.uniform(0, 2 * np.pi), 0.5 * cres(x)); inc("bird", t)
        t += rng.exponential(1.0 / (0.05 * 60 ** (max(0.0, (x - 0.1) / 0.9) ** 1.4)))
    # ---- Rite of Spring snatches, whole 10-s stretches ----
    t = 0.1 * D + rng.uniform(0, 8); j = 0
    while t < TOT - 6:
        x = X(t); pp = (j % 2 == 1) and os.path.exists(PPR); f = PPR if pp else RITE[rng.integers(len(RITE))]; info = sf.info(f); L = 10.0
        a = rng.uniform(0, info.duration - L) if pp else (0.0 if rng.random() < 0.75 else rng.uniform(10, max(10.0, info.duration - L)))
        y, _ = sf.read(f, dtype="float32", always_2d=True, start=int(a * info.samplerate), frames=int(L * info.samplerate))
        y = np.repeat(y, 2, 1) if y.shape[1] == 1 else y[:, :2]
        fi, fo = int(1.5 * SR), int(2.0 * SR); y[:fi] *= np.linspace(0, 1, fi)[:, None]; y[-fo:] *= np.linspace(1, 0, fo)[:, None]
        y = y / (np.sqrt((y ** 2).mean()) + 1e-9) * 0.05
        SNATCH.append((t, y, rng.uniform(0, 2 * np.pi))); inc("pp_reconstruct" if pp else ("rite_open" if a == 0 else "rite_mid"), t); j += 1
        t += L + rng.uniform(14, 24)                                    # never overlapping: 24-34 s from start to start
    f = np.ones(n, np.float32); m = int(0.2 * SR); f[-m:] = np.linspace(1, 0, m)
    for Y in (A, H, B, Rt): Y *= f[:, None]
    print("events:", cnt, "| motion hits:", len(hits)); return A, H, B, Rt

def mixes():
    A, H, B, Rt = render(); n = len(A)
    T, _ = sf.read(TORN, dtype="float32"); T = T[:n]; Tb = np.stack([T[:, 0] / np.sqrt(2), T[:, 3], T[:, 1], T[:, 2]], 1)
    w = slice(int((D - 20) * SR), int(D * SR)); r = lambda Y: np.sqrt((Y[w, 0] ** 2).mean()) + 1e-9   # the 20 s before the climax
    A *= r(Tb) / r(A) * 10 ** (1 / 20); H *= r(Tb) / r(H) * 10 ** (-3 / 20); B *= r(Tb) / r(B) * 10 ** (-8 / 20); Rt[:] = 0
    for t, y, az in SNATCH:   # each snatch 10 dB under the tornado AT THE TIME IT PLAYS (not under its average: the start is quiet)
        i = int(t * SR); m = min(len(y), n - i); e = sum(ra.enc(y[:m, c], az + off) for c, off in ((0, 0.6), (1, -0.6)))
        loc = np.sqrt((Tb[i:i + m, 0] ** 2).mean()) + 1e-9; Rt[i:i + m] += e * (loc / (np.sqrt((e[:, 0] ** 2).mean()) + 1e-9)) * 10 ** (-10 / 20)
    Rt *= np.concatenate([np.ones(n - int(0.2 * SR)), np.linspace(1, 0, int(0.2 * SR))]).astype(np.float32)[:, None]
    return Tb, A, H, B, Rt

if __name__ == "__main__":
    Tb, A, H, B, Rt = mixes(); n = len(A); tag = "tornado3c" if HOLD > 0 else "tornado3c_cut"
    ra.decode_write(Tb + A + H + B + Rt, f"{tag}_full", n)
    for nm, Y in (("harmonium_only", H), ("accents_only", A), ("birds_only", B), ("rite_only", Rt)): ra.decode_write(Y, f"{tag}_{nm}", n)
    lv = lambda Y: [round(float(20 * np.log10(np.sqrt((Y[i * SR * 20:(i + 1) * SR * 20, 0] ** 2).mean()) + 1e-9)), 1) for i in range(int(TOT // 20))]
    print("full mix dB per 20 s:", lv(Tb + A + H + B + Rt))
