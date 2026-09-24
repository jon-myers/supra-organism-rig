#!/usr/bin/env python
"""Does FlowEdit's lfe_steps change the breath -> harmonium render?

One 12 s breath clip (../../prompt_test/clip12s.wav), breath_pitched.py's exact
recipe and prompt (F3, harmonium-v2 spn_hz on 7894, src 1 / tar 5, n_avg 10,
10 even-step intermediates), varying only lfe_steps over 10/20/40/80 at 3 seeds.
Plus one control arm, steps 10 x n_avg 20: the same number of noise draws as
steps 20 x n_avg 10, so it separates "finer time grid" from "more averaging".

    PY=../../../concatenator-corpus/.venv/bin/python
    $PY run.py render      # skips finished renders; needs 127.0.0.1:7894
    $PY run.py analyze     # -> results.csv, distances.csv, printed summary
    $PY run.py listen      # -> LISTEN/ same-seed A/Bs
"""
import argparse, csv, itertools, json, os, shutil, subprocess, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RIG = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, RIG)
import breath_pitched as bp  # noqa: E402

CLIP = os.path.join(RIG, "prompt_test", "clip12s.wav")
WORK = os.path.join(HERE, "renders")
NOTE = "F3"
STEPS = [10, 20, 40, 80]
SEEDS = [101, 202, 303]
# (label, lfe_steps, n_avg)
ARMS = [(f"s{s:02d}", s, 10) for s in STEPS] + [("s10_avg20", 10, 20)]


def odir(arm, seed):
    return os.path.join(WORK, f"{arm}_seed{seed}")


def cmd_render(a):
    name, url, extra = bp.SERVERS[0]
    tar = bp.FRAME.format(pitch=bp.pitch_phrase(NOTE))
    jobs = [(arm, st, na, seed) for seed in SEEDS for arm, st, na in ARMS]
    for i, (arm, st, na, seed) in enumerate(jobs, 1):
        od = odir(arm, seed)
        if os.path.exists(os.path.join(od, "final.wav")) and not a.force:
            continue
        cmd = [sys.executable, os.path.join(bp.FE, "sc_bridge.py"), "--audio", CLIP,
               "--url", url, "--src", bp.SRC, "--tar", tar,
               "--lfe-steps", str(st), "--n-avg", str(na), "--num-intermediates", "10",
               "--src-cfg", "1.0", "--tar-cfg", "5.0", "--seed", str(seed),
               "--output-dir", od, "--out-dir", os.path.join(WORK, "archive"),
               "--client", "lfe-steps-exp"] + extra
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True)
        took = time.time() - t0
        if r.returncode != 0:
            sys.exit(f"FAILED {arm} seed{seed}:\n{r.stdout[-800:]}\n{r.stderr[-800:]}")
        json.dump({"arm": arm, "lfe_steps": st, "n_avg": na, "seed": seed, "wall_s": round(took, 1)},
                  open(os.path.join(od, "timing.json"), "w"))
        print(f"[{i}/{len(jobs)}] {arm} seed{seed} {took:.0f}s", flush=True)
    print("RENDER_DONE")


# ---------------------------------------------------------------- analysis

def load(p, sr=44100):
    import librosa
    y, _ = librosa.load(p, sr=sr, mono=True)
    return y


def f0_frame(x, sr, lo=60, hi=1200):
    """copied from sa-flowedit/loras/scripts/eval_harmonium_v2.py"""
    x = x - x.mean()
    if np.sqrt((x ** 2).mean()) < 1e-3: return None
    ac = np.correlate(x, x, "full")[len(x) - 1:]
    if ac[0] <= 0: return None
    lag_lo, lag_hi = int(sr / hi), int(sr / lo)
    peak = lag_lo + int(np.argmax(ac[lag_lo:lag_hi]))
    if ac[peak] / ac[0] < 0.3: return None
    return sr / peak


def f3_stats(y, sr):
    """the harmonium-v2 eval's octave metric: % voiced frames within 250 c of F3"""
    target = 440.0 * 2 ** ((53 - 69) / 12)  # F3 = MIDI 53
    N, H = int(0.09 * sr), int(0.045 * sr)
    f0s = np.array([f for f in (f0_frame(y[i:i + N].astype(np.float64), sr)
                                for i in range(0, len(y) - N, H)) if f])
    if not len(f0s):
        return dict(voiced=0, on_f3=0.0, median_cents=np.nan, cents_sd=np.nan)
    c = 1200 * np.log2(f0s / target)
    return dict(voiced=len(f0s), on_f3=float(np.mean(np.abs(c) < 250) * 100),
                median_cents=float(np.median(c)), cents_sd=float(np.std(c[np.abs(c) < 250]))
                if np.any(np.abs(c) < 250) else np.nan)


def env(y, sr, hop=0.05):
    h = int(hop * sr)
    n = len(y) // h
    return np.sqrt((y[: n * h].reshape(n, h) ** 2).mean(axis=1))


def logmel(y, sr):
    import librosa
    m = librosa.feature.melspectrogram(y=y, sr=sr, n_fft=2048, hop_length=512, n_mels=96)
    return librosa.power_to_db(m, ref=1.0, top_db=None)


def metrics(y, src, sr):
    import librosa
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=512))
    H, P = librosa.decompose.hpss(S)
    cen = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
    w = S.sum(axis=0)
    e, es = env(y, sr), env(src, sr)
    n = min(len(e), len(es))
    # energy above 4 kHz: where breath hiss lives and a harmonium has little
    f = librosa.fft_frequencies(sr=sr, n_fft=2048)
    hf = float((S[f > 4000] ** 2).sum() / (S ** 2).sum() * 100)
    return dict(centroid_hz=float((cen * w).sum() / w.sum()),
                harmonic_pct=float((H ** 2).sum() / ((H ** 2).sum() + (P ** 2).sum()) * 100),
                hf_pct=hf, env_corr=float(np.corrcoef(e[:n], es[:n])[0, 1]),
                rms_db=float(20 * np.log10(np.sqrt((y ** 2).mean()) + 1e-12)))


def cmd_analyze(a):
    sr = 44100
    src = load(CLIP, sr)
    rows, mels = [], {}
    for seed in SEEDS:
        for arm, st, na in ARMS:
            od = odir(arm, seed)
            fp = os.path.join(od, "final.wav")
            if not os.path.exists(fp):
                print(f"missing {arm} seed{seed}")
                continue
            y = load(fp, sr)
            n = min(len(y), len(src)); y = y[:n]
            r = dict(arm=arm, lfe_steps=st, n_avg=na, seed=seed)
            t = json.load(open(os.path.join(od, "timing.json"))) if os.path.exists(
                os.path.join(od, "timing.json")) else {}
            r["wall_s"] = t.get("wall_s", np.nan)
            r.update(f3_stats(y, sr)); r.update(metrics(y, src[:n], sr))
            rows.append(r); mels[(arm, seed)] = logmel(y, sr)
    with open(os.path.join(HERE, "results.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

    def d(k1, k2):
        A, B = mels[k1], mels[k2]; n = min(A.shape[1], B.shape[1])
        return float(np.mean(np.abs(A[:, :n] - B[:, :n])))

    # the yardstick: how far apart two seeds of the SAME recipe are
    drows = []
    for arm, _, _ in ARMS:
        for s1, s2 in itertools.combinations(SEEDS, 2):
            if (arm, s1) in mels and (arm, s2) in mels:
                drows.append(dict(kind="seed-vs-seed", a=f"{arm}/{s1}", b=f"{arm}/{s2}", dB=d((arm, s1), (arm, s2))))
    for seed in SEEDS:
        for (a1, _, _), (a2, _, _) in itertools.combinations(ARMS, 2):
            if (a1, seed) in mels and (a2, seed) in mels:
                drows.append(dict(kind="arm-vs-arm", a=f"{a1}/{seed}", b=f"{a2}/{seed}", dB=d((a1, seed), (a2, seed))))
    with open(os.path.join(HERE, "distances.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["kind", "a", "b", "dB"]); w.writeheader(); w.writerows(drows)

    keys = ["wall_s", "on_f3", "median_cents", "cents_sd", "centroid_hz", "harmonic_pct", "hf_pct", "env_corr", "rms_db"]
    print("\nmean (sd) over seeds")
    print("arm        " + " ".join(f"{k:>13s}" for k in keys))
    for arm, _, _ in ARMS:
        rr = [r for r in rows if r["arm"] == arm]
        if not rr:
            continue
        cells = []
        for k in keys:
            v = np.array([r[k] for r in rr], float)
            cells.append(f"{np.nanmean(v):7.1f}({np.nanstd(v):4.1f})")
        print(f"{arm:10s} " + " ".join(f"{c:>13s}" for c in cells))
    ss = [r["dB"] for r in drows if r["kind"] == "seed-vs-seed"]
    print(f"\nlog-mel L1 distance, seed-vs-seed (same recipe): {np.mean(ss):.2f} dB (n={len(ss)})")
    for (a1, _, _), (a2, _, _) in itertools.combinations(ARMS, 2):
        v = [r["dB"] for r in drows if r["kind"] == "arm-vs-arm"
             and r["a"].split("/")[0] == a1 and r["b"].split("/")[0] == a2]
        if v:
            print(f"  {a1:10s} vs {a2:10s} same seed: {np.mean(v):.2f} dB")


def cmd_listen(a):
    L = os.path.join(HERE, "LISTEN")
    os.makedirs(L, exist_ok=True)
    shutil.copy(CLIP, os.path.join(L, "00_source_breath.wav"))
    for seed in SEEDS[: a.seeds]:
        for arm, st, na in ARMS:
            fp = os.path.join(odir(arm, seed), "final.wav")
            if os.path.exists(fp):
                shutil.copy(fp, os.path.join(L, f"seed{seed}__{arm}.wav"))
        # the rig plays intermediates too: the middle slot (t~0.5) at each step count
        for arm, st, na in ARMS[:4]:
            od = odir(arm, seed)
            man = os.path.join(od, "manifest.json")
            if not os.path.exists(man):
                continue
            sl = [s for s in json.load(open(man))["slots"] if s["file"].startswith("inter_")]
            mid = sl[len(sl) // 2]
            shutil.copy(os.path.join(od, mid["file"]),
                        os.path.join(L, f"mid_seed{seed}__{arm}__{mid['label'].replace('=', '')}.wav"))
    print(f"LISTEN -> {L}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render"); r.add_argument("--force", action="store_true")
    sub.add_parser("analyze")
    l = sub.add_parser("listen"); l.add_argument("--seeds", type=int, default=2)
    a = ap.parse_args()
    {"render": cmd_render, "analyze": cmd_analyze, "listen": cmd_listen}[a.cmd](a)


if __name__ == "__main__":
    main()
