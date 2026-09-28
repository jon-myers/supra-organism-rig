"""
render_speed_axis.py -- a SPEED axis for the 36 breath voices via latent time-warping (2026-09-26).

For each voice: encode its 8 morph-step files with the Stable Audio 3 SAME-L autoencoder,
build ONE time-warp per (voice, level) -- output frames read the latent at a position that
advances at a LOCAL speed which wanders around the level: segments of irregular length (Jon's
rhythmic_sequence_maker, nCVI 35, mean ~1.5 s) each with speed = level * 2**N(0, sigma) -- apply
the same warp to all 8 steps (so morphing stays time-aligned), decode (nearest-frame reads,
the cleaner method in latent_speed.py), write breath36_voices/speed/<file>_x<level>.wav.
Levels: 1.5 2 3 4 (level 1 = the originals breath36 already loads). Mono 44.1 kHz 24-bit.
"""
import sys, os, json, time, argparse, numpy as np, soundfile as sf, torch
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "accelerando")); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ncvi import rhythmic_sequence_maker
ap = argparse.ArgumentParser()
ap.add_argument("--voices", default="", help="e.g. 1,2,3 (1-based); empty = all")
ap.add_argument("--levels", default="1.5,2,3,4"); ap.add_argument("--sigma", type=float, default=0.3, help="log2 spread of local speed")
ap.add_argument("--seg-secs", type=float, default=1.5); ap.add_argument("--ncvi", type=float, default=35)
ap.add_argument("--device", default="mps"); ap.add_argument("--voices-dir", default=None); ap.add_argument("--out", default=None); ap.add_argument("--src-ext", default="wav"); ap.add_argument("--latent-cache", default=None, help="dir for per-voice latent .pt files (fp16); reused if present")
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__)); VD = a.voices_dir or os.path.join(HERE, "..", "breath36_voices"); OUT = a.out or os.path.join(VD, "speed"); os.makedirs(OUT, exist_ok=True)
meta = json.load(open(os.path.join(VD, "voices.json"))); levels = [float(x) for x in a.levels.split(",")]
want = [int(x) for x in a.voices.split(",") if x] or [v["voice"] for v in meta["voices"]]
from stable_audio_3 import AutoencoderModel
ae = AutoencoderModel.from_pretrained("same-l", device=a.device); SR = ae.sample_rate; FPS = SR / ae.autoencoder.downsampling_ratio
warps = {}; t_all = time.time()
for v in meta["voices"]:
    if v["voice"] not in want: continue
    t0 = time.time(); zs = []
    cache = os.path.join(a.latent_cache, f"v{v['voice']:02d}.pt") if a.latent_cache else None
    if cache and os.path.exists(cache):
        zs = [z.to(a.device).float() for z in torch.load(cache)]
    else:
        for f in v["files"]:
            y, sr = sf.read(os.path.join(VD, os.path.splitext(f)[0] + "." + a.src_ext), dtype="float32")
            if y.ndim == 1: y = np.stack([y, y], 1)
            with torch.no_grad(): zs.append(ae.encode(torch.from_numpy(y.T.copy()).to(a.device), sr, chunked=True))
        if cache: os.makedirs(a.latent_cache, exist_ok=True); torch.save([z.half().cpu() for z in zs], cache)
    T = min(z.shape[-1] for z in zs); zs = [z[..., :T] for z in zs]
    for lv in levels:
        rng = np.random.default_rng(10_000 + v["voice"] * 10 + int(lv * 10))
        # warp: local speed per irregular segment; walk the input until it is consumed
        n_seg = max(4, int(T / lv / (a.seg_secs * FPS)))
        seg = np.asarray(rhythmic_sequence_maker(n_seg, a.ncvi), dtype=float); seg = seg / seg.mean() * a.seg_secs * FPS  # output frames per segment
        speeds = lv * 2.0 ** np.clip(rng.normal(0, a.sigma, n_seg), -1, 1)
        idx = []; pos = 0.0; s_i = 0; left = seg[0]
        while pos < T - 0.5:
            idx.append(int(round(pos))); pos += speeds[s_i]; left -= 1
            if left <= 0: s_i = (s_i + 1) % n_seg; left = seg[s_i]
        idx = np.clip(np.array(idx), 0, T - 1); warps[f"v{v['voice']:02d}_x{lv:g}"] = {"frames_out": len(idx), "frames_in": T, "mean_speed": round(T / len(idx), 3)}
        it = torch.from_numpy(idx).to(a.device)
        for f, z in zip(v["files"], zs):
            if os.path.exists(os.path.join(OUT, f"{os.path.splitext(f)[0]}_x{lv:g}.wav")): continue
            zw = z.index_select(-1, it)
            with torch.no_grad(): out = ae.decode(zw, chunked=True)[0].float().cpu().numpy()
            mono = out.mean(0); pk = np.abs(mono).max(); mono = mono / pk * 0.891 if pk > 0.891 else mono
            sf.write(os.path.join(OUT, f"{os.path.splitext(f)[0]}_x{lv:g}.wav"), mono, SR, subtype="PCM_24")
    done = len([k for k in warps]) // len(levels); print(f"v{v['voice']:02d} {v['performer']:8s} T={T} frames  {time.time()-t0:5.1f} s  (elapsed {(time.time()-t_all)/60:.1f} min)", flush=True)
prev = json.load(open(os.path.join(OUT, "speed.json"))) if os.path.exists(os.path.join(OUT, "speed.json")) else {"warps": {}, "levels": []}
warps = {**prev["warps"], **warps}; levels = sorted(set(prev["levels"]) | set(levels))
json.dump({"levels": levels, "sigma": a.sigma, "seg_secs": a.seg_secs, "ncvi": a.ncvi, "warps": warps}, open(os.path.join(OUT, "speed.json"), "w"), indent=1)
print("DONE", OUT)
