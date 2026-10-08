# Supra-Organism rig: student laptop version

The patches from the show (the 36 breaths, the Phantom Pain sweep through LatentFT planes, the wall of sound, and the
TORNADO ending) running on an ordinary Mac with **headphones**. What the room heard on quad speakers you hear as a
**binaural** mix on the laptop's normal output. The dancers' force sensors are **simulated**, so everything that
follows them moves by itself.

## 1. Install SuperCollider (once)

1. **SuperCollider 3.13 or newer** from https://supercollider.github.io/downloads. Drag it to Applications and open it once.
2. **sc3-plugins** (the ambisonics UGens) from https://github.com/supercollider/sc3-plugins/releases. Take the macOS
   zip that matches your SuperCollider version. In SuperCollider, run
   `Platform.userExtensionDir.openOS;` to open the Extensions folder, and put the unzipped `SC3plugins` folder there.
   Then, in Terminal (macOS blocks downloaded plugins otherwise):

       xattr -dr com.apple.quarantine ~/Library/Application\ Support/SuperCollider/Extensions/SC3plugins

3. **The Ambisonic Toolkit (ATK)**. In SuperCollider, evaluate (Cmd-Return on the line):

       Quarks.install("https://github.com/ambisonictoolkit/atk-sc3.git");

   then **Language > Recompile Class Library** (Cmd-Shift-L), then evaluate:

       Atk.downloadKernels; Atk.downloadMatrices;

   Wait until the post window says both are done (a few hundred MB).

## 2. Get the sound pack (once)

Download the `supra-organism` folder from the Dropbox link you were sent and unzip it anywhere, e.g. in Documents.
It is about 16.5 GB and holds the code (`rig/`) next to the sounds (`song_deconstruct/`, `wall_of_sound/`,
`concatenator-corpus/`). **Keep that layout:** the patches find the sounds relative to `rig/`.

## 3. Run it

1. Put headphones on (the mix is binaural: it only works on headphones).
2. Quit other big apps, browsers especially (see *Memory* below).
3. In SuperCollider: **File > Open** `supra-organism/rig/show_student.scd`, click into it, **Cmd-A**, **Cmd-Return**.
4. One window opens. The top line says how much memory your laptop has and what it is loading. After about 30 s
   it says **ready**.

Tabs (keys 1-6 switch while the window is focused):

| Tab | What it is |
|---|---|
| 1 36 BREATHS | the breathing voices, each morphing from breath to a harmonium pitch. Voices, morph sliders, speed, gap, pulse |
| 2 PHANTOM PAIN SWEEP | Phantom Pain through a ladder of LatentFT planes. **Pick a set from the menu first** (it loads for a few seconds), then PLAY and scrub the centre slider |
| 3 WALL OF SOUND | the wall: dyads, voices, chords |
| 4 TORNADO | the ending. START, BUILD, PEAK, HOLD, FADE OUT, HARD CUT |
| 5 FORCE | the six force sensors, simulated (press strength, hold, pause, contagion). TORNADO, the breaths and the sweep can follow them |
| 6 AMBI | the binaural decoder: HRTF choice, level, a test noise circling your head, where the breaths sit around you |

A Korg nanoKONTROL2, if you have one, works as in the show: it follows the selected tab.

## Memory

SuperCollider keeps every sound it plays in RAM. The full show needs about 17 GB, so `show_student.scd` sizes itself to your
laptop. At launch it checks total and free memory, sets a budget (60 % of total, and at most 90 % of what is free right now),
and picks the richest step that fits:

36 breath voices + every sweep plane → 36 + 41 planes → 36 + 21 → 30 + 21 → 24 + 21 → 24 + 11 → 18 + 11 → 12 + 11

Fewer breath voices still include every performer. Fewer sweep planes are the same ladder in coarser steps. To force a step,
put a line like this above the code before you run it:

    ~studentVoices = 24;  ~studentPlanes = 21;     // or:  ~studentBudgetGB = 12;

then `Server.killAll;` and run the file again. If you go over your laptop's real memory it will not crash; it will
stutter. Then go down a step.

## If something goes wrong

- **"the audio server did not start"**: usually the Mac's input and output run at different sample rates. Open
  *Audio MIDI Setup* and set both to 48000 Hz. Or choose the output by name:
  `~studentOutDevice = "External Headphones";` (`ServerOptions.outDevices` lists the names). Then `Server.killAll;` and run again.
- **"the Ambisonic Toolkit is missing" / "kernels are not downloaded"**: step 1.2 or 1.3.
- **"the sound pack is missing"**: `rig/` is not next to `song_deconstruct/` etc. Re-check step 2.
- **Silence on tab 2**: a sweep set has to be chosen from the menu, then PLAY.
- **Clicks, dropouts**: close apps, or force a smaller step (*Memory*).
- To start over: close the window, `Server.killAll;`, run `show_student.scd` again.

For Jon: the pack is built by `rig/tools/build_student_pack.py` (see its header) from the `student` branch.
