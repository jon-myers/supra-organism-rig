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
