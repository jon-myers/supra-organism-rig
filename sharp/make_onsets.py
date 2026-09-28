"""
make_onsets.py -- breath onset times for each of the 36 breath36 voices (2026-09-26).
Reads each voice's slot0 file (the breath end of the morph), detects onsets on a smoothed
onset-strength envelope tuned for soft breath attacks (median-filtered, adaptive threshold,
>= 0.35 s apart), writes sharp/onsets.json = {"voices": [[t, t, ...] x 36], "sr_grid": 100}.
"""
import json, os, glob, sys, numpy as np, librosa, soundfile as sf
HERE = os.path.dirname(os.path.abspath(__file__)); VD = os.environ.get("B36_OUT", os.path.join(HERE, "..", "breath36_voices")); SUF = os.environ.get("B36_SUFFIX", "")
meta = json.load(open(os.path.join(VD, "voices.json")))
# usage: make_onsets.py            -> onsets.json (originals, keyed by voice order)
#        make_onsets.py --speed    -> onsets_speed.json, keyed "<slot0 basename>_x<L>", windows scaled by 1/L
SPEED = "--speed" in sys.argv
levels = json.load(open(os.path.join(VD, "speed", "speed.json")))["levels"] if SPEED else [1.0]
out = {"sr_grid": 100, "voices": [], "by_file": {}}
def detect(f, lv):
    y, sr = librosa.load(f, sr=22050, mono=True)
    hop = 256
    # loudness swells, not spectral flux: RMS (dB), smoothed 100 ms, peaks >= 0.35 s apart with a
    # prominence test against a 2 s neighbourhood, each backtracked to the preceding valley
    rms = librosa.amplitude_to_db(librosa.feature.rms(y=y, frame_length=1024, hop_length=hop)[0] + 1e-5)
    k = int(0.1 * sr / hop); rms = np.convolve(rms, np.ones(k) / k, mode="same")
    fps = sr / hop; w = 1.0 / lv
    pk = librosa.util.peak_pick(rms, pre_max=max(1,int(0.5*w*fps)), post_max=max(1,int(0.5*w*fps)), pre_avg=max(2,int(2*w*fps)), post_avg=max(2,int(2*w*fps)), delta=2.0, wait=max(1,int(0.35*w*fps)))
    on = []
    for i in pk:
        j = i
        while j > 0 and rms[j-1] <= rms[j]: j -= 1          # back to the valley
        # onset = where the rise passes 25 % of the way from valley to peak
        thr = rms[j] + 0.25 * (rms[i] - rms[j]); m = j
        while m < i and rms[m] < thr: m += 1
        on.append(m / fps)
    on = np.array(on)
    dur = len(y) / sr; return [round(float(t), 3) for t in on if 0.05 < t < dur - 0.1], dur
for v in meta["voices"]:
    for lv in levels:
        base = os.path.splitext(v["files"][0])[0]
        f = os.path.join(VD, v["files"][0]) if not SPEED else os.path.join(VD, "speed", f"{base}_x{lv:g}.wav")
        on, dur = detect(f, lv)
        if SPEED: out["by_file"][f"{base}_x{lv:g}"] = on
        else: out["voices"].append(on)
        print(f"v{v['voice']:02d} {v['performer']:8s} x{lv:<4g} {dur:6.1f} s  {len(on):3d} onsets  mean gap {dur/max(1,len(on)):.2f} s")
json.dump(out, open(os.path.join(HERE, ("onsets_speed" if SPEED else "onsets") + SUF + ".json"), "w"))
