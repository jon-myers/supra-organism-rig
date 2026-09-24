#!/usr/bin/env python
"""Pitched breath -> harmonium voices for breath_pitched.scd.

Like breath_morph.py, but every one of the 20 voices morphs toward its OWN
harmonium pitch, drawn from the wall-of-sound dyads' pitch classes
(C, Eb, F, Bb; measured 2026-09-23 by spectral peaks + chroma over stems/)
across octaves 2-5. Each voice is its own FlowEdit render of its performer's
take (3 chunks each, reusing breath_morph.py's chunks), split across both GPU
servers. FlowEdit's prompt barely steers octave and the harmonium LoRA never
saw Eb or Bb; so this uses the harmonium-v2 spn_hz LoRA on 7894 instead, which
names note AND octave in its captions. One 35 s chunk per voice (20 renders).
No pitch shifting: assemble only reports each voice's strongest pitch.

    PY=../concatenator-corpus/.venv/bin/python
    $PY breath_morph.py chunk          # once (shared chunks)
    $PY breath_pitched.py plan && $PY breath_pitched.py render && $PY breath_pitched.py assemble
"""
import argparse, json, os, queue, random, subprocess, sys, threading, time
import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import breath_morph as bm  # noqa: E402
from breath_morph import read, segment, build, PERFORMERS, FE, SRC  # noqa: E402

WORK = os.path.join(HERE, "breath_pitched_work")
OUT = os.path.join(HERE, "breath_pitched_voices")
NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
PCS = {"C": 0, "Eb": 3, "F": 5, "Bb": 10}
# harmonium-v2 spn_hz LoRA on 7894 (trained on harmonium-notes-aug18, chromatic
# F2-A4; lands the NAMED octave 88-95 %, loras/ab/harmonium-v2-eval/README.md).
# The old v1 LoRA on 7888/7893 put a strong C5 under every named note.
# Prompt frame and pitch phrase are the eval's own (loras/scripts/eval_harmonium_v2.py).
SRC = ("A person breathing deeply and slowly, soft and controlled, close-miked, "
       "dry studio recording with gentle electronic hiss.")
FRAME = ("TrackType: Instrument, a solo harmonium playing a single note, held steadily at a "
         "moderate dynamic with a soft bellows attack and a clean release, on {pitch}, warm "
         "reedy free-reed timbre, stereo pair recording in a natural room.")
WORDS = {"C": "C", "Eb": "E-flat", "F": "F", "Bb": "B-flat"}
REG = {2: "low", 3: "middle", 4: "high", 5: "high"}
SERVERS = [("7894", "http://127.0.0.1:7894/generate",
            ["--src-lora-strengths", "1", "0", "0", "0", "0",
             "--tar-lora-strengths", "0", "0", "0", "0", "1"])]


def pitch_phrase(note):
    pc, o = note[:-1], int(note[-1])
    f = 440.0 * 2 ** ((NAMES.index(pc) + 12 * (o + 1) - 69) / 12)
    return f"{WORDS[pc]} in the {REG[o]} register ({pc}{o}, {f:.0f} Hz)"


def chunk_of(x):
    """one 35 s chunk per voice; a performer's voices rotate through its chunks"""
    return (x["voice"] - 1) // len(PERFORMERS) % 3


def midi_name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"


def cmd_plan(a):
    rng = random.Random(a.seed)
    pcs = list(PCS.items())
    octs = list(range(a.oct_lo, a.oct_hi + 1))
    # every pitch class 5x, octaves spread as evenly as 20 allows, then shuffled
    notes = []
    for k in range(a.voices):
        pc = pcs[k % len(pcs)]
        o = octs[(k // len(pcs)) % len(octs)]
        notes.append((pc, o))
    rng.shuffle(notes)
    voices = []
    for v, ((name, pc), o) in enumerate(notes):
        midi = 12 * (o + 1) + pc
        voices.append({"voice": v + 1, "performer": PERFORMERS[v % len(PERFORMERS)],
                       "note": f"{name}{o}", "midi": midi})
    os.makedirs(WORK, exist_ok=True)
    json.dump({"voices": voices}, open(os.path.join(WORK, "plan.json"), "w"), indent=1)
    for x in voices:
        print(f"voice {x['voice']:2d}  {x['performer']:8s} {x['note']}")


def cmd_render(a):
    plan = json.load(open(os.path.join(WORK, "plan.json")))["voices"]
    chunks = json.load(open(os.path.join(bm.WORK, "plan.json")))["plan"]
    q = queue.Queue()
    for x in plan:
        j = chunk_of(x)
        q.put((x, j, chunks[x["performer"]][j]))
    total = q.qsize()
    done = [0]
    lock = threading.Lock()
    fail = []

    def worker(name, url, extra):
        while not fail:
            try:
                x, j, c = q.get_nowait()
            except queue.Empty:
                return
            od = os.path.join(WORK, f"voice{x['voice']:02d}", f"chunk{j}_slots")
            if not (os.path.exists(os.path.join(od, "final.wav")) and not a.force):
                cmd = [sys.executable, os.path.join(FE, "sc_bridge.py"), "--audio", c["file"],
                       "--url", url, "--src", SRC, "--tar", FRAME.format(pitch=pitch_phrase(x["note"])),
                       "--lfe-steps", "20", "--num-intermediates", str(a.inter),
                       "--src-cfg", "1.0", "--tar-cfg", str(a.tar_cfg),
                       "--seed", str(a.seed + x["voice"]), "--output-dir", od,
                       "--out-dir", os.path.join(WORK, "archive")] + extra
                t0 = time.time()
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    print(f"FAILED voice{x['voice']} chunk{j} on {name}:\n{r.stdout[-800:]}\n{r.stderr[-800:]}",
                          flush=True)
                    fail.append(1)
                    return
                took = time.time() - t0
            else:
                took = 0
            with lock:
                done[0] += 1
                print(f"[{done[0]}/{total}] voice{x['voice']:02d} {x['note']} chunk{j} on {name} "
                      f"ok {took:.0f}s", flush=True)

    ts = [threading.Thread(target=worker, args=s) for s in SERVERS]
    [t.start() for t in ts]
    [t.join() for t in ts]
    if fail:
        sys.exit("render failed")
    print("RENDER_DONE")


def f0_midi(x, sr):
    import librosa
    y = librosa.resample(x[: sr * 30], orig_sr=sr, target_sr=22050)
    f0, vf, _ = librosa.pyin(y, fmin=55, fmax=1100, sr=22050, frame_length=4096)
    f0 = f0[vf & np.isfinite(f0)]
    if len(f0) < 20:
        return None
    return float(np.median(69 + 12 * np.log2(f0 / 440)))


def dominant_midi(x, sr):
    """strongest spectral peak 60-1200 Hz, as a fractional MIDI number. The
    renders carry a strong C5 drone whatever note is asked for, next to the
    requested one, which fools pyin's octave; the dominant peak is what the
    ear hears as 'the note'."""
    from scipy.signal import find_peaks
    y = x[: sr * 30]
    N = 2 ** int(np.log2(len(y)))
    X = np.abs(np.fft.rfft(y[:N] * np.hanning(N)))
    f = np.fft.rfftfreq(N, 1 / sr)
    b = (f > 60) & (f < 1200)
    k = int(np.argmax(X[b]))
    return float(69 + 12 * np.log2(f[b][k] / 440))


def plan_shift(target, got, cap=12.0):
    """pitch-class move in [-6, 6), then octaves toward the target, |total| <= cap"""
    pc = ((target - got + 6) % 12) - 6
    semis = pc
    while abs(target - (got + semis)) >= 12 and abs(semis + np.sign(target - got - semis) * 12) <= cap:
        semis += np.sign(target - got - semis) * 12
    return float(semis)


def shift(x, sr, semis, tmp):
    if abs(semis) < 0.05:
        return x
    i, o = tmp + "_in.wav", tmp + "_out.wav"
    wavfile.write(i, sr, x.astype(np.float32))
    subprocess.run(["rubberband", "-q", "-t", "1", "-p", f"{semis:.3f}", "--fine", i, o],
                   check=True, capture_output=True)
    _, y = read(o)
    y = y.mean(axis=1) if y.ndim > 1 else y
    y = np.pad(y, (0, max(0, len(x) - len(y))))[: len(x)]
    os.remove(i); os.remove(o)
    return y


def cmd_assemble(a):
    plan = json.load(open(os.path.join(WORK, "plan.json")))["voices"]
    cm = json.load(open(os.path.join(bm.WORK, "plan.json")))
    sr, chunks = cm["sr"], cm["plan"]
    OUTD = OUT
    os.makedirs(OUTD, exist_ok=True)
    n = int(a.loop * sr); seam = int(0.4 * sr); xf = int(0.06 * sr)
    report, voices = [], []
    for x in plan:
        p = x["performer"]
        j = chunk_of(x)
        vdir = os.path.join(WORK, f"voice{x['voice']:02d}")
        od = os.path.join(vdir, f"chunk{j}_slots")
        if not os.path.exists(os.path.join(od, "final.wav")):
            print(f"voice {x['voice']:2d} not rendered yet -- skipped", flush=True)
            continue
        files, labs = bm.slot_list(od)
        _, y = read(chunks[p][j]["file"])
        src = y.mean(axis=1) if y.ndim > 1 else y[:, 0]
        segs = segment(src[:, None], sr, None, 120.0, 250.0)
        slots = [src]
        for f in files:
            _, z = read(os.path.join(od, f))
            z = z.mean(axis=1)
            slots.append(np.pad(z, (0, max(0, len(src) - len(z))))[: len(src)])
        names = ["source"] + labs
        cand = [k for k in range(1, len(names)) if names[k] != "final"]
        pick = np.unique(np.round(np.linspace(0, len(cand) - 1,
                                              min(a.max_slots - 1, len(cand)))).astype(int))
        keep = [0] + [cand[i] for i in pick]
        got = dominant_midi(slots[keep[-1]], sr)
        line = (f"voice {x['voice']:2d} {p:8s} chunk{j} target {x['note']:4s}  "
                f"strongest pitch {midi_name(int(round(got)))} ({got:.2f})")
        print(line, flush=True); report.append(line)
        order = list(range(len(segs)))
        random.Random(a.seed + (x["voice"] - 1) * 7919).shuffle(order)
        vs = []
        for k in keep:
            buf = build(slots[k], segs, order, xf, n + seam)
            yv = buf[:n].copy()
            t = np.linspace(0, np.pi / 2, seam)
            yv[:seam] = buf[:seam] * np.sin(t) + buf[n:n + seam] * np.cos(t)
            vs.append(yv)
        voices.append((x, vs, [names[k] for k in keep]))
    ns = len(voices[0][1])
    ref = np.mean([np.sqrt((vs[0] ** 2).mean()) for _, vs, _ in voices])
    gains = [ref / max(np.mean([np.sqrt((vs[si] ** 2).mean()) for _, vs, _ in voices]), 1e-9)
             for si in range(ns)]
    peak = max(np.abs(yv * g).max() for _, vs, _ in voices for yv, g in zip(vs, gains))
    G = 0.5 / peak
    meta = []
    for x, vs, labs in voices:
        fl = []
        for si, (yv, g) in enumerate(zip(vs, gains)):
            f = f"voice{x['voice']:02d}_{x['performer']}_{x['note']}_slot{si:02d}.wav"
            wavfile.write(os.path.join(OUTD, f), sr, (yv * g * G).astype(np.float32))
            fl.append(f)
        meta.append({"performer": x["performer"], "note": x["note"], "files": fl})
    json.dump({"sr": sr, "loop_s": a.loop, "slots": voices[0][2], "voices": meta},
              open(os.path.join(OUTD, "voices.json"), "w"), indent=1)
    open(os.path.join(OUTD, "pitch_report.txt"), "w").write("\n".join(report) + "\n")
    print(f"ASSEMBLE_DONE: {len(voices)} voices x {ns} slots -> {OUTD}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("plan")
    pl.add_argument("--voices", type=int, default=20)
    pl.add_argument("--oct-lo", type=int, default=2)
    pl.add_argument("--oct-hi", type=int, default=5)
    pl.add_argument("--seed", type=int, default=23)
    r = sub.add_parser("render")
    r.add_argument("--inter", type=int, default=10)
    r.add_argument("--tar-cfg", type=float, default=5.0)   # the v2 eval's recipe
    r.add_argument("--seed", type=int, default=4242)
    r.add_argument("--force", action="store_true")
    s = sub.add_parser("assemble")
    s.add_argument("--loop", type=float, default=120.0)
    s.add_argument("--seed", type=int, default=21)
    s.add_argument("--max-slots", type=int, default=8)
    a = ap.parse_args()
    {"plan": cmd_plan, "render": cmd_render, "assemble": cmd_assemble}[a.cmd](a)


if __name__ == "__main__":
    main()
