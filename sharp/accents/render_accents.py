#!/usr/bin/env python3
"""render_accents.py (2026-10-02) -- the additive tornado + a PERCUSSION ACCENT layer driven by the dancers, rendered for listening.

Driver: the real end of today's run, 12:53:30-12:58:30 (force_recordings/derived/osc_2026-10-02_50hz.npz): the frenetic stretch
that ends when everyone unplugs, 5 min = the length of the additive tornado, so its climax lines up with theirs.
HITS: a sensor's jolt = |change of its AC| per 50-Hz frame; a hit when it crosses that sensor's 99th percentile over today's run
(11:47-13:04), at most one per 0.12 s per sensor; strength = jolt / threshold.
LAYERS, entering one after another (x = position in the piece, 0..1):
  klatter   (Thoughts klatter_hi/mid, Articulation klatter, boops)  from x 0     every hit sounds with chance 0.3 + 0.7 x
  thud      (Thoughts thud, Articulation thud, fry)                    from x 0.25  the stronger hits (strength > 1.3)
  boom      (Articulation bass drums, synthesized kicks)               from x 0.45  the strongest hits (> 1.8) and every central hit
  pulse     an accelerating kick heartbeat, 2 s -> 0.25 s apart        from x 0.5   (motion-independent: the tornado's own engine)
  phrases   Articulation excerpts, 1.5-4 s, stereo, layered in         from x 0.3   one per ~40 s -> one per ~4 s at the end
  + a motion-scaled klatter swarm that thickens with x (rate 0.2 -> 8 per s, times the ensemble's activity)
PLACE: each sensor's hits from its own region of the circle (sensor k at k x 60 deg, +-15), central and swarm anywhere, booms
wide (mostly W), phrases as a 60-degree stereo pair. LOUDER: the accent layer rises 12 dB across the piece.
Out (out/): accents_ambiX, tornado+accents ambiX / BINAURAL / QUAD on outs 1-4 (4 discrete channels, for QuickTime).
"""
import os, json, glob, subprocess, numpy as np, soundfile as sf, datetime as dt
from scipy.signal import fftconvolve
HERE = os.path.dirname(os.path.abspath(__file__)); BANK = os.path.join(HERE, "bank"); OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)
SO = os.path.abspath(os.path.join(HERE, "..", "..", "..")); SR, D, FS = 44100, 300.0, 50.0
TORN = os.path.join(SO, "tornado", "forann_line", "out_additive", "forann_additive_ambiX.wav")
HRIR = os.path.expanduser("~/Library/Application Support/ATK/kernels/FOA/decoders/cipic/44100/512/0021")
rng = np.random.default_rng(11)

def load_bank():
    b = json.load(open(os.path.join(BANK, "bank.json"))); cats = {}
    for e in b:
        y, sr = sf.read(os.path.join(BANK, e["file"]), dtype="float32"); cats.setdefault(e["cat"], []).append(y)
    return cats
def enc(s, az, width=0.8):   # mono -> ATK B (W X Y Z)
    return np.stack([s / np.sqrt(2), width * s * np.cos(az), width * s * np.sin(az), np.zeros_like(s)], 1)

def driver():
    d = np.load(os.path.join(SO, "rig", "force_recordings", "derived", "osc_2026-10-02_50hz.npz")); X = d["X"]; t0 = float(d["t0"])
    idx = lambda h, m, s: int((dt.datetime(2026, 10, 2, h, m, s).timestamp() - t0) * FS)
    def fill(a):
        a = a.copy()
        for k in range(a.shape[1]):
            m = np.isfinite(a[:, k]); i = np.where(m, np.arange(len(a)), 0); np.maximum.accumulate(i, out=i); a[:, k] = np.where(m.any(), a[i, k], 0)
        return np.nan_to_num(a)
    run = fill(X[idx(11, 47, 0):idx(13, 4, 0), 7:]); seg = fill(X[idx(12, 53, 30):idx(12, 53, 30) + int(D * FS), 7:])
    thr = np.percentile(np.abs(np.diff(run, axis=0)), 99, 0)
    jolt = np.vstack([np.zeros((1, 7)), np.abs(np.diff(seg, axis=0))]) / np.maximum(thr, 1e-6)
    act = np.convolve(np.sqrt((seg[:, :6] ** 2).mean(1)), np.ones(int(2 * FS)) / (2 * FS), "same"); act = act / (np.percentile(act, 95) + 1e-9)
    hits = []   # (time, sensor, strength)
    for k in range(7):
        last = -1.0
        for i in np.where((jolt[1:, k] > 1) & (jolt[:-1, k] <= 1))[0] + 1:
            t = i / FS
            if t - last >= 0.12: hits.append((t, k, float(jolt[i, k]))); last = t
    return sorted(hits), act

def render():
    cats = load_bank(); hits, act = driver(); n = int(D * SR); A = np.zeros((n, 4), np.float32); cnt = {}
    def place(y, t, az, gain, width=0.8):
        i = int(t * SR); m = min(len(y), n - i)
        if m > 0: A[i:i + m] += enc(y[:m] * gain, az, width)
    pick = lambda names: (lambda pool: pool[rng.integers(len(pool))])([y for c in names for y in cats.get(c, [])])
    cres = lambda x: 10 ** ((-12 + 12 * x) / 20)
    for t, k, st in hits:
        x = t / D; az = np.radians(k * 60 + rng.uniform(-15, 15)) if k < 6 else rng.uniform(0, 2 * np.pi); v = min(1.0, 0.45 + 0.25 * st)
        if rng.random() < 0.3 + 0.7 * x:
            place(pick(["klatter_hi", "klatter_mid", "art_klatter", "boops"]), t, az, 0.5 * v * cres(x)); cnt["klatter"] = cnt.get("klatter", 0) + 1
        if x >= 0.25 and st > 1.3 and rng.random() < 0.6:
            place(pick(["thud", "art_thud", "fry"]), t + 0.004, az, 0.6 * v * cres(x)); cnt["thud"] = cnt.get("thud", 0) + 1
        if x >= 0.45 and (st > 1.8 or k == 6) and rng.random() < 0.35 + 0.65 * x:
            place(pick(["art_boom", "art_boom", "kick"]), t, az, 0.8 * v * cres(x), width=0.3); cnt["boom"] = cnt.get("boom", 0) + 1
    t = 0.5 * D                                            # accelerating kick heartbeat
    while t < D - 2:
        x = t / D; place(pick(["kick", "art_boom"]), t, rng.uniform(0, 2 * np.pi), 0.7 * cres(x), width=0.2); cnt["pulse"] = cnt.get("pulse", 0) + 1
        t += 2.0 * (0.125 ** ((x - 0.5) / 0.5)) * rng.uniform(0.9, 1.1)
    t = 0.3 * D                                            # Articulation phrases, more and more often
    while t < D - 4:
        x = t / D; ph = cats["art_phrase"][rng.integers(len(cats["art_phrase"]))]; az = rng.uniform(0, 2 * np.pi)
        i = int(t * SR); m = min(len(ph), n - i)
        for c, off in ((0, 0.52), (1, -0.52)): A[i:i + m] += enc(ph[:m, c] * 0.45 * cres(x), az + off)
        cnt["phrase"] = cnt.get("phrase", 0) + 1; t += 40 * (0.1 ** ((x - 0.3) / 0.7)) * rng.uniform(0.7, 1.3)
    t = 0.0                                                # motion-scaled klatter swarm
    while t < D - 1:
        x = t / D; a = act[min(int(t * FS), len(act) - 1)]
        if rng.random() < min(1.0, 0.3 + a): place(pick(["klatter_hi", "klatter_mid", "boops", "art_klatter"]), t, rng.uniform(0, 2 * np.pi), 0.3 * cres(x)); cnt["swarm"] = cnt.get("swarm", 0) + 1
        t += rng.exponential(1.0 / (0.2 * 40 ** x))
    print("events:", cnt, "| motion hits in the 5 min:", len(hits))
    return A

def decode_write(B, name, n):
    tox = lambda b: np.stack([b[:, 0] * np.sqrt(2), b[:, 2], b[:, 3], b[:, 1]], 1)
    amb = tox(B); g = 10 ** (-1 / 20) / np.abs(amb).max(); sf.write(os.path.join(OUT, f"{name}_ambiX.wav"), amb * g, SR, subtype="PCM_24")
    hr = {c: sf.read(os.path.join(HRIR, f"HRIR_{c}.wav"))[0] for c in "WXYZ"}
    bi = sum(np.stack([fftconvolve(B[:, c], hr[ch][:, 0])[:n], fftconvolve(B[:, c], hr[ch][:, 1])[:n]], 1) for c, ch in enumerate("WXYZ"))
    sf.write(os.path.join(OUT, f"{name}_BINAURAL.wav"), bi * (10 ** (-1 / 20) / np.abs(bi).max()), SR, subtype="PCM_24")
    M = np.array([[0.353553, 0.25, 0.25], [0.353553, -0.25, 0.25], [0.353553, -0.25, -0.25], [0.353553, 0.25, -0.25]])   # ATK newQuad energy: FL BL BR FR
    FL, BL, BR, FR = M @ B[:, :3].T; q = np.stack([FL, FR, BR, BL], 1); q *= 10 ** (-1 / 20) / np.abs(q).max()
    w = os.path.join(OUT, f"{name}_QUAD_FL-FR-BR-BL.wav"); sf.write(w, q, SR, subtype="PCM_24")
    subprocess.run(["afconvert", w, os.path.join(OUT, f"{name}_QUAD_on_outs1-4_FOR_QUICKTIME.caf"), "-d", "LEI24", "-f", "caff", "-l", "9633796"], check=True)

if __name__ == "__main__":
    A = render(); n = len(A)
    T, sr = sf.read(TORN, dtype="float32"); T = T[:n]
    Tb = np.stack([T[:, 0] / np.sqrt(2), T[:, 3], T[:, 1], T[:, 2]], 1)          # ambiX -> ATK
    ra, rt = np.sqrt((A[-int(60 * SR):, 0] ** 2).mean()), np.sqrt((Tb[-int(60 * SR):, 0] ** 2).mean())
    A *= (rt / max(ra, 1e-9)) * 10 ** (-2 / 20)          # accents sit 2 dB under the tornado over the last minute
    decode_write(A, "accents_only", n); decode_write(Tb + A, "tornado_plus_accents", n)
    lv = lambda Y, a, b: round(float(20 * np.log10(np.sqrt((Y[int(a * SR):int(b * SR), 0] ** 2).mean()) + 1e-9)), 1)
    print("accent level (W, dB) at 0-60 / 120-180 / 240-300 s:", [lv(A, 0, 60), lv(A, 120, 180), lv(A, 240, 300)])
