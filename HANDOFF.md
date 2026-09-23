# supra-organism rig — handoff (paused 2026-09-23, mid-afternoon, on the MIT laptop)

**Goal (Jon, 2026-09-23):** one live SuperCollider patch for tonight's rehearsal that builds on the
existing studio rig (FlowEdit morph + latent collage + concatenator, 4-lane capture strip,
nanoKONTROL2) and adds panes for **wall of sound**, **metronomes**, and the **LatentFT pieces**.
Jon: "I need a live supercollider patch where I can do all this stuff."

Work was paused right after the survey below; **no new panes have been written yet.**

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

## Proposed next steps (not started)

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
