#!/usr/bin/env python3
"""build_bank.py (2026-10-02, Jon: "boomy bass drums, klattery percussive sounds, to accent things as it speeds up" ... "you can use
anything on the machine, including 18 thoughts") -- a bank of short percussive HITS for the tornado's accent layer.

Harvested by attack detection from
  Eleven/Seventeen Thoughts recording (2020, ~/Documents/2020/eleven_thoughts_recording): Parts 7 and 9 (strongly percussive:
     percussive/harmonic energy 15-60) and Part 2 (partly percussive)
  the Aug 28 session: boops, tongue rolls, vocal fry (concatenator-corpus/corpus/v9-aug28-*)
A hit = attack (backtracked onset) -> up to 0.35 s or the next attack; kept if loud enough and SHARP (energy in its first 15 ms
well above the 15 ms before it); 3 ms fade-in guard, 25 ms fade-out, peak -3 dBFS. Sorted by spectral centroid:
  thud (< 1200 Hz)   klatter_mid (1200-3000)   klatter_hi (> 3000)      + source families boops / rolls / fry kept apart
KICKS: synthesized "boomy" bass drums (pitch drop 150 -> 42-55 Hz, 0.35-1.0 s decay, a 4-ms click, gentle saturation).
Out: bank/<category>/<nnn>.wav (44.1 k mono) and bank/bank.json [{file, cat, src, centroid, dur}]
"""
import os, glob, json, re, numpy as np, soundfile as sf, librosa
HERE = os.path.dirname(os.path.abspath(__file__)); BANK = os.path.join(HERE, "bank"); SR = 44100
TH = os.path.expanduser("~/Documents/2020/eleven_thoughts_recording")
C = os.path.expanduser("~/Documents/2026/MIT/projects/supra-organism/concatenator-corpus/corpus")
SOURCES = [("thoughts", f) for f in sorted(glob.glob(os.path.join(TH, "*Part 7 - *.wav")) + glob.glob(os.path.join(TH, "*Part 9 - *.wav"))
                                            + glob.glob(os.path.join(TH, "*Part 2 - *.wav"))) if os.path.getsize(f) > 1.5e6]
SOURCES += [(fam, f) for fam, d in (("boops", "v9-aug28-boops"), ("rolls", "v9-aug28-rolls"), ("fry", "v9-aug28-vocal-fry")) for f in sorted(glob.glob(os.path.join(C, d, "*.wav")))]
MAX_PER_FILE, MAX_PER_CAT = 12, 120
LIMIT = [MAX_PER_FILE]   # hits per file (raised for Articulation)
# ARTICULATION for large percussion ensemble (Jon, 2017; recording 2019-08-23): real drums. Hits from the whole piece, and
# PHRASES (1.5-4 s stereo excerpts from its busiest passages) to layer in here and there (Jon: "you can even just layer in bits")
ART = os.path.expanduser("~/Desktop/old desktop/presentation materials/Articulation (2018)/Articulation - 8-23-2019.wav")
ART_HITS, ART_PHRASES = 400, 60

def hits(x, sharp=4.0, floor=0.02):
    on = librosa.onset.onset_detect(y=librosa.resample(x, orig_sr=SR, target_sr=22050), sr=22050, units="samples", backtrack=True) * 2
    out = []
    for j, a in enumerate(on):
        b = min(a + int(0.35 * SR), on[j + 1] if j + 1 < len(on) else len(x), len(x))
        if b - a < int(0.06 * SR) or a < int(0.015 * SR): continue
        seg = x[a:b].copy(); pre = x[a - int(0.015 * SR):a]; head = seg[:int(0.015 * SR)]
        pk = np.abs(seg).max()
        if pk < floor or np.sqrt((head ** 2).mean()) < sharp * (np.sqrt((pre ** 2).mean()) + 1e-6): continue   # quiet or not sharp
        out.append((pk, seg))
    out.sort(key=lambda h: -h[0]); return [s for _, s in out[:LIMIT[0]]]

def finish(seg):
    fi, fo = int(0.003 * SR), int(0.025 * SR)
    seg = seg.copy(); seg[:fi] *= np.linspace(0, 1, fi); seg[-fo:] *= np.linspace(1, 0, fo)
    return (seg / (np.abs(seg).max() + 1e-9) * 10 ** (-3 / 20)).astype(np.float32)

def kick(f_end, decay, seed):
    rng = np.random.default_rng(seed); n = int((decay + 0.05) * SR); t = np.arange(n) / SR
    f = f_end + (150 - f_end) * np.exp(-t / 0.035); ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t / (decay / 4.0))
    click = rng.standard_normal(n) * np.exp(-t / 0.002) * 0.35
    y = np.tanh(1.6 * (body + click)) / np.tanh(1.6); return finish(y)

if __name__ == "__main__":
    bank, counts = [], {}
    def put(cat, src, y):
        if counts.get(cat, 0) >= MAX_PER_CAT: return
        k = counts[cat] = counts.get(cat, 0) + 1; d = os.path.join(BANK, cat); os.makedirs(d, exist_ok=True)
        p = os.path.join(d, f"{k:03d}.wav"); sf.write(p, y, SR, subtype="PCM_24")
        S = np.abs(np.fft.rfft(y * np.hanning(len(y)))); fr = np.fft.rfftfreq(len(y), 1 / SR)
        bank.append(dict(file=os.path.relpath(p, BANK), cat=cat, src=src, centroid=round(float((S * fr).sum() / (S.sum() + 1e-9))), dur=round(len(y) / SR, 3)))
    for fam, f in SOURCES:
        x, sr = sf.read(f, dtype="float32", always_2d=True); x = x.mean(1)
        if sr != SR: x = librosa.resample(x, orig_sr=sr, target_sr=SR)
        for seg in hits(x[: SR * 120]):
            y = finish(seg); S = np.abs(np.fft.rfft(y)); fr = np.fft.rfftfreq(len(y), 1 / SR); cen = (S * fr).sum() / (S.sum() + 1e-9)
            cat = fam if fam != "thoughts" else ("thud" if cen < 1200 else "klatter_mid" if cen < 3000 else "klatter_hi")
            put(cat, os.path.basename(f), y)
    if os.path.exists(ART):
        xs, sr = sf.read(ART, dtype="float32", always_2d=True)
        if sr != SR: xs = librosa.resample(xs.T, orig_sr=sr, target_sr=SR).T
        x = xs.mean(1); LIMIT[0] = ART_HITS

        for seg in hits(x, sharp=1.6, floor=0.01):   # a dense, reverberant ensemble recording: a gentler sharpness test
            y = finish(seg); S = np.abs(np.fft.rfft(y)); fr = np.fft.rfftfreq(len(y), 1 / SR); cen = (S * fr).sum() / (S.sum() + 1e-9)
            low = (S[fr < 150] ** 2).sum() / ((S ** 2).sum() + 1e-12)   # bass drums: energy below 150 Hz, not the (attack-bright) centroid
            put("art_boom" if low > 0.35 else "art_thud" if cen < 1500 else "art_klatter", "articulation", y)
        LIMIT[0] = MAX_PER_FILE
        # phrases: windows with the most attacks per second, starting on an attack
        on = librosa.onset.onset_detect(y=librosa.resample(x, orig_sr=SR, target_sr=22050), sr=22050, units="time", backtrack=True)
        dens = np.array([((on >= t) & (on < t + 3)).sum() for t in on]); order = np.argsort(-dens); used = []
        for j in order:
            t = on[j]
            if any(abs(t - u) < 6 for u in used): continue
            L = float(np.clip(1.5 + dens[j] / 6, 1.5, 4.0)); a, b = int(t * SR), int((t + L) * SR)
            if b > len(xs): continue
            ph = xs[a:b].copy(); fo = int(0.3 * SR); fi = int(0.003 * SR)
            ph[:fi] *= np.linspace(0, 1, fi)[:, None]; ph[-fo:] *= np.linspace(1, 0, fo)[:, None]
            ph = (ph / (np.abs(ph).max() + 1e-9) * 10 ** (-3 / 20)).astype(np.float32)
            k = counts["art_phrase"] = counts.get("art_phrase", 0) + 1; d = os.path.join(BANK, "art_phrase"); os.makedirs(d, exist_ok=True)
            pth = os.path.join(d, f"{k:03d}.wav"); sf.write(pth, ph, SR, subtype="PCM_24"); used.append(t)
            bank.append(dict(file=os.path.relpath(pth, BANK), cat="art_phrase", src=f"articulation {t:.1f}s", centroid=0, dur=round(L, 2), attacks_per_3s=int(dens[j])))
            if k >= ART_PHRASES: break
    for i, (fe, dec) in enumerate([(42, 1.0), (45, 0.8), (48, 0.6), (50, 0.9), (55, 0.45), (44, 0.7), (52, 0.35), (46, 0.55)]):
        put("kick", "synth", kick(fe, dec, i))
    json.dump(bank, open(os.path.join(BANK, "bank.json"), "w"), indent=0)
    print({c: n for c, n in sorted(counts.items())})
