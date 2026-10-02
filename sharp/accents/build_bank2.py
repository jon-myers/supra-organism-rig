#!/usr/bin/env python3
"""build_bank2.py (2026-10-02 evening, Jon: "many harmonium pitches increasingly more as it goes on ... the very ending needs to be
higher, certainly higher pitched harmonium" + "don't we have that bioacoustic library? ... randomly start to pull in some of those")

  harm_hi/   the 33 chromatic harmonium notes (v7-harmonium-all aug18__r*, F2-A4) also at +12 and +24 semitones (to A6), and the 24
             chord / build-up takes at +7, +12, +19 -- Rubber Band R3, pitch only (same length, formants not preserved: a bigger
             harmonium, not a chipmunk voice). Named <semitones from F2 or 'chord'>__<orig>__p<shift>.wav
  bio/       calls from the Macaulay Library birdsong set (concatenator-corpus/corpus/macaulay-birdsong, 940 recordings): from 260
             random recordings, the loudest 1.2-3.5 s window (and a second one if it is nearly as loud), 10 ms in / 250 ms out, peak
             -3 dBFS, with spectral flatness (tonal 0 .. noisy 1) and centroid in bio/bio.json
"""
import os, re, glob, json, subprocess, numpy as np, soundfile as sf, librosa
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__)); BANK = os.path.join(HERE, "bank"); SR = 44100
SO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
HARM = os.path.join(SO, "concatenator-corpus", "corpus", "v7-harmonium-all"); BIRDS = os.path.join(SO, "concatenator-corpus", "corpus", "macaulay-birdsong")
NOTE = {"C": 0, "C#": 1, "D": 2, "Eb": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "Ab": 8, "A": 9, "Bb": 10, "B": 11}

def harm():
    out = os.path.join(BANK, "harm_hi"); os.makedirs(out, exist_ok=True); jobs = []
    for f in sorted(glob.glob(os.path.join(HARM, "*.wav"))):
        m = re.search(r"_([A-G][#b]?)(\d)\.wav$", f)
        shifts = (12, 24) if m else (7, 12, 19)
        for sh in shifts:
            o = os.path.join(out, f"{'%02d' % (12 * int(m.group(2)) + NOTE[m.group(1)] - 41 + sh) if m else 'chord'}__{os.path.basename(f)[:-4]}__p{sh}.wav")
            if not os.path.exists(o): jobs.append((f, o, sh))
    run = lambda j: subprocess.run(["rubberband", "-3", "-q", "-p", str(j[2]), j[0], j[1]], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"pitch-shifting {len(jobs)} harmonium files ...", flush=True)
    with ThreadPoolExecutor(8) as ex: list(ex.map(run, jobs))
    print("harm_hi:", len(glob.glob(os.path.join(out, "*.wav"))))

def bio(n_files=260, seed=5):
    out = os.path.join(BANK, "bio"); os.makedirs(out, exist_ok=True); rng = np.random.default_rng(seed)
    files = sorted(glob.glob(os.path.join(BIRDS, "*.mp3"))); pick = rng.choice(files, size=min(n_files, len(files)), replace=False)
    def one(f):
        try: y, _ = librosa.load(f, sr=SR, mono=True, duration=60)
        except Exception: return []
        if len(y) < SR * 2: return []
        h = int(0.05 * SR); e = np.convolve((y ** 2)[: len(y) // h * h].reshape(-1, h).mean(1), np.ones(30) / 30, "same")
        res = []
        for _ in range(2):
            i = int(np.argmax(e)); peak = e[i]
            if res and peak < 0.6 * res[0][0]: break
            L = rng.uniform(1.2, 3.5); a = max(0, int(i * h - 0.4 * L * SR)); seg = y[a:a + int(L * SR)].copy()
            if len(seg) < SR: break
            fi, fo = int(0.01 * SR), int(0.25 * SR); seg[:fi] *= np.linspace(0, 1, fi); seg[-fo:] *= np.linspace(1, 0, fo)
            seg = seg / (np.abs(seg).max() + 1e-9) * 10 ** (-3 / 20)
            S = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2 + 1e-12; fr = np.fft.rfftfreq(len(seg), 1 / SR)
            res.append((peak, seg.astype(np.float32), float(np.exp(np.log(S).mean()) / S.mean()), float((S * fr).sum() / S.sum())))
            e[max(0, i - 60):i + 60] = 0
        return [(os.path.basename(f), r) for r in res]
    meta = []
    with ThreadPoolExecutor(8) as ex:
        for lst in ex.map(one, pick):
            for name, (pk, seg, flat, cen) in lst:
                k = len(meta) + 1; p = os.path.join(out, f"{k:03d}.wav"); sf.write(p, seg, SR, subtype="PCM_24")
                meta.append(dict(file=f"bio/{k:03d}.wav", src=name, flatness=round(flat, 3), centroid=round(cen), dur=round(len(seg) / SR, 2)))
    json.dump(meta, open(os.path.join(out, "bio.json"), "w"), indent=0); print("bio calls:", len(meta))

if __name__ == "__main__":
    harm(); bio()
