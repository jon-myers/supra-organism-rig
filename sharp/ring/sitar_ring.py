#!/usr/bin/env python3
"""sitar_ring.py (2026-10-03, Jon: "the hard cut might need ... artificial like sitar strings sympathetic strings ringing over everything
at the end. Don't we have the stuff we made in python?" -- and, of the first SC try (plain combs): "that doesn't sound like simulated
strings at all")

The REAL idtap sitar string (idtap-client synthesis/kernels.py ks_string: extended Karplus-Strong, stiffness allpass, damping inside
the loop, JAWARI -- the curved bridge shortening the sounding length with the string's displacement, which is the buzz) used as 13
sympathetic (taraf) strings, never plucked, only driven by the tornado through the "bridge", then the fitted sitar body
(body_resonators). Input: the last LEAD s of the 3c cut render; at the cut the dry stops and the strings ring on.
  RING_DRIVE (drive gain, sets how hard the strings are hit = how much jawari)   RING_T60   RING_TUNE (midi list)
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

x, sr = sf.read(SRC, dtype="float64", always_2d=True)
cut = int(180.0 * sr); a = cut - int(LEAD * sr); dry = x[a:cut]
n = len(dry) + int(TAIL * sr)
drive = np.zeros(n); drive[:len(dry)] = dry.mean(1)
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
drms = np.sqrt((dry[-int(4 * sr):] ** 2).mean()); srms = np.sqrt((st[len(dry):len(dry) + int(1 * sr)] ** 2).mean()) + 1e-12
st = st * (drms * 10 ** (-4 / 20) / srms)                # the ring starts 4 dB under the dry just before the cut
halo = 10 ** (-14 / 20)                                 # under the music: 14 dB lower
env = np.ones(n) * halo; env[len(dry):] = 1.0; env[len(dry):len(dry) + int(0.05 * sr)] = np.linspace(halo, 1, int(0.05 * sr))
mix = st * env[:, None]; mix[:len(dry)] += dry
g = 10 ** (-1 / 20) / np.abs(mix).max()
sf.write(os.path.join(OUT, f"ring_{TAG}.wav"), (mix * g).astype(np.float32), sr, subtype="PCM_24")
sf.write(os.path.join(OUT, f"ring_{TAG}_strings_only.wav"), (st * g).astype(np.float32), sr, subtype="PCM_24")
print("wrote", f"ring_{TAG}.wav", "cut at", LEAD, "s")
