# rig/dev: variants in progress (2026-09-29)

Everything here is **new files only**. The stable rig (`rig/show_tabs.scd` and every patch it loads) was not
changed by any of this. When in doubt, use the stable one.

## Files

| file | what it is |
|---|---|
| `show_tabs_dev.scd` | the DEV launcher: same window and tabs as `show_tabs.scd`, with the three variants below swapped in and a 7th tab, BREATH FORCE. Loads `breath36`, `wall_live`, `rite_live`, `force_hub` unchanged from `rig/`. |
| `metro_dual.scd` | `metro.scd` plus a second click on the **interface** (the main server's output: Scarlett now, Fireface later). Per path: on/off tick-box and a big **volume slider in dB** (-60..+6, bottom = off, dB readout). Interface path also has an output-pair menu and a **delay** (0-500 ms) to meet late Bluetooth headphones. Headphone tick-box mutes without restarting the server. The interface click is triggered by every beat the metronome server reports, so the two can never drift apart. |
| `sweep_sync.scd` | `sweep_live.scd` with the **original locked to the sweep**: it plays, stops and seeks with the sweep (no transport of its own). Output: main output (sample-locked to the ladder's playhead), the metronome's headphone device (the original is loaded on the metro server, driven by timestamped bundles, re-seeked if > 30 ms off twice in a row), or both. Level in dB, offset (ms, main path), headphone lead (ms, plays the headphone copy ahead to meet Bluetooth latency). Readout: bar.beat at 110.36 BPM, first downbeat 0.134 s. |
| `force_breath.scd` | force perturbs the 36 breath voices around their centres (6 singles, 15 pairs together, 15 pairs against), depth 0-50 %, AC / DC / DC-vs-average / slow-activity signal, plus **slow signals** (5-s activity and slow level per sensor, on `~fbSlowBus`). Off / perturb / grid (`force_layer.scd`). Korg REC toggles it while the 36 BREATHS tab owns the controller. |

## Trying it (after rehearsal)

```
Server.killAll;
```
then open `rig/dev/show_tabs_dev.scd`, select all, evaluate. Keys 1-7 switch tabs. To go back: `Server.killAll;` and
evaluate `rig/show_tabs.scd`.

For a Fireface with more than 2 outputs, set `Server.default.options.numOutputBusChannels` (e.g. 8) before the first
boot so the metronome's output-pair menu offers them.

## Tested headless (light, during rehearsal: own test servers on a silent device, tiny data)

- **metro_dual**: interface click follows the metro beats (4 clicks in 3 s at 80 BPM), off = none, 200 ms delay lands
  203-213 ms after the beat, output pair 3-4 works, headphone mute sets the metro synth to 0 while it keeps beating,
  both dB volume sliders set the right amplitude (-12 dB -> 0.251, -20 dB -> 0.1), bottom = off.
- **sweep_sync**: with a 3-plane test ladder cut from phantom_pain.wav, the locked original inverted against plane 1
  cancels to -100 dB (sample-locked), also after a seek; stopped = silent. Headphone copy on a second test server:
  follows play / seek / stop within 3-24 ms, recovers from being knocked 8 s off (1 re-seek), lead 200 ms -> +225 ms;
  when the metronome server quits, the status says so.
- **force_breath**: loads without breath36 (warns cleanly), 36 voice synths + slow synth, AC 0.6 on sensor 1 ->
  +18 % on voice 1 at 30 % depth, 5-s activity and slow level respond.
- All four files compile.

## Not yet tested (needs the real thing)

- The full DEV launcher with breath36 loaded (21 GB): load time, all 7 tabs, force_breath driving the real voices.
- Real devices: the interface click on the Scarlett / Fireface; the headphone original on the Multi-Output device.
- Bluetooth delay / lead values: set by ear.
- sweep_sync with the real full-track sets (the ladder is 321.9 s, the original 319.9 s: the original simply ends 2 s
  early; offset 0 assumes plane sample 0 = track sample 0 -- check by ear, adjust "offset ms").

## Promoting a variant to the stable rig

When a variant has been played for real: copy it over the stable file in `rig/` (for sweep_sync, fix its
two-levels-up paths back to one level: `here +/+ ".." +/+ "song_deconstruct"`), point `show_tabs.scd` / `show.scd` at it,
run the headless tests in HANDOFF.md, commit, push. Do it between rehearsals, not during.

## In-ear tracks (metro_dual.scd, added 2026-09-29)
The METRONOME tab has an IN-EAR TRACK row: a menu of the audio files in `supra-organism/in_ears/` (wav / aif /
flac, mono or stereo), play/stop, position (seek), loop, and its own dB volume. It plays on the metronome's
server, i.e. to the in-ear headphones device, independent of the click. Add a file to `in_ears/` and press
rescan. Present: Phantom Pain (a link to concatenator-corpus/targets/), Old Town Road (yt-dlp, 48 kHz).
Tested headless: play, -20 dB volume (-40 -> -59 dB), seek, stops itself at the end, loop wraps, stop = silent.

## FORCE CONCAT (tab 8, dev/force_concat.scd + concatenator-corpus/live_force_shim.py, 2026-09-30)
1. SINES: Marc-Andre's ForceSensorSimulator.maxpat x6 -- loudness = DC x sensitivity, pitch = base note + AC x amount (Hz;
   default 1000, the patch used 4000). Base notes (MIDI), mutes, on/off, dB volume. Main server, outs 1-2.
2. LIVE CONCATENATOR: Python process (started/stopped by the tab, pid tracked, killed on close) that synthesizes the same
   six sines from /fc/force (sent 30 Hz from ~fhValues) and has The Concatenator rebuild them from the corpus in the menu
   (all 46 folders under concatenator-corpus/corpus, labelled with size; >0.7 GB marked SLOW/LARGE), playing straight to
   the chosen output device via pyaudio at 44.1 kHz. Knobs: level (dB), wet, temperature, grain time. Changing corpus or
   device restarts the process ("loading ... s"). Log: /tmp/force_concat_<langPort>.log.
Measured: offline 30 s renders, v9-aug28-all (24 min corpus) load 1.8 s, 5.9 ms/frame (max 6.9), RSS 5.0 GB;
v7-harmonium-all (21 min) load 1.6 s, 6.2 ms (max 8.6), 4.3 GB; live on ZoomAudioD 48 kHz: 7-8 ms/frame vs 23.2 ms
budget, paced in real time, 2 startup overruns. RAM ~10 GB per corpus-hour: v10-everything / aug-* need 15-30 GB.
Untested: real output device, running alongside the full live show, the dancers' real force data.

## 2026-10-01: force in the 36 BREATHS window, tiled faders, AMBI tab, Fireface first
- **breath36.scd, FORCE -> voices 1-6:** above voice sliders 1-6, a toggle (S1..S6) and an offset knob: morph = slider +
  0.5 x knob x sensor k, clipped 0..1 (knob down = nothing, up = +-half the range). Row below the sliders: signal AC / DC,
  sensitivity, smoothing; CENTRAL -> speed (toggle, knob, signal: ensemble activity 5 s / slow level / central DC / AC;
  speed = slider + 0.5 x knob x c x (levels - 1), levels change at each voice's next breath). Uses its own input on the
  control synth (`fbus/famt`), separate from force_breath's `modbus/modamt`, so tab 7 and this never fight. Reads ~fhBus
  (FORCE tab). Headless test (1x voices only, MIDI off): 11/11 pass. Central -> speed arithmetic tested earlier, not with
  real speed levels loaded.
- **nanoKONTROL2 faders TILED:** fader g = voices g, g+8, g+16, g+24, g+32 (faders 1-4 five voices, 5-8 four). With the voices
  tiled a/g/r/s, each fader is one performer (1 and 5 anna, 2 and 6 grisha, 3 and 7 raymond, 4 and 8 sora). Tab 7's grid
  draws the same columns.
- **ambi.scd (tab 8 AMBI):** first-order ambisonics with ATK v5.0.7 (sc3-plugins 3.14.1 arm64, ATK matrices v1.0.3 -- all
  installed 2026-10-01; the old x86 sc3-plugins are in SuperCollider/archive/). Quad decode to outs 3-6 (speaker map +
  identify), binaural to Phones 1 = outs 7/8 on the Fireface UCX II, HRTF menu, test source, breath36 "AMBI" tick-box.
- **show_tabs_dev.scd:** main output prefers the Fireface UCX II (name-prefix match: CoreAudio adds the serial), then Studio
  1824c, then Scarlett.
- **rite_live.scd (dev copy, tab 5):** ambisonic (render k at its own direction, clockwise from front, 45 deg apart; stereo as
  a 30-deg arc; default on once AMBI loads), per-render time offsets against the shared playhead (0..0.8 s), GO 1-8
  (buttons + Korg S buttons in the RITE tab) with fades and a fresh random offset, SWIRL (N neighbours in circle order,
  step ms apart, growing offsets), ALL (8-swirl), SCATTER, RE-ROLL (1.5 s glide), HUSH. Headless test passes (direction,
  swirl timing and offsets, scatter, stereo fallback).
- **ambi.scd quad map fixed:** the default sent back-left to out 4 and front-right to out 6; now circle order 3 FL, 4 FR,
  5 BR, 6 BL. A session still holding the old map is corrected on reload. Wall + breaths default to AMBI when the tab loads.
- **metro_dual.scd OUTPUTS box:** one 2 x 2 matrix at the top of tab 4 -- SPEAKERS (main server: output pair, delay ms) /
  IN-EARS (metro server: device menu, the Multi-Output Device) x CLICK / TRACK, each an on/off tick + dB. The in-ear track
  also plays on the speakers: loaded on both servers, started with the same timestamp (+ speaker delay), the speakers'
  copy re-cued if > 30 ms off twice in a row; readout "speakers vs in-ears: N ms off, re-cued Nx". Headless two-server
  test passes (both play aligned, untick = silent, 1-s knock re-cued to 17 ms, stop frees both).
