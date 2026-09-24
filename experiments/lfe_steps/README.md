# lfe_steps: does FlowEdit's step count change the breath -> harmonium render? (2026-09-24, measured, not yet heard)

**Short answer: more steps don't make a render better. They make it more reliable.**
When a render works, 10, 20, 40 and 80 steps are about as far apart as two
seeds are. But at 10 and 20 steps, 2 of 6 renders **failed**: the edit never
took hold, and they came out as breath hiss plus a weak harmonium. At 40 and
80 steps: 0 of 6. The same held for the control that keeps 10 steps but
doubles the averaging (0 of 3). With 3 seeds per arm this is a small
sample, not a failure rate.

## Setup

- Source: `../../prompt_test/clip12s.wav` (12 s breath).
- Recipe: `breath_pitched.py`'s exact recipe and prompt, target F3.
  - LoRAs on server 7894: voice on source passes, harmonium-v2 spn_hz on target passes.
  - src cfg 1, tar cfg 5, n_avg 10, 10 intermediates via `--even-steps`.
- Varied: `lfe_steps` 10 / 20 / 40 / 80, at seeds 101 / 202 / 303.
- Control arm `s10_avg20`: 10 steps × n_avg 20. That is the same number of
  noise draws as 20 × 10, so it separates a finer time grid from more averaging.
- Code: `run.py` (`render`, `analyze`, `listen`). Numbers: `results.csv`, `distances.csv`.

## What lfe_steps is (from `sa-flowedit/stable_audio_3/inference/sampling.py`)

The server runs plain FlowEdit (`noise_amt=0`, no inversion). For each of the N steps:

1. s goes from 1 down to 1/N.
2. Draw fresh noise `n_avg` times.
3. Measure `v_target - v_source`, the difference between what the harmonium
   prompt and the breath prompt each say the audio should do.
4. Average over the draws and move the latent by `delta/N`.

So N changes three things together:

- how finely the path from 1 to 0 is sampled;
- how many noise draws get averaged (N × n_avg in total);
- the lowest noise level visited (1/N).

Fresh noise is drawn every step, so "same seed" at a different N is a
different random realization. The fair comparison is step count vs seed,
not render vs render.

## Results (final.wav)

| arm | seed 101 | seed 202 | seed 303 |
|---|---|---|---|
| s10 | ok | **FAILED** | ok |
| s20 | **FAILED** | ok | ok |
| s40 | ok | ok | ok |
| s80 | ok | ok | ok |
| s10_avg20 | ok | ok | ok |

### A clean render vs a failed one

| | clean renders (13) | the 2 failures |
|---|---|---|
| % of frames on F3 (±250 c) | 90–94 | 53, 73 |
| energy above 4 kHz | 0.2–0.3 % | 4.8, 4.1 % |
| correlation with the breath's loudness envelope | −0.37 to −0.51 | +0.74, +0.52 |
| spectral centroid | 1150–1420 Hz | ~2690 Hz |

In a clean render the harmonium does not follow the breath's loudness
envelope; the correlation is slightly negative. In a failed one it does. The
failure shows up from the very first captures:

| capture (t) | 1.0 | 0.6 | 0.45 | final |
|---|---|---|---|---|
| s20 seed 101 (failed): energy above 4 kHz | 5.2 % | 8.8 % | 8.4 % | 4.8 % |
| s40 seed 101 (clean): energy above 4 kHz | 5.0 % | 2.0 % | 1.2 % | 0.3 % |

The failed render gets hissier before it gets cleaner, and the later, low-noise
steps never recover it. Likely cause: the early high-noise steps average too
few draws, so one unlucky set of noise draws sends the edit off course. More
steps and more n_avg both mean more draws over that stretch. Both fixed it
here, which fits this reading, but it has not been tested directly.

### Among clean renders, the step count barely matters

- **Pitch:** 91–94 % on F3 in every arm, median +2 to +4 cents.
- **Harmonic fraction:** 99.9 % in every arm.
- **Distance:** log-mel L1 between two seeds of the same recipe is 3.9 dB.
  - Between step counts at the same seed: 2.5–4.6 dB.
  - 40 vs 80: 3.1 dB.
  - The only pair above the seed-to-seed spread is 10 vs 80 (4.6 dB).
- **Brightness:** one small but consistent trend. The spectral centroid rises with steps:

  | steps | 10 | 20 | 40 | 80 |
  |---|---|---|---|---|
  | clean-render centroid | ~1200 Hz | ~1240 Hz | ~1290 Hz | ~1340 Hz |

  About +12 % from 10 to 80, which is probably the finer low-noise steps
  adding upper-partial detail. It may not be audible.

### Render time (wall clock, includes hub queue; noisy)

| steps | 10 | 10 × avg20 | 20 | 40 | 80 |
|---|---|---|---|---|---|
| mean time | 39 s | 36 s | 44 s | 62 s | 98 s |

Roughly 25–30 s is fixed overhead (upload, decoding 10 intermediates); each
extra step adds about 0.8 s. **Going 20 → 40 costs about 1.4× the time, and
20 → 80 about 2.2×.**

### The production voices

`breath_pitched_work`: all 18 rendered voices, 20 steps, 35 s chunks. **None
is in the failure mode.**

- Energy above 4 kHz: 0–2.2 %. The highest values are on F5 and Bb5, where
  a bright sound is expected.
- Correlation with the breath's loudness envelope: −0.18 to +0.37.

So nothing needs re-rendering.

## Recommendation

- **Don't go to 80.** It's 2.2× the time, and a clean 80-step render can't
  be told apart from a clean 40.
- **For new renders, use 40 steps**, or 20 steps with `--n-avg 20`, whichever
  the server runs faster. That buys robustness against the failure mode for
  about 1.4× the time.
- Or stay at 20 and screen each final.wav: re-render with a new seed if
  energy above 4 kHz is > 2 % on a note below C5, or the correlation with the
  breath's envelope is > 0.5. The two measures are `metrics()` in `run.py`.
- **Open:** what the failure rate really is. There are 2 failures in 6
  renders at ≤ 20 steps, all on one clip; the 18 production voices at 20
  steps showed 0. Settling it needs about 10 seeds per arm.

## LISTEN/ (local only; audio is gitignored)

- `00_source_breath.wav`
- `seed{101,202,303}__{s10,s20,s40,s80,s10_avg20}.wav`: finals. The two failures are
  named `__FAILED-breath-leak`.
- `mid_seed*__s*__t0.45/0.5.wav`: the middle intermediate at each step count
  (the rig plays slots, not just finals).

Questions for ears:

1. Are the two failures as bad as the numbers say, or usable as a
   "breathier" colour?
2. Is s10 vs s80 at the same seed audibly different when both are clean
   (101 and 303)?
3. Do the mid slots differ more than the finals?
