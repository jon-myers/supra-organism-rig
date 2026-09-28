"""
latent_speed.py -- can Stable Audio 3 (SAME-L) latents be time-compressed before decoding? (2026-09-26)

Encode a breath excerpt, resample the latent sequence ALONG TIME by a factor (linear
interpolation, and nearest-frame decimation as a second method), decode, and write the result
next to two references at the same factor: Rubber Band R3 time-compression (pitch kept) and
plain playback speed-up (pitch rises). Nothing in stable_audio_3 or the collage service does
this; it is just F.interpolate on the (C, T) latent.
"""
import sys, os, time, argparse, numpy as np, soundfile as sf, torch, torch.nn.functional as F, subprocess
ap = argparse.ArgumentParser()
ap.add_argument("--src", default="/Users/jon/Documents/2026/MIT/projects/supra-organism/rig/breath36_voices/v01_anna_Eb5_slot0.wav")
ap.add_argument("--offset", type=float, default=20.0); ap.add_argument("--secs", type=float, default=30.0)
ap.add_argument("--factors", default="1,1.5,2,3,4,6"); ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "latent_speed_out"))
ap.add_argument("--ae", default="same-l"); ap.add_argument("--device", default="mps")
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
from stable_audio_3 import AutoencoderModel
t0 = time.time(); ae = AutoencoderModel.from_pretrained(a.ae, device=a.device); print(f"loaded {a.ae} on {a.device} in {time.time()-t0:.1f}s; sr {ae.sample_rate}, ds {ae.autoencoder.downsampling_ratio}, latent_dim {ae.autoencoder.latent_dim}", flush=True)
y, sr = sf.read(a.src, start=int(a.offset * 44100), stop=int((a.offset + a.secs) * 44100), dtype="float32")
if y.ndim == 1: y = np.stack([y, y], 1)
sf.write(os.path.join(a.out, "00_source.wav"), y, sr)
audio = torch.from_numpy(y.T.copy())
with torch.no_grad():
    z = ae.encode(audio.to(a.device), sr, chunked=True)          # (1, C, T)
print("latent", tuple(z.shape), f"= {z.shape[-1] / a.secs:.2f} frames/s", flush=True)
with torch.no_grad():
    recon = ae.decode(z, chunked=True)[0].float().cpu().numpy().T
sf.write(os.path.join(a.out, "01_recon_x1.wav"), recon[:len(y)], ae.sample_rate)
for f_ in [float(x) for x in a.factors.split(",") if float(x) != 1]:
    T = z.shape[-1]; Tn = max(8, int(round(T / f_)))
    for method in ["linear", "nearest"]:
        zs = F.interpolate(z, size=Tn, mode=method, **({"align_corners": False} if method == "linear" else {}))
        with torch.no_grad():
            out = ae.decode(zs, chunked=True)[0].float().cpu().numpy().T
        name = f"latent_{method}_x{f_:g}.wav"; sf.write(os.path.join(a.out, name), out, ae.sample_rate); print("wrote", name, f"{len(out)/ae.sample_rate:.1f}s", flush=True)
    src = os.path.join(a.out, "00_source.wav")
    subprocess.run(["rubberband", "-q", "-3", "-t", str(1 / f_), src, os.path.join(a.out, f"ref_rubberband_x{f_:g}.wav")], check=True)
    subprocess.run(["sox", src, os.path.join(a.out, f"ref_speed_pitchup_x{f_:g}.wav"), "speed", str(f_)], check=True)
print("DONE", a.out)
