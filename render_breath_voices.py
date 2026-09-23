#!/usr/bin/env python
"""Render N seamless looping breath-collage voices for breath_chorus.scd.

Each voice = one performer's breathing take, cut at its breath/silence gaps
(chorus_slots.segment, the same cut the Sep 1 breath choruses used), replayed
in its OWN shuffled order and cycled to the loop length. Voices are assigned
round-robin to performers, so voices 1-4 are four different people, 5-8 the
next shuffle of each, and so on. The loop seam is an equal-power crossfade of
the tail into the head, so every file loops without a click.

No GPU: the breath chorus is pure collage of the recordings.

    ../concatenator-corpus/.venv/bin/python render_breath_voices.py
"""
import argparse, json, os, random, sys
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
SO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SO, "sa-flowedit"))
from chorus_slots import read, segment  # noqa: E402

PERFORMERS = ["anna", "grisha", "raymond", "sora"]


def build(mono, segs, order, xfade, n):
    """segments in order, cycled until n samples, crossfaded at every join"""
    buf = np.zeros(n + xfade + 1)
    pos, i = 0, 0
    while pos < n:
        a, b = segs[order[i % len(order)]]
        i += 1
        piece = mono[a:b].copy()
        if len(piece) < 2:
            continue
        f = min(xfade, len(piece), pos)
        if f > 0:
            t = np.linspace(0, np.pi / 2, f)
            pos -= f
            buf[pos:pos + f] *= np.cos(t)
            piece[:f] *= np.sin(t)
        end = min(pos + len(piece), len(buf))
        buf[pos:end] += piece[:end - pos]
        pos += len(piece)
    return buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voices", type=int, default=20)
    ap.add_argument("--loop", type=float, default=120.0, help="loop length, s")
    ap.add_argument("--seed", type=int, default=21)
    ap.add_argument("--xfade-ms", type=float, default=60.0)
    ap.add_argument("--seam-ms", type=float, default=400.0)
    ap.add_argument("--out", default=os.path.join(HERE, "breath_voices"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    src = {}
    for p in PERFORMERS:
        path = os.path.join(SO, "sa-flowedit", "input_audio", "defaults", f"breathing_2__{p}.wav")
        sr, y = read(path)
        mono = y.mean(axis=1)
        segs = segment(y, sr, None, 120.0, 250.0)
        src[p] = (sr, mono, segs)
        print(f"{p}: {len(mono) / sr:.1f}s, {len(segs)} segments")

    sr = src[PERFORMERS[0]][0]
    n = int(a.loop * sr)
    seam = int(a.seam_ms * sr / 1000)
    xf = int(a.xfade_ms * sr / 1000)
    voices = []
    for v in range(a.voices):
        p = PERFORMERS[v % len(PERFORMERS)]
        _, mono, segs = src[p]
        order = list(range(len(segs)))
        random.Random(a.seed + v * 7919).shuffle(order)
        buf = build(mono, segs, order, xf, n + seam)
        y = buf[:n].copy()
        t = np.linspace(0, np.pi / 2, seam)
        y[:seam] = buf[:seam] * np.sin(t) + buf[n:n + seam] * np.cos(t)
        voices.append((p, y))

    # one common gain so the performers keep their relative levels
    peak = max(np.abs(y).max() for _, y in voices)
    g = 0.5 / peak
    meta = []
    for v, (p, y) in enumerate(voices):
        f = f"voice{v + 1:02d}_{p}.wav"
        wavfile.write(os.path.join(a.out, f), sr, (y * g).astype(np.float32))
        meta.append({"file": f, "performer": p})
    json.dump({"sr": sr, "loop_s": a.loop, "voices": meta},
              open(os.path.join(a.out, "voices.json"), "w"), indent=1)
    print(f"wrote {len(voices)} voices x {a.loop:.0f}s to {a.out}")


if __name__ == "__main__":
    main()
