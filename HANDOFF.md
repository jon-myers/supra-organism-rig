# supra-organism rig — handoff (updated 2026-09-23 on the nyc Mac; panes BUILT)

**Goal (Jon, 2026-09-23):** one live SuperCollider patch for tonight's rehearsal that builds on the
existing studio rig (FlowEdit morph + latent collage + concatenator, 4-lane capture strip,
nanoKONTROL2) and adds panes for **wall of sound**, **metronomes**, and the **LatentFT pieces**.

## State: tabs 4-6 are written and pass a live end-to-end test on this Mac

`rig.scd` now has six tabs. The new ones each own ONE lane, so the strips, the nanoKONTROL2
S-row (play), volume knobs, pan, mute/solo and the output meters keep working unchanged:

| tab | key | lane | what |
|---|---|---|---|
| WALL OF SOUND | 4 | 1 | bell_12min render streamed from disk (`VDiskIn`, 96 kHz wav rate-scaled, mp3 stand-in when the wav has not synced). Version menu A/B/C × curve/open, play/pause, go-to-seconds, 1 Hz mm:ss readout, rescan. |
| WALL OF SOUND | 4 | 2 | live dyads: 24 stem buttons + AUTO. Mirrors compose.py: apex envelope (gaussian apex 0.5 ± 0.125, clipped 0.25–0.75), random azimuth, 0 to −6 dB, Tenney-style stem choice (weight = age²). **Fader 2 = density** (mean gap 60 s → 2 s). "cut all" frees sounding dyads. Stems load at boot (`~wsLoadStems`, ~630 MB). |
| METRONOMES | 5 | 3 | three modes on one lane: **FILES** (set / voice / file menus → LOAD → play; readout "beat n / N · BPM · mm:ss" stepped at 2 Hz from the `.beats.json`); **LIVE** (server-side click, `VarLag` glide so the tempo never steps; **fader 3 steers BPM inside the lo–hi range**, glide s = settle time; voice tock/beep synthesised); **GLIDE** (target BPM + seconds, GO ramps from the current tempo, linear or exp; GO again re-targets mid-ramp; HOLD freezes; a "30→80 / 3:00" preset). File playback and the click are exclusive on lane 3. |
| LATENTFT | 6 | 4 | A and B source menus (original phantom_pain + every wav found under the LatentFT out dirs), loaded on selection, read by ONE clock in seconds so 22050 and 44100 Hz files stay sample-locked; **fader 4 = equal-power crossfade** (also the on-screen slider); play/stop, go-to-seconds, section cue buttons from `phantom_pain_form/out/form_compact.json` (in, A1, B1, A2, B2, A3, C1, out); B offset box (auto −60 for the `*60s` pieces). |

Transport ■ stops everything including the panes. The play button on a strip starts that lane's pane
player when a set tab is showing, and the old morph/collage/concat player on tabs 1–3.

Implementation notes:
- The new code sits between the latent-collage section and the control surface, in six
  `{ ... }.value` blocks. **That wrapping is load-bearing:** the `s.waitForBoot { }` function hit
  sclang's 256-entry literal/selector table ("Selector table too big") when the pane code was
  inline. Any further pane must go inside one of those blocks or a new one.
- Fader semantics are now centralised: `~surfFaderName / ~surfFaderVal / ~surfFaderText /
  ~surfFaderSet` handle every tab; the GUI fader and the MIDI fader both call `~surfFaderSet`.
- Pane hooks: `~panePlaying / ~paneStart / ~paneStop / ~panesStopAll / ~paneApplyMix`, called
  from `~lanePlaying`, `~laneTogglePlay`, the STOP button and `~applyMix`.
- Position readouts are `SendReply` → `OSCdef` (`/srWsPos` 1 Hz, `/srMtPos` 2 Hz, `/srClick` 2 Hz,
  `/srLfPos` 1 Hz) into StaticTexts; no animation anywhere.
- Headless test driver used here: a script that `executeFile`s rig.scd, waits for `~lfTab`,
  exercises every pane and exits (see the git log of 2026-09-23). Compile check:
  `thisProcess.interpreter.compile(File.readAllString(p))` is nil on a parse error.

Not done / to check at the venue: the output device (`~srOutDevice` is nil = system default);
the wall pane at 96 kHz reads at rate 2 on a 48 kHz server — fine, or set `~srSampleRate = 96000`;
the mp3 stand-ins are 48 kHz. The laptop → nyc sync had only delivered `A_dyads_curve.wav` of the
six bell wavs when this was written and no rsync was running any more (`.sync_done` absent).

## What is in this repo

- `rig.scd` — copy of `sa-flowedit/studio_rig.scd` (2026-08-28 version, identical to the
  max-frontend worktree copy) with every path made relative to this file: `~soRoot` is the
  `supra-organism` folder, and `sa-flowedit`, `sa-latent-collage`, `concatenator-corpus` are
  resolved as its siblings. The old absolute `~/Documents/2026/MIT/experiments/...` paths no
  longer existed after the Mac migration, so the original file could not run as-is.
  `thisProcess.nowExecutingPath` must resolve, so evaluate it from the saved file in the SC IDE.
- `studio_presets.json` — the FlowEdit prompt presets (read-only from the rig).
- Runbook for the existing tabs: `../sa-flowedit/STUDIO-RIG.md`. Key findings about FlowEdit
  (t is edit strength, useful range 0–0.3; 7882 is dead, use 7888/7893; harmonium LoRA notes
  F A Ab G C D E only): `../sa-flowedit/HANDOFF.md`.

Prereqs unchanged: SuperCollider 3.14.1, `python3` on PATH, `concatenator-corpus/.venv`,
ssh tunnel with 7884 (collage), 7888 + 7893 (FlowEdit) forwarded (`fleet up`, Duo tap).
Audio devices seen on the MIT laptop: Waves SoundGrid, MacBook Pro Speakers, aggregates.

## Structure of rig.scd (what to extend)

- Config block lines ~25–125; `~tabFe = 0; ~tabLc = 1; ~tabCc = 2` name the StackLayout indices.
- Tabs are assembled at the bottom: `~tabStack = StackLayout(~feTab, ~lcTab, ~ccTab)` and
  `~tabBtns = ["FLOWEDIT MORPH", "LATENT COLLAGE", "CONCATENATOR"]`. **Adding tabs means also
  fixing** `~setTab.((~curTab ± 1).wrap(0, 2))` (three places: track buttons + MIDI) and the
  keyboard `1/2/3` switch — use `~tabBtns.size - 1` instead of the literal 2.
- Each tab is `HLayout(transport-width header column, *four lane columns of width ~stripW, nil)`;
  the control surface (four strips with knob/fader/play/collage/morph + output meters) sits
  below and re-labels its faders per tab in `~surfFaderName` / `~surfRefresh`.
- Players: `\srFilePlay` (mono buf), `\srFilePlay2` (stereo buf), per-lane morph defs. All
  players call `~outMeter.(sig, lane)` so the output meters work. Motion-safe rules: readouts
  stepped at 1–2 Hz, no animation, no drag selection (vestibular migraines).
- `~playAllLanes`, `~laneTogglePlay`, `~lanePlaying` decide what "play" means per tab; new
  panes should hook into these so the surface play buttons and MIDI S-row keep working.

## Media inventory for the new panes (all verified with afinfo)

**Wall of sound** — `wall_of_sound/renders/bell_12min/`: `{A_dyads, B_dyads+voices,
C_dyads+voices+chords}_{curve,open}.wav`, **stereo 96 kHz 24-bit, 720.0 s, 415 MB each** (mp3s
alongside; `old_limited/` and `previous_dry_voices/` are superseded). B and C are the 2026-09-18
re-renders with room + EQ on the voices — **unlistened**. Dyad stems `wall_of_sound/stems/01–24.wav`
are stereo 96 kHz, ~34 s each (harmonium dyads). Engine: `compose.py` (density curve + Tenney
dissonant-counterpoint stem choice + random azimuth panning + apex envelope), `bell.py`
(12-min bell placement). Listening page: https://claude.ai/artifact/2YgsEYfD3asfTWJDd1ukXT.
→ 96 kHz files: stream with `VDiskIn` at `fileSR / s.sampleRate` (or run the server at 96 k);
loading 415 MB into a Buffer is a bad idea. A "live wall" pane could fire dyad stems by hand /
MIDI with the apex envelope and a density knob, mirroring compose.py.

**Metronomes** — `metronomes/`, mono 44.1 kHz 24-bit, every wav has a sibling `.beats.json`
(tick times, metrical level, instantaneous tempo — use it for a stepped "beat n / BPM" readout):
- `speedups_30-80bpm/{tock,beep}/30-80bpm_MMmSSs.wav` — 19 durations, 1:00–10:00 in 30 s steps.
- `90counts_30-80bpm/{tock,beep}/` — 1m30, 1m40, 1m45.93 EVEN, 1m55.32 PERCOUNT, 2m00.
- `logeven/30-80bpm/{tock,beep}/30-80bpm_logeven_0{3,4,5}m00s.wav` — the deliverable set
  (180.08 / 240.11 / 300.13 s); `logeven/30-120bpm/` is the by-product.
- Fixed-tempo references `30bpm.wav`, `40bpm.wav`, `50bpm.wav`, `30bpm long.wav`.
README: `metronomes/README.md` (Callender 2001 method; files end exactly on 80.000 BPM).

**LatentFT pieces** (Phantom Pain, Mason Wang's model) — **stereo 22050 Hz Int16**:
- `song_deconstruct/.claude/worktrees/latentft/out/latentft/fullsong/phantom_pain_{reconstruct,deconstruct}_fullsong.wav`
  (315.2 s each, sample-aligned with each other — an A/B or equal-power crossfade pane between
  them and the original is the natural "hear the knob" interface).
- `.../out/latentft/pieces/{lp,hp,bp_1oct}_60s.wav` (40.2 s each, from 60 s into the track).
- `.../out/latentft/LISTEN_run11_grid_and_bandpass/01–08*.wav` + `LISTEN.md` — **unlistened**.
- **For Ann and run 10 are NOT in the latentft worktree**: they are in the main checkout,
  `song_deconstruct/out/latentft/for_ann/` and `song_deconstruct/out/latentft/LISTEN_run10_FULLSONG_pieces/`
  (also `song_deconstruct/.claude/worktrees/for-ann/out/latentft/for_ann/`). Not yet inventoried.
- Original track: `song_deconstruct/in/phantom_pain.wav` (symlinked from `phantom_pain_form/in/`).
  Form for section cueing: fade-in 14 | A 16+4 | B 8+12 | A 20 | B 8+8 | A 22 | breakdown 10+16 |
  outro 4+5 bars; bar times in `phantom_pain_form/out/form_compact.json`.
Notes: `.../worktrees/latentft/LATENTFT.md`. The 95-render knob grid is ready but NOT launched.

## Original plan (2026-09-23 afternoon) — now implemented as above

1. Evaluate `rig.scd` once on the target machine to confirm the relative paths and server boot.
2. Add a **PLAYERS / SET** tab family: (a) wall of sound: version menu (A/B/C × curve/open),
   VDiskIn stream, play/pause/locate by number box, stepped mm:ss readout, level; plus live dyad
   firing. (b) metronomes: set/voice/duration menus, play with beat-count + BPM readout from
   the `.beats.json`, a fallback synthesized click with a BPM box. (c) LatentFT: sample-locked
   A/B/original players with an equal-power crossfade fader, section-cue buttons from the form.
3. Route the new players through `~outMeter`, `~effLevel`, and the surface play buttons; extend
   the tab-wrap logic and key switches (`4`, `5`, `6`).
4. Syntax-check headless: `sclang` can `thisProcess.interpreter.compile(File.readAllString(p))`
   and exit; nil means a parse error.

Standing issues from the project brief: `/data/scratch/jonmyers` is over quota (use
`/data/scratch-fast/jonmyers`); lab-journal `song-deconstruct` inbox notes to promote.

## 2026-09-23 evening -- standalone patches (laptop session)

`set.scd` is now the entry point: it opens `metro_slider.scd` + `breath_swarm.scd` on one server.

- `metro_slider.scd` -- one log slider 20-80 BPM (starts 30), glide, beats/cycle (default 10) with
  a downbeat-accent toggle, big 4 Hz tempo readout.
- `breath_chorus.scd` -- 1-20 looping breath-collage voices (`render_breath_voices.py`, no GPU).
- `breath_morph.scd` -- same, each voice morphable breath -> harmonium (`breath_morph.py`, v1 LoRA
  on 7893, unpitched).
- `breath_pitched.scd` -- 20 voices, each morphing to its own harmonium pitch: C Eb F Bb (the
  wall-of-sound dyads' pitch classes, measured) over octaves 2-5 (`breath_pitched.py`). Uses the
  **harmonium-v2 spn_hz LoRA on 7894** (needs `ssh -O forward -L 7894:127.0.0.1:7894 mobile01`).
  The v1 LoRA put a strong C5 under every named note (65-87 % of the energy); those renders are
  kept in `breath_pitched_work_v1_c5drone/`. Voices 19-20 not rendered yet (tunnel dropped).
- `breath_swarm.scd` -- **live collage, 1-216 voices (6^3)** from the same renders held once
  (`prepare_swarm.py`, 838 MB): each voice plays breath segments of render v mod 18 in its own
  endlessly reshuffled order, so there are no loops to realign. Morph = ALL + pitch-class offset +
  octave offset. Server-side modulation input per voice (`modbus`/`modamt`, `~bsSetMod`) and OSC
  `/swarm/*` for the force-sensor layer (session so-force). Measured: 216 voices ~20 % avg CPU.

Audio notes: patches fall back to the system output if the named device is missing, and pin the
input to the MacBook mic (the default input, Waves SoundGrid, crashes boot when not running).

## 2026-09-26 -- breath "sharpness" (session supra-organism-3c)

- `breath36_sharp.scd` (v2) -- a sharpness knob layered on breath36 (open breath36.scd first, then
  evaluate this; re-evaluating is safe). ONE signal, one process: the loop plays as before and a
  time-varying amplitude window, retriggered at the voice's own breath onsets, shapes it. 0 =
  identity; to 0.6 the gaps between breaths deepen to silence and the window shortens (each breath
  cut to a burst of itself, performer's timing); above 0.4 a per-voice nCVI clock adds onsets
  (spacing 2.5 s -> "mean IOI", default 0.3 s); window down to "min window" (0.07 s), 3 ms attack.
  "pos rand" lets the read position jump at an onset; "spread" offsets voices. Sensor input
  `~b36SetSharpMod.(i, bus, amt)`. Voice 1 posts its onset count. v1 (loop/grain crossfade) was
  rejected by Jon before it worked ("this works by crossfade? seems like it will fail") -- it went
  silent at 100 % because the grain trigger multiplied a demand UGen by a k-rate control.
- `sharp/make_onsets.py` -> `sharp/onsets.json`: breath onsets per voice from slot0, detected as
  loudness swells (RMS dB, peak_pick, backtracked to 25 % of the rise). Spectral-flux onset
  detection under-counted badly on soft breaths (gaps of 8-18 s on some voices).
- `sharp/make_sharp_assets.py` -> `sharp/iois.json` (36 voices x 6 nCVI levels x 128 IOIs, mean 1,
  own seed per voice) and the concatenator targets below.
- Option 3 of the same brainstorm lives in concatenator-corpus: `run_sharp_concat.sh` musaics the
  per-performer breath corpora against `targets/ncvi_noise_{soft,mid,sharp}.wav` (pink-noise
  bursts at nCVI-50 onsets; mean IOI 1.0/0.5/0.25 s, bursts 250/120/60 ms) and `targets/2020_60s.wav`.
  Renders + peak-normalized listening copies: `concatenator-corpus/out/sharp/listen/`.
- Not done (Jon unsure): option 2, feeding the Aug 28 whoosh/boops stems in at the sharp end.

## 2026-09-27 -- breath SPEED axis via latent time-warp (session supra-organism-3c)

Jon rejected both the grain crossfade and the onset-windowing sharpness designs ("naw") and asked
for latent time-stretching of Stable Audio 3 latents instead. Test (`sharp/latent_speed.py` ->
`sharp/latent_speed_out/`): SAME-L latents run at 10.77 frames/s (ds 4096, 256 ch); resampling
the latent along time and decoding gives a pitch/spectrum-preserving speed-up (mel-spectrum corr
0.96-0.98 to the source at 1.5x-6x; nearest-frame reads beat linear interpolation; tape speed-up
for contrast falls to 0.36 at 2x). Runs locally: sa-flowedit/.venv, `AutoencoderModel.from_pretrained
("same-l", device="mps")`, ~2 min per voice for 8 steps x 4 levels.
- `sharp/render_speed_axis.py` -> `breath36_voices/speed/<file>_x{1.5,2,3,4}.wav` + `speed.json`.
  ONE warp per (voice, level), applied to all 8 morph steps (so morphing stays aligned): local speed
  = level * 2^N(0, 0.3) per irregular segment (rhythmic_sequence_maker nCVI 35, mean 1.5 s) --
  the "bit of variability" Jon asked for. Voice 1 done; voices 2-36 rendering (started 2026-09-27
  ~00:05, ~80 min).
- `breath36_speed.scd` -- stepped speed slider 1x..4x over breath36 (evaluate after breath36.scd):
  one synth per (voice, level) using breath36's own \b36Voice def, paused when not active; each
  voice on a discrete level = round(slider + own offset), switching staggered with a short fade,
  never a blend of two speeds. Wraps ~b36SetMorph / ~b36Set / ~b36SetAmp so the breath36 window
  still drives every level. API: ~spSetLevel.(i, k), ~spSetAll.(x). RAM: ~3.5 GB per level on top
  of breath36's 6.6 GB; `~spLevels = [2, 4]` before evaluating loads a subset. Compiles; not heard.
- `breath36_sharp.scd` (v2 windowing) is parked, not the direction.

## 2026-09-27 (later) -- breath36.scd is now ONE patch (morph + speed), voices tiled

- `breath36.scd` absorbs the speed axis (was `breath36_speed.scd`, now in `sharp/archive/` with the
  parked `breath36_sharp.scd` and the pre-merge `breath36_pre-merge.scd`). One window: voice count
  0-36, speed 1x-4x with per-voice spread / re-roll / switch fade / stagger, morph sliders with a
  small speed-level readout per voice. One synth per (voice, level); inactive levels paused.
  `~b36SpeedLevels = [2, 4]` or `[]` before evaluating loads fewer levels (RAM ~3.5 GB each).
- Voices are TILED across performers (anna, grisha, raymond, sora, anna, ...) by reordering
  `meta["voices"]` at load; slot numbers, pans and the voice-count slider follow the tiled order.
  `~b36Synths` is still the level-1 synth array, `~b36SetMod` now reaches every level.
- Default voice count is 0 (silent on load). Compiles; not yet heard in this form.
- 2026-09-27 13:47: speed levels 6x 8x 10x rendered for all 36 voices on **mobile01** (RTX 6000 Ada,
  `/scratch/jonmyers/breath36_speed/`, flowedit venv, ~17 min; sources went up as FLAC at 14 MB/s,
  results came back as FLAC at 11 MB/s -- the earlier 0.5 MB/s rsyncs were an anomaly, the idle link
  measures 95 Mbps up / 31 Mbps down). `breath36_voices/speed/` now holds 7 levels, 10 GB;
  `~b36SpeedLevels` defaults to all seven (~21 GB of server buffers with the originals).
  Latents cached on mobile01 (`latents/`, fp16) so further levels there are decode-only.
  A 10x voice loops every ~14-16 s.

## 2026-09-27 (afternoon) -- breath36.scd v3: breath-by-breath player, GAP knob, nanoKONTROL2

- Player rewritten: per voice a Routine plays SEGMENTS between detected breath onsets
  (`sharp/onsets.json` for 1x, `sharp/onsets_speed.json` for the speed renders -- `make_onsets.py
  --speed`, windows scaled by 1/level) as short `\b36Seg` synths (sine fades at the cut, 40 ms),
  reading morph and on-gain from per-voice control buses written by `\b36Ctl` (which still takes
  `modbus/modamt`, so force_layer.scd's `~b36SetMod` works). gap = 0 reproduces the loop; gap > 0
  inserts a rest after each breath, scaled by the voice's nCVI sequence (`iois.json`, menu
  0/10/20/35/50/70). Speed level changes now happen AT THE NEXT BREATH (no crossfade, no paused
  synths, so idle CPU is ~0 with voices off). Voices start at independent random phases.
- nanoKONTROL2 (factory CCs, in the same patch, `~b36Midi = false` to disable): sliders 1-8 = morph
  of pitch groups C/Eb/F/Bb low (oct 2-3) then high (oct 4-5); S/M solo/mute group; R1 re-roll
  speed offsets; CYCLE links sliders; knobs 1-8 = voices, speed level, spread, glide, volume, fade,
  gap, gap nCVI; PLAY/STOP = voices back on / all off. Soft takeover (`~mkPick`) on every
  fader/knob. Jon's unit sends some buttons as noteOn -- both routed through `~mkButton`.
- Previous versions: `sharp/archive/breath36_pre-gaps.scd` (v2, paused-synth speed switching).
- Not yet heard. Things to check first: seam clicks at gap 0 (raise seg fade), timing drift of
  the language-side scheduler over a long run (uses s.latency bundles), MIDI pickup feel.

## 2026-09-27 (evening) -- show rig: metro on its own server, wall of sound LIVE

- `metro.scd` = metro_slider.scd on a second scsynth (`~msServer`, port 57111, `~msOutDevice =
  "Multi-Output Device"` per Jon; breath36 / rig stay on the default server = headphone jack until
  an interface arrives). All server refs go through ~msServer; `~msOutBus` offsets the output.
- `wall_live.scd` -- bell.py's placement rule run live: three DENSITY sliders (dyads 0-8, voices 0-4,
  chords 0-2) = target number of concurrent events; a 0.25 s tick starts an event when the
  committed count (events minus their closing 20-35 %) is below target, after a 1.5-4 s entry gap.
  Material/levels from `wall_of_sound/analysis/live_assets.json` (`wall_of_sound/live_assets.py`:
  singer segments via bell.py find_segments, gains vs the median dyad, chord starts/fades/pans) and
  the bell.py room IR resampled to 44.1k (`room_ir_44k.wav`, PartConv, wet -8 dB). Voices get the
  distance EQ live (BHiPass x2 @80, BLowShelf 200/-4, BHiShelf 7k/-5). ~1.7 GB of buffers.
  HUSH = targets to 0 (events finish), CUT = stop now. nanoKONTROL2: sliders 1-3 densities, knobs
  1-3 trims, knob 5 master, STOP = hush; surface OWNERSHIP shared with breath36 through `~mkOwner`
  (TRACK < > cycles owners) -- breath36 does NOT yet check ~mkOwner (TODO).
- Not built: the Phantom Pain "mass panner". Clarified with Jon: he wants FULL-TRACK renders at
  every row-zeroing step (k00..k80) with the NEW STEREO LatentFT (cluster session's fine-tune,
  `/data/scratch-fast/jonmyers/latentft_stereo/`, training to 250k tonight; its
  `latentft_stereo_render.py` does a full track in ~1.8 min on an H200), then a tab that sweeps
  through them live. 81 renders ~4-5 GB at 22.05 kHz stereo; fits everywhere.
- None of tonight's patches have been heard.
- 2026-09-27 ~17:30: mass-panner renders QUEUED on the cluster: array **2364842** (lft-bins, 81 tasks, %4,
  H200), `--dependency=afterany:2360113:2360115` (the stereo fine-tune + its continuation, finishing
  ~22:50 EDT). Script `/data/scratch-fast/jonmyers/latentft_stereo/bins/render_bins.sbatch`; each task
  = full track at a fixed cutoff k x 0.0841 Hz (k = 1..81) with the newest `run1/ema_step*.pt`; outputs
  `/data/scratch-fast/jonmyers/latentft_stereo/bins/phantom_pain/phantom_pain_kNN_reconstruct_<tag>.wav`
  (22.05 kHz stereo PCM16, ~28 MB each, ~2.3 GB total). Preempted tasks: `sbatch --array=<k>` again.
  Cluster session (supra-organism-0b) was told; it owns the renderer. Next: pull them down (FLAC via
  slurm2, ~2 GB) and build the sweep tab (stream from disk, centre / width / spread).
- 2026-09-27 ~19:00: the OTHER sweep sets are the cluster session's (supra-organism-0b): new
  `scripts/latentft_stereo_ladder.py` (HAI-Res/latentft-post-training), modes lowpass / highpass
  (= Jon's "deconstruct") / band / notch at widths 1 bin, 1 oct, 2 oct, 81 planes each, frozen
  stereo-v1 (`latentft_stereo/frozen/stereo-v1/ema_step250000.pt`), EACH plane written twice: `_lr`
  (L/R vocoded separately, wide) and `_mid` (mid vocoded once + per-band level width, fused). Layout
  `/data/scratch-fast/jonmyers/latentft_stereo/ladders/<mode>_<width>/<full|2bar>/` + manifest.json
  (plane index -> mask). Queue order: highpass full, all 2-bar sets, then band/notch full (may land
  in the morning). My 2364842 lowpass set stays as is (its renderer is the hai-res-agents session's).
- `sweep_live.scd` -- the mass panner player: a SET = folder of full-track planes (+ manifest.json),
  streamed with VDiskIn (Buffer.cueSoundFile at the shared transport position), centre / width
  (Hann over |k - centre|, power-normalised) / spread (pan by offset) / master, `_lr` vs `_mid`
  variant toggle, PLAY/STOP/seek. `~swSets` maps names to folders; ladders are expected under
  `song_deconstruct/sweeps/<mode>_<width>/full/` after pulling from scratch-fast. Smoke set
  `test_pieces` = the three 60 s lp/hp/bp renders. nanoKONTROL2: sliders 1-3 centre/width/spread,
  knob 5 master, PLAY/STOP, CYCLE variant. breath36 now honours ~mkOwner too (TRACK < > cycles
  breath36 / wall / sweep). Compiles; unheard.
- 23:40: cluster session's ladders QUEUED: 2-bar sets (one task each, all 81 planes) 2371719-2371726;
  full-track arrays chained one set at a time: highpass 2371727 -> band_1oct 2371728 -> notch_1oct
  2371729 -> band_2oct 2371730 -> notch_2oct 2371731 -> band_bin 2371732 -> notch_bin 2371733 ->
  lowpass 2371734 (~30 min per set on 6 GPUs, queue was 77 deep). Output
  `/data/scratch-fast/jonmyers/latentft_stereo/ladders/<set>/<grain>/plane_NN_{lr,mid}.wav` +
  `plane_NN.json`, NN = 01..81. Preempted task: `SET=<set> GRAIN=full sbatch --array=<NN>
  cluster/latentft_stereo_ladder.sbatch` in mask_study/code. sweep_live.scd now expects exactly that
  layout under `song_deconstruct/sweeps/<set>/<grain>/` (16 sets pre-listed; 2-bar sets loop).
  Pull command for the morning:
    rsync -a --include='*/' --include='*.json' --include='*.wav' --exclude='*' \
      slurm2:/data/scratch-fast/jonmyers/latentft_stereo/ladders/ ../song_deconstruct/sweeps/
  (~2.3 GB per full set as PCM16; convert to FLAC on slurm2 first if the link is slow.)

## 2026-09-28 morning -- metro.scd readied for the Bluetooth / Multi-Output test

- Port moved 57111 -> **57131** (macOS `sharingd` holds UDP 57111; a boot there fails "address in use").
- Fixed 48 kHz on the metro server (mic is 48 k; Bluetooth/Multi-Output usually 48 k) so scsynth's
  in/out rate check cannot refuse. Verified headless: boots, `SC_AudioDriver: sample rate = 48000`.
- Window now has an OUTPUT DEVICE menu + rescan: choosing one quits/reboots the metro server on it
  and rebuilds (`~msRebootTo`). Title/readout show the ACTUAL device (falls back to system default
  with a warning if the named one is absent).
- State at 09:xx: no Bluetooth headphones connected; "Multi-Output Device" exists in Audio MIDI Setup
  but with sample rate 0 (no live members) so CoreAudio does not offer it -> SC's outDevices list
  lacks it. It must contain each connected headphone (+ speakers/jack as clock) to appear.
- Launch from a shell (no IDE): `/Applications/SuperCollider.app/Contents/MacOS/sclang rig/metro.scd`.
  Boot is by trial over sample rates 44.1 k / 48 k / device rate (`~msTryBoot`; scsynth exits
  silently on an in/out rate mismatch). Gotcha: killing that sclang ORPHANS its scsynth, which then
  holds the port and every later boot fails "exit code 1" -- `pkill -f "scsynth -u 57131"` first.
  09:40: running on system default @ 44.1 k (Multi-Output Device had no connected member).

## 2026-09-28 11:45 -- rehearsal sweep sets are LOCAL; breath36 player fixes; spatial renders
- `song_deconstruct/sweeps/<set>/<grain>/plane_NN_{lr,mid}.flac` (+ plane_NN.json): all eight 2-bar sets and the
  lowpass + highpass FULL sets pulled (6.4 GB, 13 MB/s via mobile01). The other six full sets stay on
  scratch-fast (`latentft_stereo/ladders/`). sweep_live.scd now globs *.flac as well as *.wav.
- breath36.scd: two player bugs fixed after Jon heard "each sample stopped midway" with 2 voices at gap 0:
  (1) the fraction->segment-index round trip repeated a segment ~3 % of the time (now an integer index per
  voice, remapped proportionally on a level change); (2) the segment crossfade was equal-power, which puts
  a +3 dB bump at every cut of identical material (now linear). Re-evaluated by Jon? -- not yet confirmed.
- Spatial fine-tune renders (other session, cluster job 2399927) are in
  `latentft-post-training/results/stereo-v1/ab/` with the stereo-v1 and mono renders; `stereo-v1_compare.RPP`
  there has all 11 aligned. Final stereo-v1 (250k) full-track render = my job 2399247, still pending.

## 2026-09-28 evening -- CHECKPOINT: show launchers, tabs, live wall, sweep player, metro on its own server

Entry points (all SuperCollider, select all + evaluate):
- `show_tabs.scd` -- ONE window, tabs 1-4: 36 BREATHS | PHANTOM PAIN SWEEP | WALL OF SOUND | METRONOME.
  Each patch builds into its tab via the `~stHost` hook (nil -> its own window, as before). nanoKONTROL2
  follows the selected tab. Default server: numBuffers 16384, maxNodes 8192, memSize 2^19.
- `show.scd` -- same four patches as separate windows (sets `~stHost = nil`); controller follows the
  front window. `show_stack.scd` -- older variant (windows stacked under a tab strip).
- `breath36.scd` -- breath-by-breath player, speed 1x..10x (latent time-warp renders), gap knob,
  nanoKONTROL2 faders = voice BLOCKS 4 5 4 5 4 5 4 5 (Jon). `~b36Version` \a (v1, ~21 s/voice, default)
  or \b (v2 breath36b_voices: random half of each performer's breaths, latent-collage assembly with
  setting B = gate -36 dB, min silence 400 ms, min seg 1.5 s, parity-preserving shuffle; render was
  13/36 done on mobile01 when the mobile01 tunnel dropped -- resume `B36_WORK=... breath36.py render`,
  then `sharp/build_b36b.sh`).
- `sweep_live.scd` -- in-memory ladder player: ONE synth, shared playhead, TWO readers, equal-power
  crossfade between neighbouring planes; plane slider drawn by the patch (redrawn 4 Hz, sound unthrottled).
  Sets = folders under song_deconstruct/sweeps/<set>/full* (centred-2-bar `full2bar` are Jon's pick).
- `wall_live.scd` -- bell.py's placement rule live; lowering a density fades the excess (newest first)
  over "fade-out when lowered" s; reverb IR unit-energy; limiter.
- `metro.scd` -- own scsynth (port 57131), output menu (default Scarlett 2i2 4th Gen; Multi-Output
  Device selectable), boots at the device's own rate first, stopped by default, resumes across switches.

Lessons that cost time today (so they are not repeated):
- SuperCollider Event keys that are ALSO method names return the method, not your value: set, synth,
  play, stop, mean, release (found so far). Use bracket access (`e[\key]`) or other names.
- Never put a `//` comment on a line whose code continues after the replaced span (it swallowed code twice).
- `Buffer.cueSoundFile`'s last arg is sent as an OSC message: never pass an action function there.
- A patch reloading must tear its previous instance down SYNCHRONOUSLY (onClose = nil, then free);
  a window's onClose runs later and freed the NEW instance's buffers (-> "No more buffer numbers").
- Headless test harness pattern: `Server.default = Server(\x, NetAddr("127.0.0.1", PORT))`,
  outDevice "ZoomAudioD" (silent), executeFile the patch, drive it from a fork, post TEST lines.
  Free the MIDIdefs in tests: Jon's nanoKONTROL2 otherwise steers the test instance too.

## 2026-09-29 checkpoint -- tab 5 (Rite of Spring), fader fixes, metro fallback, sweep Hz labels

- `show_tabs.scd` now has FIVE tabs (keys 1-5): ... | METRONOME | RITE OF SPRING. `show.scd` loads the
  same five as windows.
- `rite_live.scd` -- eight Rite of Spring concatenator renders (1929 recording, first 2:30) looping
  together from ONE synth / one playhead; faders default 0; all eight microtonal (list in `~rtPick`,
  files in concatenator-corpus/out/listen-rite1929/). nanoKONTROL2: sliders 1-8 levels, knob 5 master,
  PLAY/STOP. 20-ms dip at the loop seam.
- `sweep_live.scd` -- ORIGINAL row on top (plain playback of Phantom Pain, independent of the ladder);
  plane slider has Hz ticks built from each set's plane_NN.json (scales differ: band/notch 0.1-30 Hz
  log, lowpass 0.08-6.8 Hz linear, highpass 0.08-40 Hz); readout shows the plane's Hz. All 17 ladder
  sets are local (33 GB), incl. notch_3oct (zero fill, rendered today as job 2456420).
- nanoKONTROL2 hardware: faders 7 and 8 were sending on their own (fader 8: 114/117/119 at ~100 msg/s).
  breath36 and rite now filter it: a fader moves freely the way it is going, turning back needs TWO
  messages in a row >= 4 steps back; a fader lets go when its voices are changed elsewhere (mouse, or
  another fader while LINKED). Jon worked the faders and both went quiet (0 messages in 15 s).
  Sweep and wall do not have the filter yet.
- `metro.scd` -- if the named output (Scarlett) is not connected, it now boots on the system output
  with a warning instead of retrying forever (`~msForceDevice` default false).
- Frozen audio = the servers lost their device (default output switched to BTD 700 under them):
  `Server.killAll;` then evaluate show_tabs.scd.
- `sharp/latent_slow.py` + `sharp/latent_slow_out/` (ignored): latent SLOW-down 0.5x/0.25x leaves a
  10.8 Hz flutter; blending frames is worse than repeating them (lab journal LC-8).
- SLURM oddity: two submissions named `lad2b-notch_3oct` were "CANCELLED by 0" within seconds with no
  log; the same script under another name ran. Cause unknown (scheduler side).

## TODO (Jon, 2026-09-29, during rehearsal -- not started)

- **Phantom Pain original in sync with the sweep.** The "PLAY original" row in `sweep_live.scd` has its own
  playhead; it should play locked to the sweep's playhead (same position, same start/stop/seek), so the
  original and the ladder planes are sample-aligned.
- **Route that original to the headphones device** -- the Multi-Output / aggregate device the metronome
  (`metro.scd`, own server `~msServer`, port 57131) plays to -- instead of the main output. Likely: play it on
  the metro server (load phantom_pain.wav there), driven by the sweep's position/transport, since a server
  can only open one output device.
- **Paused, uncommitted:** `force_breath.scd` + `show_tabs_force.scd` (force perturbs the 36 breath voices
  around their centres; tested headless, see this session's notes). Commit and try after rehearsal.
