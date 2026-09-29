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
