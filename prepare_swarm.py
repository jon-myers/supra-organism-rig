#!/usr/bin/env python
"""Prepare the renders for breath_swarm.scd (live collage, 1-216+ voices).

breath_pitched_voices/ bakes each voice as a 120 s collage, so memory grows with
the voice count (216 voices ~ 36 GB). The swarm instead keeps each FlowEdit
render ONCE (one 35 s breath chunk x 8 morph steps) plus its segment list, and
SuperCollider does the collage live: every voice plays segments of one render in
its own endlessly reshuffled order. No loops, so nothing ever realigns, and any
number of voices can share the 20 renders.

Reads breath_pitched_work/ (renders from breath_pitched.py). Writes
swarm_renders/: rNN_slotK.wav (mono float, loudness-matched per step) + swarm.json.

    ../concatenator-corpus/.venv/bin/python prepare_swarm.py
"""
import json, os, sys
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import breath_morph as bm  # noqa: E402
import breath_pitched as bp  # noqa: E402
from breath_morph import read, segment  # noqa: E402

OUT = os.path.join(HERE, "swarm_renders")


def main(max_slots=8):
    plan = json.load(open(os.path.join(bp.WORK, "plan.json")))["voices"]
    chunks = json.load(open(os.path.join(bm.WORK, "plan.json")))["plan"]
    os.makedirs(OUT, exist_ok=True)
    renders = []
    for x in plan:
        j = bp.chunk_of(x)
        od = os.path.join(bp.WORK, f"voice{x['voice']:02d}", f"chunk{j}_slots")
        if not os.path.exists(os.path.join(od, "final.wav")):
            print(f"voice {x['voice']} not rendered -- skipped")
            continue
        files, labs = bm.slot_list(od)
        sr, y = read(chunks[x["performer"]][j]["file"])
        src = y[:, 0] if y.ndim > 1 else y
        slots = [src]
        for f in files:
            _, z = read(os.path.join(od, f))
            z = z.mean(axis=1)
            slots.append(np.pad(z, (0, max(0, len(src) - len(z))))[: len(src)])
        names = ["source"] + labs
        cand = [k for k in range(1, len(names)) if names[k] != "final"]
        pick = np.unique(np.round(np.linspace(0, len(cand) - 1,
                                              min(max_slots - 1, len(cand)))).astype(int))
        keep = [0] + [cand[i] for i in pick]
        segs = segment(src[:, None], sr, None, 120.0, 250.0)
        renders.append({"x": x, "slots": [slots[k] for k in keep], "segs": segs, "sr": sr})
        print(f"render {len(renders):2d}: voice{x['voice']:02d} {x['performer']:8s} {x['note']:4s} "
              f"{len(src) / sr:.1f}s {len(segs)} segments")
    ns = len(renders[0]["slots"])
    ref = np.mean([np.sqrt((r["slots"][0] ** 2).mean()) for r in renders])
    gains = [ref / max(np.mean([np.sqrt((r["slots"][k] ** 2).mean()) for r in renders]), 1e-9)
             for k in range(ns)]
    peak = max(np.abs(r["slots"][k] * gains[k]).max() for r in renders for k in range(ns))
    G = 0.5 / peak
    meta = []
    for i, r in enumerate(renders):
        fl = []
        for k in range(ns):
            f = f"r{i + 1:02d}_{r['x']['performer']}_{r['x']['note']}_slot{k}.wav"
            wavfile.write(os.path.join(OUT, f), r["sr"], (r["slots"][k] * gains[k] * G).astype(np.float32))
            fl.append(f)
        meta.append({"performer": r["x"]["performer"], "note": r["x"]["note"], "files": fl,
                     "segments": [[a / r["sr"], b / r["sr"]] for a, b in r["segs"]]})
    json.dump({"slots": ns, "renders": meta}, open(os.path.join(OUT, "swarm.json"), "w"), indent=1)
    print(f"SWARM_READY: {len(meta)} renders x {ns} steps -> {OUT}")


if __name__ == "__main__":
    main()
