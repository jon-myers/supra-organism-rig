#!/usr/bin/env python3
"""sitar_ring.py (2026-10-03, Jon: "the hard cut might need ... artificial like sitar strings sympathetic strings ringing over everything
at the end. Don't we have the stuff we made in python?" -- and, of the first SC try (plain combs): "that doesn't sound like simulated
strings at all")

The REAL idtap sitar string (idtap-client synthesis/kernels.py ks_string: extended Karplus-Strong, stiffness allpass, damping inside
the loop, JAWARI -- the curved bridge shortening the sounding length with the string's displacement, which is the buzz) used as 13
sympathetic (taraf) strings, never plucked, only driven by the tornado through the "bridge", then the fitted sitar body
(body_resonators). Input: the last LEAD s of the 3c cut render; at the cut the dry stops and the strings ring on.
  RING_DRIVE (drive gain, sets how hard the strings are hit = how much jawari)   RING_T60   RING_TUNE (midi list)
  RING_MODE (Jon: "what would be most natural, like muting with a finger? or a little percussive accent to end?"):
    fade    the 3c cut render as it is (its own 0.2-s fade)          [default, the first renders a/b/c]
    choke   the HOLD render cut in 5 ms (what SC's HARD CUT does)
    finger  the HOLD render damped like a hand on the strings: highs go first, gone in ~30 ms
    accent  a final hit (boom + kick + klatter burst) at the cut, the rest choked under it; the hit rings out naturally
  In every mode the strings are driven by what is actually heard, so the last sound is what they ring from.
  out/ring_<tag>.wav (dry + strings, cut at LEAD s)   out/ring_<tag>_strings_only.wav
"""
import os, sys, numpy as np, soundfile as sf
sys.path.insert(0, "/Users/jon/Documents/2026/MIT/projects/idtap/idtap-client")
from idtap.synthesis import kernels as K
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)
SRC = os.path.join(HERE, "..", "accents", "out", "tornado3c_cut_full_BINAURAL.wav")
LEAD, TAIL = 20.0, 16.0
DRIVE = float(os.environ.get("RING_DRIVE", "0.02")); T60 = float(os.environ.get("RING_T60", "13"))
TUNE = [int(v) for v in os.environ.get("RING_TUNE", "48,50,52,55,57,60,62,64,67,69,72,74,76").split(",")]
TAG = os.environ.get("RING_TAG", "a")

MODE = os.environ.get("RING_MODE", "fade")
if MODE == "fade":
    x, sr = sf.read(SRC, dtype="float64", always_2d=True); cut = int(180.0 * sr)
else:
    x, sr = sf.read(SRC.replace("tornado3c_cut_full", "tornado3c_full"), dtype="float64", always_2d=True); cut = int(195.0 * sr)   # inside the hold
a = cut - int(LEAD * sr); n = int(LEAD * sr) + int(TAIL * sr)
dry = np.zeros((n, 2)); dry[:int(LEAD * sr)] = x[a:cut]
if MODE in ("choke", "finger", "accent"):
    k = int(LEAD * sr); post = x[cut:cut + int(0.2 * sr)]; dry[k:k + len(post)] = post          # the music would go on: shape it
    if MODE == "choke" or MODE == "accent":
        m = int((0.005 if MODE == "choke" else 0.012) * sr); env = np.zeros(int(0.2 * sr)); env[:m] = 0.5 * (1 + np.cos(np.linspace(0, np.pi, m)))
        dry[k:k + len(env)] *= env[:, None]
    if MODE == "finger":
        from scipy.signal import butter, sosfilt
        m = int(0.2 * sr); seg = dry[k:k + m].copy(); t = np.arange(m) / sr
        lo = np.stack([sosfilt(butter(2, 400, fs=sr, output="sos"), seg[:, c]) for c in range(2)], 1)   # highs damped first
        w = np.clip(t / 0.008, 0, 1)[:, None]; seg = seg * (1 - w) + lo * w
        dry[k:k + m] = seg * np.exp(-t / 0.006)[:, None] * (t < 0.04)[:, None]
    if MODE == "accent":
        B = os.path.join(HERE, "..", "accents")
        rng = np.random.default_rng(3); hit = np.zeros((int(TAIL * sr), 2))
        def add(rel, gain, pan, delay=0.0):
            y, fs = sf.read(os.path.join(B, rel), dtype="float64", always_2d=True); y = y.mean(1)
            if fs != sr: from scipy.signal import resample_poly; y = resample_poly(y, sr, fs)
            i = int(delay * sr); y = y[:len(hit) - i]; hit[i:i + len(y), 0] += y * gain * np.sqrt((1 - pan) / 2); hit[i:i + len(y), 1] += y * gain * np.sqrt((1 + pan) / 2)
        import json; man = json.load(open(os.path.join(B, "live", "live.json")))["hits"]
        add(man["art_boom"][7], 1.0, -0.3); add(man["art_boom"][41], 1.0, 0.3); add(man["kick"][2], 0.9, 0.0)
        for j in range(9): add(rng.choice(man["klatter_mid"] + man["art_klatter"]), 0.5 * 0.8 ** j, rng.uniform(-1, 1), j * rng.uniform(0.012, 0.03))
        lvl = np.sqrt((x[cut - int(2 * sr):cut] ** 2).mean()); hit *= lvl * 10 ** (6 / 20) / (np.sqrt((hit[:int(0.3 * sr)] ** 2).mean()) + 1e-12)
        dry[k:] += hit[:n - k]
drive = dry.mean(1)
hop = 64; ctrl = lambda v: np.full(n // hop + 2, float(v))
strings = []
for m in TUNE:
    f = 440 * 2 ** ((m - 69) / 12)
    t60c = (T60 - K.KS_T60_MIN) / (K.KS_T60_MAX - K.KS_T60_MIN)    # cutoff_ctrl -> this T60
    y = K.ks_string(ctrl(f), ctrl(min(1.0, max(0.0, t60c))), drive * DRIVE, float(sr), hop, 1.0)
    strings.append(y)
S = np.array(strings); print("per-string peak", np.round(np.abs(S).max(1), 3), " (jawari touches above", round(K.JAWARI_THRESHOLD, 4), ")")
taraf = S.sum(0) / np.sqrt(len(TUNE))
taraf = K.body_resonators(taraf, K.SITAR_BODY_FREQS.copy(), K.SITAR_BODY_QS, K.SITAR_BODY_MIX, float(sr))
# stereo: alternate strings left / right a little
L = (S[0::2].sum(0) * 1.0 + S[1::2].sum(0) * 0.6) / np.sqrt(len(TUNE)); R = (S[1::2].sum(0) * 1.0 + S[0::2].sum(0) * 0.6) / np.sqrt(len(TUNE))
body = lambda v: K.body_resonators(v, K.SITAR_BODY_FREQS.copy(), K.SITAR_BODY_QS, K.SITAR_BODY_MIX, float(sr))
st = np.stack([body(L), body(R)], 1)
drms = np.sqrt((x[cut - int(4 * sr):cut] ** 2).mean()); srms = np.sqrt((st[int(LEAD * sr):int(LEAD * sr) + int(1 * sr)] ** 2).mean()) + 1e-12
AFTER = float(os.environ.get("RING_AFTER", "-16"))
st = st * (drms * 10 ** (AFTER / 20) / srms)             # the ring sits AFTER dB under the music (was -4: too loud, it read as a fade)
halo = 1.0 if MODE != "fade" else 10 ** (-14 / 20)      # physical: the strings ring the same before and after; the cut only exposes them
env = np.ones(n) * halo; k0 = int(LEAD * sr); env[k0:] = 1.0; env[k0:k0 + int(0.05 * sr)] = np.linspace(halo, 1, int(0.05 * sr))
mix = st * env[:, None] + dry
g = 10 ** (-1 / 20) / np.abs(mix).max()
sf.write(os.path.join(OUT, f"ring_{TAG}.wav"), (mix * g).astype(np.float32), sr, subtype="PCM_24")
sf.write(os.path.join(OUT, f"ring_{TAG}_strings_only.wav"), (st * g).astype(np.float32), sr, subtype="PCM_24")
print("wrote", f"ring_{TAG}.wav", "cut at", LEAD, "s")
