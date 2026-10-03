# Show day checklist (written 2026-10-02 night, for Future Fest 2026-10-03)

## Before launching SuperCollider
1. **Plug in the Fireface UCX II** (main outputs, AMBI quad, lav on XLR 1) and the **BTD 700** (in-ears, Auracast).
   Plug the dongle into a port on the Mac itself, not a hub.
2. **Keep the BTD 700 broadcasting:** `btd_keepalive status` should say *running*. If not: `btd_keepalive start`.
   It plays -70 dBFS pink noise to the BTD 700 from outside SC, so the headphones stay joined through SC reboots.
   The launcher starts it too. Never stop it during rehearsal or the show.
3. **Never change the BTD 700's sample rate** (a rate change restarts the broadcast; the headphones drop and may not rejoin).
   `audiorate` shows every device's rate; `audiorate rig` (the launcher runs it) leaves the BTD alone and moves the Fireface to match.
4. If someone's AirPods / earbuds connect to this Mac they can grab the default input (call mode, 16-32 kHz). `audiorate input MacBook`
   puts it back; a stuck headset needs `sudo killall coreaudiod` (then relaunch SC).

## Launch
- Evaluate `rig/dev/show_tabs_dev.scd` **once**. Watch the post window for `tabs: rig sample rate = 48000`, `METRO_READY ... BTD 700 @ 48000`,
  the main server on the Fireface at 48000, and `SHOW_TABS_READY`.
- FORCE tab (6): switch the source to the **live OSC** (Mark-David's sensors, port 7500), not the simulator.
- METRONOME tab (4): the in-ear row = BTD 700. Tick **mic** for the lav (off at every load). MASTER fader + FADE IN / OUT at the top.

## The ending: TORNADO tab (12, key =)
- BUILD (Korg fader 1) = where the ending is; AUTO creeps it, CLIMAX (Korg >>) glides it to 100 %, HOLD (Korg CYCLE) freezes it.
- At 100 % it stays at full intensity until you act: FADE OUT (Korg SET) or **HARD CUT (Korg REC)**.
- START / STOP = Korg PLAY / STOP. Selecting the tab gives it the Korg; TRACK < > passes the Korg on.
- Needs the AMBI tab (quad + binaural) and the FORCE tab on live OSC.

## Fades everywhere
METRONOME, PHANTOM PAIN SWEEP, FOLLOW, SOLO, TORNADO have MASTER faders with FADE IN / FADE OUT (fade time box). WALL and RITE had them already.

## If something goes wrong
- No in-ears: `btd_keepalive status`, then `audiorate` (is the BTD 700 there, at 48 kHz?).
- AMBI tab error about a sample rate (e.g. 32000): the main server booted at a wrong rate -- run `audiorate rig`, relaunch SC.
- Metronome posts `LAV OFF`: the in-ear device and the Fireface do not share a rate; `audiorate` shows which.
