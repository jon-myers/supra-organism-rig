"""latent_slow.py -- the breath36 speed axis run the other way: SLOW a voice down by reading the cached
SAME-L latent more slowly (2026-09-28). Per voice: a 30 s excerpt of morph step 0 (the untouched breath),
stretched to 0.5x and 0.25x two ways -- 'repeat' (nearest frame: each ~93 ms frame decoded 2x / 4x) and
'blend' (linear interpolation between neighbouring frames) -- plus the plain decode at 1x."""
import os, sys, torch, torch.nn.functional as F, soundfile as sf
from stable_audio_3 import AutoencoderModel
D = "/scratch/jonmyers/breath36_speed"; OUT = os.path.join(D, "slow_test"); os.makedirs(OUT, exist_ok=True)
ae = AutoencoderModel.from_pretrained("same-l", device="cuda"); SR = ae.sample_rate
FPS = SR / ae.autoencoder.downsampling_ratio
for v in sys.argv[1:]:
    z = torch.load(os.path.join(D, "latents", f"v{int(v):02d}.pt"))[0].float().cuda()
    if z.dim() == 2: z = z[None]
    a, b = int(20 * FPS), int(50 * FPS); z = z[..., a:min(b, z.shape[-1])]
    def dec(zz, name):
        with torch.no_grad(): y = ae.decode(zz, chunked=True)[0].float().cpu().numpy().T
        sf.write(os.path.join(OUT, f"v{int(v):02d}_{name}.wav"), y, SR, subtype="PCM_24"); print(v, name, f"{len(y)/SR:.1f}s", flush=True)
    dec(z, "x1")
    for f in (0.5, 0.25):
        Tn = int(round(z.shape[-1] / f))
        dec(F.interpolate(z, size=Tn, mode="nearest"), f"x{f:g}_repeat")
        dec(F.interpolate(z, size=Tn, mode="linear", align_corners=True), f"x{f:g}_blend")
print("DONE")
