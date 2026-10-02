#!/usr/bin/env python3
"""render_distance.py (2026-10-01) -- what DISTANCE adds to the 36 breath voices in first-order ambisonics.

For N = 4, 10, 20, 36 voices: two 45-s renders with the SAME voices, morph steps and azimuths:
  flat      every voice at 3 m
  distance  each voice at its own distance, 1-12 m (log-spread, golden-ratio order: any first N span near to far)
Each voice = one breath36 render (breath36_voices, a fixed morph step 2-6 so there is some harmonium pitch), placed at an
azimuth with even coverage round the circle (the 36 slots shuffled + jitter, like ambi.scd's "random, even coverage").

Distance cues, all from r (metres):
  level         1/r  (ref 1 m)                      -> 1 m = 0 dB, 3 m = -9.5 dB, 12 m = -21.6 dB
  air           one-pole low-pass at 20 kHz / (1 + (r/4)^1.5)   -> 17.8 kHz at 1 m, 12 kHz at 3 m, 3.3 kHz at 12 m
                (exaggerated vs real air, which barely matters at 12 m; perception needs the help)
  room          constant reverb send 1/3 (the wall's room IR, unit energy): dry = wet at 3 m, so near voices are dry and
                far ones mostly room. Reverb is spread round the circle (IR L / R at +-60 deg, decorrelated tails with the same decay at +-150 deg).
  arrival       r / 343 s delay (35 ms at 12 m)
  size          near voices are WIDE: the directional components scaled by k = clip((r - 0.5) / 2.5, 0.35, 1), i.e. a voice
                at 1 m is part-omni (enveloping), from ~3 m on a point.
Outputs (out/): <N>v_<flat|distance>_BINAURAL.wav (ATK's CIPIC 21 KEMAR HRIRs, the same decode as the rig's binaural) and
<N>v_<flat|distance>_ambiX.wav (FOA, ACN/SN3D). Each file is normalised to the same RMS (-23 dBFS) so N and the two versions
compare at equal loudness; peaks are reported.
"""
import json, os, numpy as np, soundfile as sf
from scipy.signal import fftconvolve, lfilter

HERE = os.path.dirname(os.path.abspath(__file__))
RIG = os.path.abspath(os.path.join(HERE, "..", ".."))
VOX = os.path.join(RIG, "breath36_voices")
IR = os.path.join(RIG, "..", "wall_of_sound", "analysis", "room_ir_44k.wav")
HRIR = os.path.expanduser("~/Library/Application Support/ATK/kernels/FOA/decoders/cipic/44100/512/0021")
# STEP=0 (env) renders every voice at one fixed morph step (0 = plain breath) into out_step<k>/; default = random steps 2-6 into out/
FIXED_STEP = os.environ.get("STEP")
LOWCUT = float(os.environ.get("LOWCUT", "0"))   # Hz, 24 dB/oct (4th-order Butterworth); the rig's breath default is 70
OUT = os.path.join(HERE, ("out" if FIXED_STEP is None else f"out_step{FIXED_STEP}") + (f"_lowcut{int(LOWCUT)}" if LOWCUT > 0 else "")); os.makedirs(OUT, exist_ok=True)
SR, DUR, START = 44100, 45.0, 20.0
rng = np.random.default_rng(20261001)

meta = json.load(open(os.path.join(VOX, "voices.json")))
# tile performers a g r s a g r s ... (as breath36.scd does)
perfs = sorted({v["performer"] for v in meta["voices"]}); order, used = [], set()
while len(order) < len(meta["voices"]):
    for p in perfs:
        j = next((j for j, v in enumerate(meta["voices"]) if v["performer"] == p and j not in used), None)
        if j is not None: order.append(j); used.add(j)
voices = [meta["voices"][j] for j in order]
steps = rng.integers(2, 7, size=36)
if FIXED_STEP is not None: steps = np.full(36, int(FIXED_STEP))
az = ((rng.permutation(36) + rng.uniform(-0.5, 0.5, 36)) * (2 * np.pi / 36) + np.pi) % (2 * np.pi) - np.pi
# distances log-spread over 1-12 m in a golden-ratio order, so ANY first N voices span near to far (a plain random draw
# put all of the first 4 between 1.7 and 3.7 m)
dist = np.exp(((0.5 + np.arange(36) * 0.618034) % 1.0) * np.log(12))

hr = {c: sf.read(os.path.join(HRIR, f"HRIR_{c}.wav"))[0] for c in "WXYZ"}   # each (512, 2): L, R
ir, irsr = sf.read(IR); assert irsr == SR
def _decorrelated_tail(h, seed):   # same energy envelope (5-ms RMS) as h, fresh noise
    w = int(0.005 * SR); env = np.sqrt(np.convolve(h ** 2, np.ones(w) / w, "same"))
    t = np.random.default_rng(seed).standard_normal(len(h)) * env; return t * np.sqrt((h ** 2).sum() / (t ** 2).sum())
IR_REAR = [_decorrelated_tail(ir[:, 0], 11), _decorrelated_tail(ir[:, 1], 12)]
n = int(DUR * SR)

def load(i):
    v = voices[i]; x, sr = sf.read(os.path.join(VOX, v["files"][steps[i]]), dtype="float64"); assert sr == SR
    s = int(START * SR); x = x[s:s + n] if len(x) >= s + n else np.resize(x, n)
    if LOWCUT > 0:
        from scipy.signal import butter, sosfilt
        x = sosfilt(butter(4, LOWCUT, "highpass", fs=SR, output="sos"), x)
    return x

def onepole_lp(x, fc):
    a = np.exp(-2 * np.pi * fc / SR); return lfilter([1 - a], [1, -a], x)

def enc_atk(s, theta, k=1.0):   # ATK B-format (W at -3 dB), + azimuth = left
    return np.stack([s / np.sqrt(2), k * s * np.cos(theta), k * s * np.sin(theta), np.zeros_like(s)], 1)

def render(N, flat):
    B = np.zeros((n, 4)); send = np.zeros(n)
    for i in range(N):
        r = 3.0 if flat else dist[i]
        s = load(i) * (1.0 / r)
        s = onepole_lp(s, 20000 / (1 + (r / 4) ** 1.5))
        d = int(r / 343 * SR); s = np.concatenate([np.zeros(d), s[:n - d]])
        k = float(np.clip((r - 0.5) / 2.5, 0.35, 1.0))
        B += enc_atk(s, az[i], k); send += s * r * (1 / 3)   # the send is taken BEFORE the 1/r (constant wet level)
    send *= (1.0 / 3.0)                                       # dry 1/r vs wet 1/3: equal at r = 3 m
    wl, wr = fftconvolve(send, ir[:, 0])[:n], fftconvolve(send, ir[:, 1])[:n]
    # rear reverb = DECORRELATED tails (noise shaped by the room IR's own decay), NOT delayed copies of the front: a 17-ms
    # delayed copy summed in the ears made a comb filter (notches every 59 Hz; heard 2026-10-01, cepstrum peak at 17.0 ms)
    wl2, wr2 = fftconvolve(send, IR_REAR[0])[:n], fftconvolve(send, IR_REAR[1])[:n]
    B += 0.7 * (enc_atk(wl, np.radians(60)) + enc_atk(wr, np.radians(-60)) + enc_atk(wl2, np.radians(150)) + enc_atk(wr2, np.radians(-150)))
    # binaural: sum over W X Y Z of channel * HRIR (as ATK's FoaDecoderKernel)
    bin_ = sum(np.stack([fftconvolve(B[:, c], hr[ch][:, 0])[:n], fftconvolve(B[:, c], hr[ch][:, 1])[:n]], 1) for c, ch in enumerate("WXYZ"))
    # ambiX (ACN W Y Z X, SN3D): from ATK (W*sqrt2, then reorder)
    ambix = np.stack([B[:, 0] * np.sqrt(2), B[:, 2], B[:, 3], B[:, 1]], 1)
    g = 10 ** (-23 / 20) / np.sqrt((bin_ ** 2).mean())
    tag = f"{N}v_{'flat' if flat else 'distance'}"
    sf.write(os.path.join(OUT, f"{tag}_BINAURAL.wav"), bin_ * g, SR, subtype="PCM_24")
    sf.write(os.path.join(OUT, f"{tag}_ambiX.wav"), ambix * g * 0.7, SR, subtype="PCM_24")
    print(f"{tag}: peak {20*np.log10(np.abs(bin_*g).max()):.1f} dBFS" + ("" if flat else
          f"; distances (m) {np.round(dist[:N], 1).tolist()}"))

if __name__ == "__main__":
    # sanity check of the binaural decode: a source hard left must be louder in the left ear
    t = rng.standard_normal(SR); t = np.diff(t, prepend=0)   # bright noise
    Bt = enc_atk(t, np.pi / 2); b = sum(np.stack([fftconvolve(Bt[:, c], hr[ch][:, 0]), fftconvolve(Bt[:, c], hr[ch][:, 1])], 1) for c, ch in enumerate("WXYZ"))
    print(f"check: hard-left noise, L-R = {20*np.log10(np.sqrt((b[:,0]**2).mean())/np.sqrt((b[:,1]**2).mean())):+.1f} dB (SC test gave about +17.5)")
    for N in (4, 10, 20, 36):
        for flat in (True, False): render(N, flat)
