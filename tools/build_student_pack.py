#!/usr/bin/env python3
"""Build the student sound pack: exactly the files show_student.scd's six tabs read, in the folder layout the
patches expect (rig/ next to song_deconstruct/, wall_of_sound/, concatenator-corpus/), plus the code of a git ref.

    python3 tools/build_student_pack.py DEST [--src SUPRA_ORGANISM_DIR] [--ref student] [--sets lowpass/full ...] [--code-only]

DEST/supra-organism/ is the pack. Audio is HARD-LINKED from SRC when both are on one volume (no extra disk), copied
otherwise. The code is `git archive REF` of this repo (no .git). wall_of_sound/analysis/live_assets.json holds absolute
paths on Jon's Mac; the pack's copy is rewritten relative to wall_of_sound/.
Re-running is safe: existing identical files are kept.
"""
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path

RIG = Path(__file__).resolve().parent.parent
DEFAULT_SETS = ["lowpass/full", "highpass/full", "notch_2oct/full2bar", "band_2oct/full2bar"]


def place(src: Path, dst: Path, stats):
    src = src.resolve()   # phantom_pain.wav is a symlink into ~/Downloads: ship the real file
    if not src.is_file():
        sys.exit(f"missing source file: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        if dst.stat().st_size == src.stat().st_size:
            stats["kept"] += 1; stats["bytes"] += src.stat().st_size; return
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)
    stats["placed"] += 1; stats["bytes"] += src.stat().st_size


def write_json(obj, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()   # never write through a hard link into the source tree
    dst.write_text(json.dumps(obj, indent=1))


def wav_paths(x, out):
    if isinstance(x, str) and x.lower().endswith((".wav", ".flac", ".aif", ".aiff")):
        out.append(x)
    elif isinstance(x, dict):
        for v in x.values(): wav_paths(v, out)
    elif isinstance(x, list):
        for v in x: wav_paths(v, out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dest")
    # default: the folder around the MAIN checkout of this repo (a worktree's own parent holds no audio)
    common = subprocess.run(["git", "-C", str(RIG), "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True).stdout.strip()
    ap.add_argument("--src", default=str(Path(common).parent.parent), help="Jon's supra-organism folder (default: around the main checkout)")
    ap.add_argument("--ref", default="student")
    ap.add_argument("--sets", nargs="+", default=DEFAULT_SETS, help="sweep sets as <set>/<grain>")
    ap.add_argument("--code-only", action="store_true")
    a = ap.parse_args()
    src = Path(a.src).resolve()
    srig = src / "rig"
    pack = Path(a.dest).resolve() / "supra-organism"
    prig = pack / "rig"
    stats = dict(placed=0, kept=0, bytes=0)

    # ---- code: git archive of the ref, over the pack's rig/ (assets in ignored folders are untouched) ----
    prig.mkdir(parents=True, exist_ok=True)
    arch = subprocess.run(["git", "-C", str(RIG), "archive", a.ref], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(prig)], input=arch, check=True)
    print(f"code: {a.ref} @ {subprocess.run(['git', '-C', str(RIG), 'rev-parse', '--short', a.ref], capture_output=True, text=True).stdout.strip()} -> {prig}")
    if a.code_only:
        return

    # ---- 36 BREATHS: 1x voices (no speed levels), onsets, gap sequences, OCEAN features + its two recordings ----
    vj = json.loads((srig / "breath36_voices" / "voices.json").read_text())
    place(srig / "breath36_voices" / "voices.json", prig / "breath36_voices" / "voices.json", stats)
    for v in vj["voices"]:
        for f in v["files"]:
            place(srig / "breath36_voices" / f, prig / "breath36_voices" / f, stats)
    # (onsets / iois / ocean_match json are tracked in git, so they came with the code; ocean_*.json hold paths relative to rig/)
    for name in ["215", "waves5min"]:
        rel = Path(json.loads((prig / "sharp" / "ocean_match" / f"ocean_{name}.json").read_text())["path"])
        place((srig / rel).resolve(), (prig / rel).resolve(), stats)

    # ---- TORNADO: live.json and every sound it names ----
    acc = srig / "sharp" / "accents"
    tj = json.loads((acc / "live" / "live.json").read_text())
    place(acc / "live" / "live.json", prig / "sharp" / "accents" / "live" / "live.json", stats)
    for f in sorted(set(wav_paths(tj, []))):
        place(acc / f, prig / "sharp" / "accents" / f, stats)

    # ---- Phantom Pain (the sweep's original + TORNADO's row) ----
    place(src / "song_deconstruct" / "in" / "phantom_pain.wav", pack / "song_deconstruct" / "in" / "phantom_pain.wav", stats)

    # ---- the LatentFT sweep: chosen sets, the _lr variant only, each plane's json ----
    for st in a.sets:
        d = src / "song_deconstruct" / "sweeps" / st
        planes = sorted(d.glob("plane_*_lr.*"))
        if not planes:
            sys.exit(f"no _lr planes in {d}")
        for p in planes:
            place(p, pack / "song_deconstruct" / "sweeps" / st / p.name, stats)
            j = d / (p.name[:8] + ".json")
            if j.exists():
                place(j, pack / "song_deconstruct" / "sweeps" / st / j.name, stats)

    # ---- WALL OF SOUND: analysis/ (IR, live_assets.json rewritten relative) + the 30 files it names ----
    wsrc = src / "wall_of_sound"
    for f in (wsrc / "analysis").iterdir():
        if f.is_file() and f.name != "live_assets.json":
            place(f, pack / "wall_of_sound" / "analysis" / f.name, stats)
    wa = json.loads((wsrc / "analysis" / "live_assets.json").read_text())
    def rel_wall(path):
        p = Path(path).resolve()
        try:
            rel = p.relative_to(wsrc.resolve())
        except ValueError:                            # outside wall_of_sound/ (e.g. audio-archive/Aug 28/...)
            rel = Path("external") / p.parent.name / p.name
        place(p, pack / "wall_of_sound" / rel, stats)
        return str(rel)
    for d in wa["dyads"]:
        d["file"] = rel_wall(d["file"])
    for k in ("voices", "chords"):
        for v in wa[k].values():
            v["file"] = rel_wall(v["file"])
    write_json(wa, pack / "wall_of_sound" / "analysis" / "live_assets.json")

    print(f"audio: {stats['placed']} placed, {stats['kept']} already there, {stats['bytes'] / 1e9:.1f} GB -> {pack}")


if __name__ == "__main__":
    main()
