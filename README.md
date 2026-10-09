# Supra-Organism: student laptop rig

The live SuperCollider patches from *Supra-Organism*, set up to run on an ordinary Mac with **headphones**:

- **36 BREATHS**: the cast's breathing voices, each morphing from breath into a harmonium pitch
- **PHANTOM PAIN SWEEP**: Phantom Pain scrubbed through a ladder of LatentFT (latent Fourier transform) planes
- **WALL OF SOUND**: dyads, voices and chords
- **TORNADO**: the ending

In the show these played on quad speakers. Here the same ambisonic sound field is decoded **binaurally** to the
laptop's normal output, so you hear the room's placement on headphones. The dancers' force sensors are **simulated**,
so everything that follows them moves by itself. You need no audio interface, second device or sensors.

## 1. Download everything

**https://www.dropbox.com/scl/fo/3ubegot2yujmmeczd9bev/AI67bOLAt0wWuIsggn599wY?rlkey=f6gqw2wpqi6wa1pv7dut5a72n&dl=0**

Open the link, click **Download**, and unzip the result anywhere (Documents is fine). It is about 16.5 GB and holds
**both the code and the sounds**, so you don't need to download anything from this GitHub page. You get one folder:

```
supra-organism/
  rig/                 the code (this repository), plus the breath voices and TORNADO sounds
  song_deconstruct/    Phantom Pain and the LatentFT sweep planes
  wall_of_sound/       the wall's stems
  concatenator-corpus/ the ocean recordings the breaths follow
```

**Don't rearrange it.** The patches find the sounds relative to `rig/`.

You need about 35 GB of free disk while unzipping (17 GB afterwards) and at least 8 GB of RAM. 16 GB or more is
better (see *Memory*).

## 2. Install SuperCollider and its add-ons (once)

1. **SuperCollider 3.13 or newer** from https://supercollider.github.io/downloads. Drag it to Applications and open it once.
2. **sc3-plugins** (the ambisonics UGens) from https://github.com/supercollider/sc3-plugins/releases. Take the macOS
   zip that matches your SuperCollider version. In SuperCollider, evaluate
   `Platform.userExtensionDir.openOS;` to open the Extensions folder, and put the unzipped `SC3plugins` folder there.
   Then, in Terminal (macOS blocks downloaded plugins otherwise):

       xattr -dr com.apple.quarantine ~/Library/Application\ Support/SuperCollider/Extensions/SC3plugins

3. **The Ambisonic Toolkit (ATK).** In SuperCollider, evaluate (click on the line, Cmd-Return):

       Quarks.install("https://github.com/ambisonictoolkit/atk-sc3.git");

   then **Language > Recompile Class Library** (Cmd-Shift-L), then evaluate:

       Atk.downloadKernels; Atk.downloadMatrices;

   Wait until the post window says both are done (a few hundred MB).

## 3. Run it

1. Put headphones on. The mix is binaural, so it only works on headphones.
2. Quit other big apps, browsers especially (see *Memory*).
3. In SuperCollider: **File > Open** `supra-organism/rig/show_student.scd`, click into it, **Cmd-A**, **Cmd-Return**.
4. One window opens. The top line says how much memory your laptop has and what it is loading. After about 30 s
   it says **ready**.

### The tabs

Keys 1 to 6 switch tabs while the window is focused.

| Tab | What it is |
|---|---|
| 1 36 BREATHS | the breathing voices. Voices, morph sliders, speed, gap, pulse |
| 2 PHANTOM PAIN SWEEP | Phantom Pain through a ladder of LatentFT planes. **Pick a set from the menu first** (it loads for a few seconds), then PLAY and scrub the centre slider |
| 3 WALL OF SOUND | the wall: dyads, voices, chords |
| 4 TORNADO | the ending. START, BUILD, PEAK, HOLD, FADE OUT, HARD CUT |
| 5 FORCE | the six force sensors, simulated (press strength, hold, pause, contagion). TORNADO, the breaths and the sweep can follow them |
| 6 AMBI | the binaural decoder: HRTF choice, level, a test noise circling your head, where the breaths sit around you |

The sweep sets are `lowpass/full`, `highpass/full`, `notch_2oct/full2bar` and `band_2oct/full2bar`.

A Korg nanoKONTROL2, if you have one, works as in the show: it follows the selected tab.

## Memory

SuperCollider keeps every sound it plays in RAM, unpacked to 32-bit float, so a sound costs more in memory than on
disk. The full show needs about 17 GB, so `show_student.scd` sizes itself to your laptop. At launch it checks total
and free memory and sets a budget: 60 % of total, and at most 90 % of what is free right now. The wall, TORNADO and
the audio server always take about 4.3 GB. With the rest it picks the richest step that fits:

36 breath voices + every sweep plane → 36 + 41 planes → 36 + 21 → 30 + 21 → 24 + 21 → 24 + 11 → 18 + 11 → 12 + 11

A 16 GB laptop typically gets 18 voices + 11 planes. Fewer breath voices still include every performer. Fewer sweep
planes are the same ladder in coarser steps; the scrub still crossfades between neighbours.

To force a step, put a line like this at the top of `show_student.scd` before you run it:

    ~studentVoices = 24;  ~studentPlanes = 21;     // or:  ~studentBudgetGB = 12;

then evaluate `Server.killAll;` and run the file again. Going over your laptop's real memory won't crash it, but it
will stutter. Then go down a step.

## If something goes wrong

- **"the audio server did not start"**: usually the Mac's input and output run at different sample rates. Open
  *Audio MIDI Setup* and set both to 48000 Hz. Or choose the output by name:
  `~studentOutDevice = "External Headphones";` (`ServerOptions.outDevices` lists the names). Then `Server.killAll;` and run again.
- **"the Ambisonic Toolkit is missing"** or **"the ATK kernels are not downloaded"**: redo step 2.2 or 2.3.
- **"the sound pack is missing or in the wrong place"**: `rig/` is no longer next to `song_deconstruct/` and the
  others. Check the layout in step 1.
- **Silence on tab 2**: choose a sweep set from the menu first, then press PLAY.
- **Clicks or dropouts**: close apps, or force a smaller step (*Memory*).
- **To start over**: close the window, evaluate `Server.killAll;`, and run `show_student.scd` again.

## If the code is updated

The Dropbox folder always holds the current code. You only need the new code, not the sounds again: on this GitHub
page click **Code > Download ZIP**, unzip it, and copy everything inside over your `supra-organism/rig/` folder,
replacing files when asked.

## What is in this repository

| File | What it is |
|---|---|
| `show_student.scd` | the launcher: checks the install, sizes to memory, opens the six tabs |
| `dev/breath36.scd` | 36 BREATHS |
| `dev/sweep_sync.scd` | PHANTOM PAIN SWEEP |
| `dev/wall_live.scd` | WALL OF SOUND |
| `dev/tornado_engine.scd` | TORNADO |
| `force_hub.scd` | FORCE (sensors or simulation) |
| `dev/ambi.scd` | AMBI (binaural and quad decoders) |
| `tools/build_student_pack.py` | builds the Dropbox pack from the full archive (see its header) |

The other files are the show rig and earlier experiments, kept for reference; `show_student.scd` doesn't use them.
