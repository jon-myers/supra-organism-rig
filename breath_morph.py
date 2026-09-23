#!/usr/bin/env python
"""Breath -> harmonium morph voices for breath_morph.scd.

  chunk     cut each breathing_2 take into ~35 s chunks at breath gaps (local)
  render    FlowEdit every chunk on the GPU server (needs the CSAIL tunnel)
  assemble  stitch chunk slots back to full length, then rebuild the 20
            collage voices from EVERY slot with the same cuts and orders as
            render_breath_voices.py, so each voice can crossfade breath ->
            harmonium sample-locked (local)

    PY=../concatenator-corpus/.venv/bin/python
    $PY breath_morph.py chunk && $PY breath_morph.py render && $PY breath_morph.py assemble

FlowEdit preserves timing (slot envelopes track the source at zero lag), which
is what makes one segmentation valid for every slot. Chunks stay under the
45 s conditioning cap (seconds_total pins at 47 s).
"""
import argparse, json, os, random, subprocess, sys, time
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
SO = os.path.dirname(HERE)
FE = os.path.join(SO, "sa-flowedit")
sys.path.insert(0, FE)
sys.path.insert(0, HERE)
from chorus_slots import read, segment  # noqa: E402
from render_breath_voices import build, PERFORMERS  # noqa: E402

WORK = os.path.join(HERE, "breath_morph_work")
OUT = os.path.join(HERE, "breath_morph_voices")
SRC = ("A person breathing deeply and slowly, soft and controlled, close-miked, "
       "dry studio recording.")
TAR = ("TrackType: Instrument, a solo harmonium sustaining a warm reedy drone, "
       "hand-pumped free-reed timbre with breath-controlled swells, stereo pair "
       "recording in a natural room.")


def take(p):
    return os.path.join(FE, "input_audio", "defaults", f"breathing_2__{p}.wav")


def cmd_chunk(a):
    plan = {}
    for p in PERFORMERS:
        sr, y = read(take(p))
        mono = y.mean(axis=1)
        segs = segment(y, sr, None, 120.0, 250.0)
        cuts = [s[0] for s in segs[1:]]
        n = len(mono)
        k = int(np.ceil(n / sr / a.max_chunk))
        bounds = [0]
        for j in range(1, k):
            target = j * n // k
            bounds.append(min(cuts, key=lambda c: abs(c - target)))
        bounds.append(n)
        d = os.path.join(WORK, p)
        os.makedirs(d, exist_ok=True)
        plan[p] = []
        for j in range(k):
            a0, b0 = bounds[j], bounds[j + 1]
            f = os.path.join(d, f"chunk{j}.wav")
            wavfile.write(f, sr, (np.clip(mono[a0:b0], -1, 1) * 32767).astype(np.int16))
            plan[p].append({"file": f, "start": a0, "end": b0})
            print(f"{p} chunk{j}: {(b0 - a0) / sr:.1f}s")
    json.dump({"sr": sr, "plan": plan}, open(os.path.join(WORK, "plan.json"), "w"), indent=1)


def cmd_render(a):
    plan = json.load(open(os.path.join(WORK, "plan.json")))["plan"]
    jobs = [(p, j, c) for p in PERFORMERS for j, c in enumerate(plan[p])]
    for n, (p, j, c) in enumerate(jobs, 1):
        od = os.path.join(WORK, p, f"chunk{j}_slots")
        if os.path.exists(os.path.join(od, "final.wav")) and not a.force:
            print(f"[{n}/{len(jobs)}] {p} chunk{j}: done already")
            continue
        cmd = [sys.executable, os.path.join(FE, "sc_bridge.py"), "--audio", c["file"],
               "--url", a.url, "--src", SRC, "--tar", TAR,
               "--lfe-steps", "20", "--num-intermediates", str(a.inter),
               "--src-cfg", "1.0", "--tar-cfg", str(a.tar_cfg),
               "--seed", str(a.seed), "--output-dir", od,
               "--out-dir", os.path.join(WORK, "archive")]
        t0 = time.time()
        print(f"[{n}/{len(jobs)}] {p} chunk{j} ...", flush=True)
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout[-1500:], r.stderr[-1500:])
            sys.exit(f"render failed: {p} chunk{j}")
        print(f"    ok in {time.time() - t0:.0f}s", flush=True)
    print("RENDER_DONE")


def slot_list(od):
    m = json.load(open(os.path.join(od, "manifest.json")))
    lab = {s["file"]: s["label"] for s in m["slots"]}
    files = sorted(f for f in os.listdir(od) if f.startswith("inter_")) + ["final.wav"]
    return files, [lab.get(f, "final") for f in files]


def cmd_assemble(a):
    meta = json.load(open(os.path.join(WORK, "plan.json")))
    sr, plan = meta["sr"], meta["plan"]
    full = {}
    labels = None
    for p in PERFORMERS:
        files, labs = slot_list(os.path.join(WORK, p, "chunk0_slots"))
        labels = labs
        _, y = read(take(p))
        src_mono = y.mean(axis=1)
        slots = [src_mono]
        for f in files:
            parts = []
            for j, c in enumerate(plan[p]):
                fsr, z = read(os.path.join(WORK, p, f"chunk{j}_slots", f))
                assert fsr == sr, (fsr, sr)
                z = z.mean(axis=1)
                want = c["end"] - c["start"]
                z = np.pad(z, (0, max(0, want - len(z))))[:want]
                parts.append(z)
            # short equal-power crossfade across each chunk join
            out = parts[0]
            xf = int(0.03 * sr)
            for z in parts[1:]:
                t = np.linspace(0, np.pi / 2, xf)
                out = out.copy()
                out[-xf:] = out[-xf:] * np.cos(t) + z[:xf] * np.sin(t)
                out = np.concatenate([out, z[xf:]])
                out = np.pad(out, (0, xf))[:len(out)]
            slots.append(np.pad(out, (0, max(0, len(src_mono) - len(out))))[:len(src_mono)])
        full[p] = (slots, segment(y, sr, None, 120.0, 250.0))

    # order the slots breath -> harmonium by spectral centroid, keep only the
    # monotone run from the source to the darkest (fullest-harmonium) slot:
    # past that FlowEdit drifts back toward the source (t is edit strength)
    def centroid(x):
        X = np.abs(np.fft.rfft(x[: sr * 30]))
        f = np.fft.rfftfreq(min(len(x), sr * 30), 1 / sr)
        return float((X * f).sum() / max(X.sum(), 1e-9))
    names = ["source"] + labels
    cents = np.mean([[centroid(s) for s in full[p][0]] for p in PERFORMERS], axis=0)
    rms = np.mean([[20 * np.log10(np.sqrt((s ** 2).mean()) + 1e-12) for s in full[p][0]]
                   for p in PERFORMERS], axis=0)
    for nm, c, r in zip(names, cents, rms):
        print(f"  {nm:8s} centroid {c:7.0f} Hz  rms {r:6.1f} dB")
    darkest = int(np.argmin(cents[1:])) + 1
    # candidates: every step from brightest (nearest the breath) to the darkest,
    # dropping "final" when it duplicates the last intermediate
    cand = sorted((k for k in range(1, len(names))
                   if cents[k] >= cents[darkest] and not
                   (names[k] == "final" and any(abs(cents[k] - cents[j]) < 1
                                                for j in range(1, k)))),
                  key=lambda k: -cents[k])
    # the source, then evenly spaced steps ending exactly on the darkest
    pick = np.unique(np.round(np.linspace(0, len(cand) - 1,
                                          min(a.max_slots - 1, len(cand)))).astype(int))
    keep = [0] + [cand[i] for i in pick]
    print("  kept slots:", [names[k] for k in keep])

    os.makedirs(OUT, exist_ok=True)
    n = int(a.loop * sr)
    seam = int(0.4 * sr)
    xf = int(0.06 * sr)
    voices = []
    for v in range(a.voices):
        p = PERFORMERS[v % len(PERFORMERS)]
        slots, segs = full[p]
        order = list(range(len(segs)))
        random.Random(a.seed + v * 7919).shuffle(order)
        vs = []
        for k in keep:
            buf = build(slots[k], segs, order, xf, n + seam)
            y = buf[:n].copy()
            t = np.linspace(0, np.pi / 2, seam)
            y[:seam] = buf[:seam] * np.sin(t) + buf[n:n + seam] * np.cos(t)
            vs.append(y)
        voices.append((p, vs))
    # loudness-match each slot level to the source level per voice set (RMS),
    # so the morph slider changes timbre, not volume
    ref = np.mean([np.sqrt((vs[0] ** 2).mean()) for _, vs in voices])
    gains = []
    for si in range(len(keep)):
        lvl = np.mean([np.sqrt((vs[si] ** 2).mean()) for _, vs in voices])
        gains.append(ref / max(lvl, 1e-9))
    peak = max(np.abs(y * g).max() for _, vs in voices for y, g in zip(vs, gains))
    G = 0.5 / peak
    meta_v = []
    for v, (p, vs) in enumerate(voices):
        files = []
        for si, (y, g) in enumerate(zip(vs, gains)):
            f = f"voice{v + 1:02d}_{p}_slot{si:02d}.wav"
            wavfile.write(os.path.join(OUT, f), sr, (y * g * G).astype(np.float32))
            files.append(f)
        meta_v.append({"performer": p, "files": files})
    json.dump({"sr": sr, "loop_s": a.loop, "slots": [names[k] for k in keep],
               "voices": meta_v}, open(os.path.join(OUT, "voices.json"), "w"), indent=1)
    print(f"ASSEMBLE_DONE: {a.voices} voices x {len(keep)} slots x {a.loop:.0f}s -> {OUT}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("chunk"); c.add_argument("--max-chunk", type=float, default=36.0)
    r = sub.add_parser("render")
    r.add_argument("--url", default="http://127.0.0.1:7893/generate")
    r.add_argument("--inter", type=int, default=10)
    r.add_argument("--tar-cfg", type=float, default=5.0)
    r.add_argument("--seed", type=int, default=4242)
    r.add_argument("--force", action="store_true")
    s = sub.add_parser("assemble")
    s.add_argument("--voices", type=int, default=20)
    s.add_argument("--loop", type=float, default=120.0)
    s.add_argument("--seed", type=int, default=21)   # same as render_breath_voices
    s.add_argument("--max-slots", type=int, default=8)
    a = ap.parse_args()
    {"chunk": cmd_chunk, "render": cmd_render, "assemble": cmd_assemble}[a.cmd](a)


if __name__ == "__main__":
    main()
