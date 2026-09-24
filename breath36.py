#!/usr/bin/env python
"""36 individual breaths -> pitched harmonium, each its own loop (breath36.scd).

Every voice is a DIFFERENT stretch of real breathing: the 8 pure-breath takes of
July 23 (breathing_1 88 s, breathing_2 104 s; anna, grisha, raymond, sora) cut at
breath gaps into 36 pieces of ~21 s (4 + 5 per performer and take pair = 9 per
performer). No voice shares material with another. Each voice's loop is built
only from its own piece -- its breath segments in a shuffled order -- to its own
length between 120 and 160 s (no two within 0.5 s), so the voices phase against
each other and never realign. (36 unique 2-minute phrases would need ~72 min of
breath; the takes hold ~13.)

Each piece is FlowEdit-rendered (harmonium-v2 spn_hz LoRA on 7894) toward its own
pitch: C, Eb, F, Bb (wall-of-sound dyads) x octaves 2-5, 9 voices per pitch class.

    PY=../concatenator-corpus/.venv/bin/python
    $PY breath36.py plan && $PY breath36.py render && $PY breath36.py assemble
"""
import argparse, json, os, random, subprocess, sys, threading, time
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import breath_morph as bm  # noqa: E402
import breath_pitched as bp  # noqa: E402
from breath_morph import read, segment, FE  # noqa: E402
from render_breath_voices import build  # noqa: E402

ARCH = "/Users/jon/Documents/2026/MIT/projects/audio-archive/July 23/July 23"
TAKES = [("1. breathing_1", 4), ("2. breathing_2", 5)]   # (take folder, pieces per performer)
PERF = ["Anna", "Grisha", "Raymond", "Sora"]
WORK = os.path.join(HERE, "breath36_work")
OUT = os.path.join(HERE, "breath36_voices")
MIN_GAP_S = 0.25
SEAM_S = 0.3


def cmd_plan(a):
    os.makedirs(WORK, exist_ok=True)
    pieces = []
    for p in PERF:
        for take, k in TAKES:
            sr, y = read(os.path.join(ARCH, take, f"{p}.wav"))
            mono = y.mean(axis=1)
            segs = segment(y, sr, None, 120.0, 250.0)
            gaps = [s[0] for s in segs[1:]]          # cut points sit in breath gaps
            n = len(mono)
            bounds = [0] + [min(gaps, key=lambda c: abs(c - j * n // k)) for j in range(1, k)] + [n]
            for j in range(k):
                a0, b0 = bounds[j], bounds[j + 1]
                pieces.append({"performer": p.lower(), "take": take, "start": a0, "end": b0, "sr": sr})
    # no two loop lengths within MIN_GAP_S: nudge an end cut to the next gap if needed
    lens = sorted(((x["end"] - x["start"]) / x["sr"], i) for i, x in enumerate(pieces))
    for (l1, i1), (l2, i2) in zip(lens, lens[1:]):
        if l2 - l1 < MIN_GAP_S:
            x = pieces[i2]
            x["end"] = max(x["start"] + int((l1 + MIN_GAP_S + 0.05) * x["sr"]), x["end"])
    assert len(pieces) == 36, len(pieces)
    rng = random.Random(a.seed)
    notes = [(pc, o) for o in range(2, 6) for pc in ["C", "Eb", "F", "Bb"]]   # 16 combos
    notes = (notes * 3)[:36]           # each pc 9x, octaves spread
    rng.shuffle(notes)
    for i, (x, (pc, o)) in enumerate(zip(pieces, notes)):
        x.update(voice=i + 1, note=f"{pc}{o}",
                 midi=12 * (o + 1) + bp.NAMES.index(pc))
        f = os.path.join(WORK, f"v{i + 1:02d}_src.wav")
        sr, y = read(os.path.join(ARCH, x["take"], f"{x['performer'].capitalize()}.wav"))
        seg = np.clip(y.mean(axis=1)[x["start"]:x["end"]], -1, 1)
        wavfile.write(f, sr, (seg * 32767).astype(np.int16))
        x["file"] = f
        x["seconds"] = round((x["end"] - x["start"]) / sr, 3)
        print(f"v{i + 1:02d} {x['performer']:8s} {x['take'][3:]:12s} {x['seconds']:6.2f}s -> {x['note']}")
    json.dump({"voices": pieces}, open(os.path.join(WORK, "plan.json"), "w"), indent=1)
    L = sorted(x["seconds"] for x in pieces)
    print(f"lengths {L[0]:.2f}-{L[-1]:.2f}s, min spacing {min(b - a for a, b in zip(L, L[1:])):.3f}s")


def cmd_render(a):
    plan = json.load(open(os.path.join(WORK, "plan.json")))["voices"]
    name, url, extra = bp.SERVERS[0]
    for n, x in enumerate(plan, 1):
        od = os.path.join(WORK, f"v{x['voice']:02d}_slots")
        if os.path.exists(os.path.join(od, "final.wav")) and not a.force:
            print(f"[{n}/36] v{x['voice']:02d} done already", flush=True); continue
        cmd = [sys.executable, os.path.join(FE, "sc_bridge.py"), "--audio", x["file"], "--url", url,
               "--src", bp.SRC, "--tar", bp.FRAME.format(pitch=bp.pitch_phrase(x["note"])),
               "--lfe-steps", "20", "--num-intermediates", "10", "--src-cfg", "1.0",
               "--tar-cfg", "5.0", "--seed", str(4242 + x["voice"]), "--output-dir", od,
               "--out-dir", os.path.join(WORK, "archive")] + extra
        t0 = time.time()
        for attempt in range(3):      # a dropped download is retried; a dead tunnel is not
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode == 0: break
            if "Connection refused" in r.stdout + r.stderr or "timed out" in r.stdout + r.stderr:
                sys.exit(f"server unreachable (tunnel down?) at v{x['voice']:02d} -- run fleet up, then rerun")
            time.sleep(5)
        else:
            print(r.stdout[-800:], r.stderr[-800:]); sys.exit(f"render failed v{x['voice']:02d}")
        print(f"[{n}/36] v{x['voice']:02d} {x['note']} ok {time.time() - t0:.0f}s", flush=True)
    print("RENDER_DONE")


def cmd_assemble(a):
    plan = json.load(open(os.path.join(WORK, "plan.json")))["voices"]
    os.makedirs(OUT, exist_ok=True)
    # every voice its own loop length, LOOP_MIN..LOOP_MAX s, at least 0.5 s apart
    rng = random.Random(360)
    lens = []
    while len(lens) < len(plan):
        L = round(rng.uniform(a.loop_min, a.loop_max), 2)
        if all(abs(L - q) >= 0.5 for q in lens):
            lens.append(L)
    loop_len = {x["voice"]: L for x, L in zip(plan, lens)}
    voices = []
    for x in plan:
        od = os.path.join(WORK, f"v{x['voice']:02d}_slots")
        if not os.path.exists(os.path.join(od, "final.wav")):
            print(f"v{x['voice']:02d} not rendered -- skipped"); continue
        files, labs = bm.slot_list(od)
        sr, y = read(x["file"]); src = y[:, 0] if y.ndim > 1 else y
        slots = [src]
        for f in files:
            _, z = read(os.path.join(od, f)); z = z.mean(axis=1)
            slots.append(np.pad(z, (0, max(0, len(src) - len(z))))[: len(src)])
        names = ["source"] + labs
        cand = [k for k in range(1, len(names)) if names[k] != "final"]
        pick = np.unique(np.round(np.linspace(0, len(cand) - 1, 7)).astype(int))
        keep = [0] + [cand[i] for i in pick]
        # A long loop made ONLY of this voice's own ~21 s: its breath segments in a
        # shuffled order (one order shared by all 8 morph steps, so they stay
        # sample-aligned), cycled to this voice's own loop length, seam folded.
        segs = segment(src[:, None], sr, None, 120.0, 250.0)
        order = list(range(len(segs)))
        random.Random(4242 + x["voice"]).shuffle(order)
        n = int(loop_len[x["voice"]] * sr); m = int(SEAM_S * sr); t = np.linspace(0, np.pi / 2, m)
        vs = []
        for k in keep:
            buf = build(slots[k], segs, order, int(0.06 * sr), n + m)
            yv = buf[:n].copy()
            yv[:m] = buf[:m] * np.sin(t) + buf[n:n + m] * np.cos(t)
            vs.append(yv)
        voices.append((x, vs))
    ns = len(voices[0][1])
    ref = np.mean([np.sqrt((vs[0] ** 2).mean()) for _, vs in voices])
    gains = [ref / max(np.mean([np.sqrt((vs[k] ** 2).mean()) for _, vs in voices]), 1e-9) for k in range(ns)]
    peak = max(np.abs(vs[k] * gains[k]).max() for _, vs in voices for k in range(ns))
    G = 0.5 / peak
    meta = []
    for x, vs in voices:
        fl = []
        for k in range(ns):
            f = f"v{x['voice']:02d}_{x['performer']}_{x['note']}_slot{k}.wav"
            wavfile.write(os.path.join(OUT, f), sr, (vs[k] * gains[k] * G).astype(np.float32)); fl.append(f)
        meta.append({"voice": x["voice"], "performer": x["performer"], "take": x["take"],
                     "note": x["note"], "seconds": round(len(vs[0]) / sr, 3), "files": fl})
    json.dump({"slots": ["source"] + [f"step{k}" for k in range(1, ns)], "voices": meta}, open(os.path.join(OUT, "voices.json"), "w"), indent=1)
    print(f"ASSEMBLE_DONE: {len(meta)} voices x {ns} steps -> {OUT}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("plan"); pl.add_argument("--seed", type=int, default=36)
    r = sub.add_parser("render"); r.add_argument("--force", action="store_true")
    s_ = sub.add_parser("assemble")
    s_.add_argument("--loop-min", type=float, default=120.0)
    s_.add_argument("--loop-max", type=float, default=160.0)
    a = ap.parse_args()
    {"plan": cmd_plan, "render": cmd_render, "assemble": cmd_assemble}[a.cmd](a)


if __name__ == "__main__":
    main()
