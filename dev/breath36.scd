/*
DEV COPY (rig/dev/breath36.scd, 2026-09-30): QUAD. Each breath is panned around 4 outputs (~b36QuadOuts, SuperCollider
bus numbers, listed in CIRCLE order around the room; default [2, 3, 4, 5] = the interface's physical outputs 3-6).
Voice positions: the stereo layout's max-spread order, mapped onto the full circle. Tick-box "quad" switches
new breaths between quad and stereo (outs 1-2). The main server must have >= 6 outputs (dev launcher opens 8).
Otherwise identical to ../breath36.scd.

breath36.scd -- 36 individual breaths, each morphing breath -> its own harmonium pitch,
with a stepped SPEED axis, a GAP knob, and the nanoKONTROL2 as control surface. One patch.

VOICES: 36 different ~21 s stretches of the July 23 breathing takes (anna, grisha, raymond,
sora), each looped from its own breath segments to its own length (120-160 s, no two alike),
pitch targets C Eb F Bb x octaves 2-5 (breath36.py, harmonium-v2 spn_hz LoRA). Slots are
TILED across performers (anna, grisha, raymond, sora, anna, ...).

PLAYER: each voice is played BREATH BY BREATH -- segments between its detected breath onsets
(sharp/onsets*.json, loudness swells), each with a short sine fade at the cut (seg fade,
default 40 ms). With gap = 0 the segments run back to back: the loop as it was. Gap adds a
rest after every breath, mean "gap" seconds, each rest scaled by a per-voice nCVI sequence
(gap nCVI menu; 0 = even rests). Voices that are off keep advancing silently, so they keep
their independent positions.

SPEED: levels 1.5x .. 10x = the 8 morph steps re-rendered through the Stable Audio 3
autoencoder with the latent time-warped (sharp/render_speed_axis.py; local speed wanders in
irregular segments). Each voice sits on one discrete level = round(speed slider + own offset),
and changes level AT ITS NEXT BREATH -- never mid-breath, never a blend of two speeds.

nanoKONTROL2 (factory CC map, soft takeover on every fader/knob):
  sliders 1-8  breath -> harmonium morph, TILED (2026-10-01): fader g = voices g, g+8, g+16, g+24, g+32
               (faders 1-4 five voices, 5-8 four; with the voices tiled a/g/r/s, each fader is ONE performer).
               Before 2026-10-01: a BLOCK of consecutive voices: 4 5 4 5 4 5 4 5 (= 36),
               i.e. slider 1 = voices 1-4, 2 = 5-9, 3 = 10-13, ... 8 = 32-36 (voices are tiled a/g/r/s)
  S / M        solo / mute that group      R 1-8  FORCE on/off for that group (2026-10-02; off at every load)
  << (REW)     re-roll speed offsets (was R1)      REC  PULSE on/off      >> (FF)  OCEAN on/off      CYCLE  link all sliders
  knobs 1-8  FORCE offset depth of fader group g (sensors 1-6 -> groups 1-6, CENTRAL -> 7, 8 none) (2026-10-01;
             volume / gap / voices / speed / spread / glide / fade / nCVI are on screen only. Was: 1 voices, 2 speed
             level, 3 spread, 4 glide, 5 volume, 6 fade, 7 gap, 8 nCVI)
  PLAY / STOP  voices back on at the last count / all off
Server-side modulation per voice: ~b36SetMod.(i, busIndex, amt) adds In.kr(bus)*amt to the morph.
API: ~b36Set.(n), ~b36SetMorph.(i, v), ~spSetLevel.(i, k), ~spSetAll.(x), ~gpSet.(secs).
RAM: ~6.6 GB (1x) + ~14 GB for all seven speed levels; set ~b36SpeedLevels = [2, 4, 8] (or [])
before evaluating to load fewer. Select all, evaluate.
*/
(
~b36OutDevice = "External Headphones";   // nil = system default
// which render set: \b = v2 (each voice a random HALF of its performer's breaths, ~90 s; 2026-09-28), \a = v1 (~21 s each)
~b36Version = ~b36Version ? \a;   // switch to \b once breath36b_voices is complete
~b36Dir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ ".." +/+ if (~b36Version == \a) { "breath36_voices" } { "breath36b_voices" };
~b36OnsetSuffix = if (~b36Version == \a) { "" } { "_b" };
~b36Sharp = PathName(thisProcess.nowExecutingPath).pathOnly +/+ ".." +/+ "sharp";
~b36SpeedLevels = ~b36SpeedLevels ? [1.5, 2, 3, 4, 6, 8, 10];
~b36Midi = ~b36Midi ? true;
~b36QuadOuts = ~b36QuadOuts ? [2, 3, 4, 5]; ~b36Quad = true;   // QUAD by default again (2026-09-30, Jon)   // quad outputs, in circle order
~b36N = 0; ~b36Fade = 3.0; ~b36Amp = 0.8; ~b36Comp = false; ~b36Spread = 0.9;
// PULSE (2026-10-02, Jon): rhythmic UNISON breath attacks -- every playing voice starts its next breath together on a beat.
// Beats from the METRONOME (its /msBeat, so the breaths follow its tempo and glides) or an own tempo; every N beats; each breath
// lasts gate x the pulse length (then fades); loosen = up to N ms of random spread; offset = ms later / earlier than the beat.
// Each pulse is scheduled one pulse AHEAD (on the predicted beat), so the server never gets it late. While PULSE is on the free-running players wait, keeping their places.
~b36Pulse = ~b36Pulse ? (on: false, src: 0, every: 1, bpm: 60, gate: 0.8, jitter: 0, offset: 0);
~b36Pulse[\on] = false;   // never on at load
// TIERS (2026-10-02, Jon): mode 1 = a probabilistic polyrhythm on the 16th grid. Voices interleave into three tiers of 12
// (voice 1 -> A, 2 -> B, 3 -> C, 4 -> A ...): A may attack only on the beat, B on the beat or the off-beat 8th, C on any 16th
// but at most maxC per beat. Each voice rolls its own dice per allowed slot (pA / pB / pC), so each does its own thing and
// is often silent. Each breath lasts gate x its tier's subdivision (beat / 8th / 16th). mode 0 = unison (all on each pulse).
// OCEAN (2026-10-02, Jon): PULSE still decides WHEN; OCEAN decides WHICH breath -- from the firing voice's own breaths, the one
// whose spectrum (24-band shape of its first 0.4 s, sharp/ocean_match/features.py) is closest to the ocean recording AT THAT
// MOMENT (a random pick among the topK closest, so it does not repeat). loud: 0 = level as is .. 1 = follows the ocean's swell
// (+-18 dB). hear: the ocean itself underneath (215 goes into the AMBI field as ambiX when the AMBI tab is up). Matched breaths
// use the 1x renders (where the features were measured).
~b36Ocean = ~b36Ocean ? (on: false, target: 0, topK: 3, loud: 0.6, hear: false, hearDb: -18);
~b36Ocean[\on] = false; ~b36Ocean[\hear] = false;
[[\mode, 0], [\pA, 0.35], [\pB, 0.25], [\pC, 0.15], [\maxC, 2]].do { |kv| ~b36Pulse[kv[0]] = ~b36Pulse[kv[0]] ? kv[1] };
~b36Hpf = ~b36Hpf ? 70;   // breath LOW CUT in Hz (24 dB/oct), new breaths pick it up; 10 = effectively off
~b36Glide = 0.5;    // seconds for a morph slider move to settle
~spP = (x: 0, spread: 0.5);
~gpP = (mean: 0, ncviIdx: 3, fade: 0.04);
// FORCE per tiled fader group (2026-10-01, Jon): sensor -> every voice of its group:  morph = slider + 0.5 * knob * s, clipped 0..1
// (knob down = nothing, up = +-half the range). s = AC (press up, release down, settles in ~1.6 s) or DC (press = up).
// Reads force_hub.scd's buses (~fhBus), so the FORCE tab must be loaded. CENTRAL -> SPEED: speed level =
// speed slider + 0.5 * knob * c * (levels - 1), c = ensemble activity (5-s |AC| of central) / slow level / DC / AC.
~b36F = ~b36F ? (on: true ! 8, knob: 1 ! 8, signal: 0, sens: 1, smooth: 0.1);
if (~b36F[\on].size < 8) { ~b36F[\on] = ~b36F[\on].extend(8, true); ~b36F[\knob] = ~b36F[\knob].extend(8, 1) };
~b36F[\on] = false ! 8;   // the FORCE mapping is OFF on every load (2026-10-02, Jon): tick a fader group to bring force in
// PER FADER GROUP (2026-10-01, Jon): group g = voices g, g+8, g+16, ... (the tiled Korg fader); Korg knob g = its offset
// depth. Sensor per group: 1-6 -> sensors 1-6, 7 -> CENTRAL, 8 -> none (yet).
~b36FSensorOf = [0, 1, 2, 3, 4, 5, 6, nil];
~b36FC = ~b36FC ? (on: false, knob: 1, signal: 0, smooth: 1);
~b36FC[\delay] = ~b36FC[\delay] ? 0;   // seconds: the speed follows the ensemble this late (0-60)

s = Server.default;
if (s.serverRunning.not) {
	~b36OutDevice !? {
		if (ServerOptions.outDevices.includesEqual(~b36OutDevice)) {
			s.options.outDevice = ~b36OutDevice;
		} {
			("OUTPUT DEVICE '" ++ ~b36OutDevice ++ "' NOT AVAILABLE -- using system default").warn;
			s.options.outDevice = nil;
		};
	};
	s.options.numInputBusChannels = 0;
	s.options.inDevice = "MacBook Pro Microphone";   // see metro_slider.scd
};
s.options.numBuffers = s.options.numBuffers.max(16384);
s.options.memSize = 2.pow(18);
s.options.maxNodes = 4096;

s.waitForBoot {
	var jp = ~b36Dir +/+ "voices.json", meta, nv, ns, slots, chosen, names, order, performers, levelNames;
	var onsData, onsSpeed, ioiData, gapLevels, pcs = ["C", "Eb", "F", "Bb"];
	// ---- tear the previous instance down NOW, before allocating: its window's onClose would otherwise run
	// a moment later and free/stop the NEW instance's buffers and players (and 2 x 2304 buffers > the limit)
	~b36Win !? { ~b36Win.onClose = nil; if (~b36Win.isClosed.not) { ~b36Win.close } };
	~b36Rout !? { ~b36Rout.stop }; ~b36Players !? { ~b36Players.do(_.stop) }; ~b36Synths !? { ~b36Synths.do(_.free) };
	~b36Silent !? { ~b36Silent.free }; ~b36MorphBus !? { ~b36MorphBus.free }; ~b36GainBus !? { ~b36GainBus.free }; ~b36VolBus !? { ~b36VolBus.free };
	~b36FCRout !? { ~b36FCRout.stop }; ~b36FCSyn !? { ~b36FCSyn.free }; ~b36FCSyn = nil; ~b36FCBus !? { ~b36FCBus.free };
	~b36LoadRout !? { ~b36LoadRout.stop };
	~spBufs !? { ~spBufs.flat.do { |b| b !? { b.free } } }; ~spBufs = nil; ~b36Bufs = nil; ~b36Players = nil;
	MIDIdef(\b36cc).free; MIDIdef(\b36note).free;
	s.sync;
	if (File.exists(jp).not) { ("no " ++ jp ++ " -- run breath_morph.py assemble").postln } {
	meta = File.readAllString(jp).parseJSON;
	// ---- tile the voices across performers: a g r s a g r s ... ----
	performers = meta["voices"].collect { |v| v["performer"] }.asSet.asArray.sort;
	order = [];
	block { |break| inf.do { |k|
		var added = false;
		performers.do { |p| var idx = meta["voices"].detectIndex { |v, j| (v["performer"] == p) and: { order.includes(j).not } };
			idx !? { order = order.add(idx); added = true } };
		if (added.not) { break.value } } };
	meta["voices"] = order.collect { |j| meta["voices"][j] };
	~b36Meta = meta;
	nv = meta["voices"].size;
	ns = meta["slots"].size;
	names = meta["voices"].collect { |v| v["performer"] };
	~b36Notes = meta["voices"].collect { |v| v["note"] };
	levelNames = [1] ++ ~b36SpeedLevels;
	~b36LevelNames = levelNames;

	// ---- breath onsets per (voice, level), gap sequences per voice ----
	onsData = File.readAllString(~b36Sharp +/+ ("onsets" ++ ~b36OnsetSuffix ++ ".json")).parseJSON;
	onsSpeed = if (File.exists(~b36Sharp +/+ ("onsets_speed" ++ ~b36OnsetSuffix ++ ".json"))) { File.readAllString(~b36Sharp +/+ ("onsets_speed" ++ ~b36OnsetSuffix ++ ".json")).parseJSON } { IdentityDictionary["by_file" -> IdentityDictionary.new] };
	ioiData = File.readAllString(~b36Sharp +/+ "iois.json").parseJSON;
	gapLevels = ioiData["ncvi_levels"].collect(_.asFloat);
	~spOnsets = meta["voices"].collect { |v|
		var orig = v["voice"].asInteger - 1, base = v["files"][0].splitext[0];
		levelNames.collect { |lv, k|
			var arr = if (k == 0) { onsData["voices"][orig] } { onsSpeed["by_file"][base ++ "_x" ++ lv.asString] };
			if (arr.isNil or: { arr.size == 0 }) { [0.0] } { [0.0] ++ arr.collect(_.asFloat) };   // always a segment from 0
		};
	};
	~gpSeq = meta["voices"].collect { |v| ioiData["voices"][v["voice"].asInteger - 1].collect { |seq| seq.collect(_.asFloat) } };

	// ---- synths: one control synth per voice (morph + gain buses), one short synth per breath ----
	// modbus/modamt: force_breath / force_layer (tab 7).  fbus/famt: this window's FORCE per fader group (independent)
	SynthDef(\b36Ctl, { |morphOut, gainOut, morph = 0, glide = 0.5, modbus, modamt = 0, on = 0, fade = 3,
		fbus, famt = 0, fsens = 1, fsmooth = 0.1|
		Out.kr(morphOut, (VarLag.kr(morph, glide) + (In.kr(modbus) * modamt)
			+ (Lag.kr((In.kr(fbus) * fsens).clip(-1, 1), fsmooth) * famt.lag(0.1))).clip(0, 1));
		Out.kr(gainOut, VarLag.kr(on, fade, warp: \sin));
	}).add;
	// CENTRAL -> speed: activity = |AC of central| averaged ~5 s x3 (0..1), slow level = central DC averaged ~5 s
	SynthDef(\b36Central, { |in, out, csig = 0, csmooth = 1|
		var dc = In.kr(in + 6), ac = In.kr(in + 13), c = exp(-1 / (5 * ControlRate.ir));
		var x = Select.kr(csig, [(OnePole.kr(ac.abs, c) * 3).clip(0, 1), OnePole.kr(dc, c), dc, ac]);
		Out.kr(out, Lag.kr(x.clip(-1, 1), csmooth));   // the DELAY is applied language-side (~b36FCDelayed)
	}).add;
	SynthDef(\b36Seg, { |hpf = 70, start = 0, dur = 1, fade = 0.04, morphBus, gainBus, pan = 0, amp = 0.8, comp = 1, out = 0, vol = 0.8|
		var bufs = \bufs.kr(0 ! ns);
		var m = In.kr(morphBus) * (ns - 1);
		// LINEAR fades: consecutive segments are the same continuous material, and linear in/out sum to exactly 1 across the overlap
		var env = EnvGen.kr(Env.linen(fade, (dur - fade).max(0.001), fade, 1, \lin), doneAction: 2);
		var sig = ns.collect { |i|
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;      // equal-power triangle window around step i
			PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), 1, start, 0) * w
		}.sum;
		sig = BHiPass.ar(BHiPass.ar(sig, hpf.max(10)), hpf.max(10));   // LOW CUT (2026-10-01): the breath takes carry 20-40 Hz mic air rumble (13 % of their energy below 40 Hz)
		Out.ar(out, Pan2.ar(sig * env * In.kr(gainBus) * amp.lag(0.1) * vol.lag(0.1) * comp.lag(1), pan));
	}).add;
	// quad: the same breath, panned around 4 speakers (azim -1..1 = the full circle, PanAz width 2 = equal-power pairs)
	SynthDef(\b36SegQ, { |hpf = 70, start = 0, dur = 1, fade = 0.04, morphBus, gainBus, azim = 0, amp = 0.8, comp = 1, vol = 0.8|
		var bufs = \bufs.kr(0 ! ns), outs = \outs.kr([2, 3, 4, 5]);
		var m = In.kr(morphBus) * (ns - 1);
		var env = EnvGen.kr(Env.linen(fade, (dur - fade).max(0.001), fade, 1, \lin), doneAction: 2);
		var sig = ns.collect { |i|
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;
			PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), 1, start, 0) * w
		}.sum;
		var q = PanAz.ar(4, BHiPass.ar(BHiPass.ar(sig, hpf.max(10)), hpf.max(10)) * env * In.kr(gainBus) * amp.lag(0.1) * vol.lag(0.1) * comp.lag(1), azim, 1, 2);
		4.do { |c| Out.ar(outs[c], q[c]) };
	}).add;

	slots = Array.interpolation(nv, ~b36Spread.neg, ~b36Spread);
	chosen = [slots.minIndex { |x| x.abs }];
	(nv - 1).do {
		var rest = (0..(nv - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~b36Pan = chosen.collect { |k| slots[k] };
	// quad: the same max-spread order, but 36 EVEN steps round the circle (-1 and +1 are the same point on a circle,
	// so the stereo extremes must not map to them)
	~b36Azim = chosen.collect { |k| -1 + (2 * k / nv) };

	// ---- buffers: level 1 (originals) + speed levels (skipped per voice if not rendered) ----
	~b36Bufs = meta["voices"].collect { |v| v["files"].collect { |f| Buffer.read(s, ~b36Dir +/+ f) } };
	// BACKGROUND LOADING (2026-10-02, Jon): only the 1x renders load now (the patch is playable in seconds); the speed levels load
	// one by one AFTER the window is up (~b36LoadLevels, slowest first), each usable as soon as it is in. Until then a voice set
	// faster than what is loaded plays the fastest loaded level and steps up as the rest arrive.
	~spFiles = meta["voices"].collect { |v| ~b36SpeedLevels.collect { |lv|
		var files = v["files"].collect { |f| ~b36Dir +/+ "speed" +/+ (f.splitext[0] ++ "_x" ++ lv.asString ++ ".wav") };
		if (files.every { |p| File.exists(p) }) { files } { nil } } };
	~spBufs = meta["voices"].collect { |v, i| [~b36Bufs[i]] ++ (nil ! ~b36SpeedLevels.size) };
	~b36LoadedLevels = 0;
	("breath36: reading " ++ ~spBufs.flat.reject(_.isNil).size ++ " buffers ...").postln;
	s.sync;
	// 2026-10-01: with ~2300 buffers loading at once some /b_info replies get lost over UDP, leaving a Buffer with
	// numFrames nil (a voice's player then crashed on its first breath at that speed). Re-query until all are known.
	block { |done| 5.do { |round| var missing = ~spBufs.flat.reject(_.isNil).select { |b| b.numFrames.isNil };
		if (missing.isEmpty) { done.value };
		("breath36: " ++ missing.size ++ " buffers without size info -- re-querying (round " ++ (round + 1) ++ ")").warn;
		missing.do { |b| b.updateInfo }; s.sync; 0.2.wait } };
	~spAvail = ~spBufs.collect { |sets| sets.detectIndex(_.isNil) ? sets.size };

	~b36Silent = Bus.control(s, 1).set(0);
	~b36MorphBus = Bus.control(s, nv); ~b36GainBus = Bus.control(s, nv);
	~b36VolBus = Bus.control(s, 1).set(~b36Amp);   // the VOLUME, read LIVE by every breath (2026-10-03, Jon: "should be live, not just when the next sample begins")
	~b36Morph = 0 ! nv; ~b36OnState = 0 ! nv; ~offAt = nil ! nv;
	~b36Mute = false ! nv; ~b36Solo = false ! nv;
	~spLevel = 0 ! nv; ~spOffset = 0 ! nv;
	~segPhase = nv.collect { |i| thisThread.randSeed = 900 + i; 1.0.rand };   // independent start points (used once, to seed ~segIdx)
	~segIdx = nil ! nv; ~segN = nil ! nv;   // integer segment index per voice (a fraction->index round trip repeated segments ~3 % of the time)
	~gapIdx = 0 ! nv;
	~b36CompFor = { |n| if (~b36Comp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~b36Synths = nv.collect { |i|
			Synth(\b36Ctl, [\morphOut, ~b36MorphBus.index + i, \gainOut, ~b36GainBus.index + i,
				\morph, 0, \glide, ~b36Glide, \modbus, ~b36Silent.index, \modamt, 0, \on, 0, \fade, 0,
				\fbus, ~b36Silent.index, \famt, 0]);
		};
	};

	// ---- control functions ----
	~b36Audible = { |i| (i < ~b36N) and: { ~b36Mute[i].not } and: { ~b36Solo.includes(true).not or: { ~b36Solo[i] } } };
	~b36ApplyOn = {
		nv.do { |i| var on = ~b36Audible.(i).asInteger;
			if ((on == 0) and: { ~b36OnState[i] == 1 }) { ~offAt[i] = Main.elapsedTime };
			~b36OnState[i] = on; ~b36Synths[i].set(\fade, ~b36Fade, \on, on) };
		~b36Dirty = true;
	};
	~b36Set = { |n| ~b36N = n.round.asInteger.clip(0, nv); ~b36ApplyOn.() };
	~b36SetMorph = { |i, v|
		~b36Morph[i] = v.clip(0, 1);
		~b36Synths[i].set(\glide, ~b36Glide, \morph, ~b36Morph[i]);
		~b36Dirty = true;
	};
	~b36SetMod = { |i, busIndex, amt = 1| ~b36Synths[i].set(\modbus, busIndex ? ~b36Silent.index, \modamt, amt) };
	~b36ClearMod = { ~b36Synths.do(_.set(\modbus, ~b36Silent.index, \modamt, 0)) };
	// ---- FORCE per fader group and CENTRAL -> speed ----
	~b36FGroups = 8.collect { |g| (g, (g + 8) .. (nv - 1)).select { |i| i < nv } };   // = the tiled Korg faders
	~b36FGroupOf = nv.collect { |i| i % 8 };
	~b36FAmt = { |g| if (~b36FSensorOf[g].isNil) { 0 } { 0.5 * ~b36F[\knob][g] * ~b36F[\on][g].asInteger } };
	~b36FApply = { |g| var k = ~b36FSensorOf[g];
		~b36FGroups[g].do { |i|
			if (~fhBus.isNil or: { k.isNil }) { ~b36Synths[i].set(\fbus, ~b36Silent.index, \famt, 0) } {
				~b36Synths[i].set(\fbus, ~fhBus.index + (if (~b36F[\signal] == 0) { 7 } { 0 }) + k, \famt, ~b36FAmt.(g),
					\fsens, ~b36F[\sens], \fsmooth, ~b36F[\smooth]) } } };
	~b36FApplyAll = { if (~fhBus.isNil and: { ~b36F[\on].includes(true) }) { "breath36: FORCE needs the FORCE tab (force_hub.scd, ~fhBus)".warn };
		8.do { |g| ~b36FApply.(g) } };
	(s.latency + 0.1).wait;   // the voice synths were created in a timed bundle (s.bind): a plain .set sent now would arrive first
	~b36FApplyAll.();
	~b36FCBus = Bus.control(s, 1);
	~b36FCStart = { ~b36FCSyn !? { ~b36FCSyn.free }; ~b36FCSyn = nil;
		if (~fhBus.notNil) { ~b36FCSyn = Synth(\b36Central, [\in, ~fhBus.index, \out, ~b36FCBus.index, \csig, ~b36FC[\signal], \csmooth, ~b36FC[\smooth]], s, \addToHead) } };
	// delay: a short history of the central signal; the speed uses the value from `delay` seconds ago
	~b36FCHist = List.new;
	~b36FCDelayed = { |c| var now = Main.elapsedTime, d = ~b36FC[\delay], old;
		~b36FCHist.add([now, c]); while { ~b36FCHist.size > 2 and: { ~b36FCHist[1][0] < (now - d - 0.5) } } { ~b36FCHist.removeAt(0) };
		if (d <= 0) { c } { old = ~b36FCHist.detect { |e| e[0] >= (now - d) }; (old ? ~b36FCHist.last)[1] } };
	~b36FCStart.();
	~b36FCApplied = nil;
	~b36FCRout = Routine { loop {   // 10 x a second: each voice heads for base + offset (+ its own spread); ~spP.x stays the base
		if (~b36FC[\on] and: { ~b36FCSyn.notNil }) {
			var c = ~b36FCDelayed.(~b36FCBus.getSynchronous);   // shared memory (local server); async Bus.get gave stale values
			{
				var lmax = levelNames.size - 1, off = 0.5 * ~b36FC[\knob] * c * lmax, x = (~spP.x + off).clip(0, lmax);
				~b36FCVal = c; ~b36FCOff = off; ~b36FCX = x;
				if (~b36FCApplied.isNil or: { (x - ~b36FCApplied).abs > 0.01 }) {
					~b36FCApplied = x; nv.do { |i| ~spSetLevel.(i, x + ~spOffset[i]) } } }.defer };
		0.1.wait } }.play(SystemClock);
	~b36FCSetOn = { |on| ~b36FC[\on] = on;
		if (on and: { ~b36FCSyn.isNil }) { ~b36FCStart.(); if (~b36FCSyn.isNil) { "breath36: CENTRAL needs the FORCE tab (~fhBus)".warn } };
		if (on.not) { ~b36FCApplied = nil; ~spSetAll.(~spP.x) } };
	~spSetLevel = { |i, k| ~spLevel[i] = k.round.asInteger.clip(0, ~spAvail[i] - 1); ~b36Dirty = true };   // takes effect at the voice's next breath
	~spSetAll = { |x| ~spP.x = x; nv.do { |i| ~spSetLevel.(i, x + ~spOffset[i]) } };
	~spRollOffsets = { |sp, seed = 4242| ~spP.spread = sp; thisThread.randSeed = seed; ~spOffset = nv.collect { sp.rand2 }; ~spSetAll.(~spP.x) };
	~spRollOffsets.(~spP.spread);
	~gpSet = { |secs| ~gpP[\mean] = secs.clip(0, 12); ~b36Dirty = true };

	// one breath segment of voice i, routed AMBI / quad / stereo as the window is set; used by the free player and by PULSE
	~b36PlaySeg = { |i, bufs, b0, t0, dur, fade, lat, gain = 1|
		s.makeBundle(lat, {
						if ((~b36Ambi == true) and: { ~ambiBus.notNil }) {   // AMBI (dev/ambi.scd): encoded at its azimuth, decoded quad + binaural there
							Synth(\b36SegA, [\hpf, ~b36Hpf, \bufs, bufs.collect(_.bufnum), \start, t0 * b0.sampleRate, \dur, dur, \fade, fade,
								\morphBus, ~b36MorphBus.index + i, \gainBus, ~b36GainBus.index + i,
								\az, (~ambiAz !? { |a| a[i] }) ? (~b36Azim[i] * pi), \el, (~ambiEl !? { |a| a[i] }) ? 0, \out, ~ambiBus.index, \amp, gain, \vol, ~b36VolBus.asMap, \comp, ~b36CompFor.(~b36N)])
						} {
						if (~b36Quad and: { s.options.numOutputBusChannels > ~b36QuadOuts.maxItem }) {
							Synth(\b36SegQ, [\hpf, ~b36Hpf, \bufs, bufs.collect(_.bufnum), \start, t0 * b0.sampleRate, \dur, dur, \fade, fade,
								\morphBus, ~b36MorphBus.index + i, \gainBus, ~b36GainBus.index + i,
								\azim, ~b36Azim[i], \outs, ~b36QuadOuts, \amp, gain, \vol, ~b36VolBus.asMap, \comp, ~b36CompFor.(~b36N)])
						} {
							Synth(\b36Seg, [\hpf, ~b36Hpf, \bufs, bufs.collect(_.bufnum), \start, t0 * b0.sampleRate, \dur, dur, \fade, fade,
								\morphBus, ~b36MorphBus.index + i, \gainBus, ~b36GainBus.index + i,
								\pan, ~b36Pan[i], \amp, gain, \vol, ~b36VolBus.asMap, \comp, ~b36CompFor.(~b36N)]) } };
		}) };
	// ---- the players: one routine per voice, breath by breath ----
	~b36Players = nv.collect { |i|
		Routine {
			loop {
				var k = ~spLevel[i], bufs, ons, b0, total, n, idx, t0, t1, dur, fade, gap, audible;
				if (~b36Pulse[\on] == true) { 0.05.wait } {   // PULSE plays the breaths now; this voice keeps its place
				// a speed level whose buffers have no size info yet (lost reply): play this breath at 1x, ask again
				if (~spBufs[i][k].isNil) { k = 0 };   // level not loaded (yet)
				if (~spBufs[i][k].any { |b| b.numFrames.isNil }) { ~spBufs[i][k].do { |b| if (b.numFrames.isNil) { b.updateInfo } }; k = 0 };
				bufs = ~spBufs[i][k]; ons = ~spOnsets[i][k]; b0 = bufs[0];
				total = b0.numFrames / b0.sampleRate; n = ons.size;
				if (~segIdx[i].isNil) { ~segIdx[i] = (~segPhase[i] * n).floor.asInteger; ~segN[i] = n };
				if (~segN[i] != n) { ~segIdx[i] = (~segIdx[i] / ~segN[i] * n).round.asInteger; ~segN[i] = n };   // level changed: keep the place
				idx = ~segIdx[i] % n;
				t0 = ons[idx]; t1 = if (idx + 1 < n) { ons[idx + 1] } { total };
				dur = (t1 - t0).max(0.05); fade = ~gpP.fade.min(dur * 0.45);
				gap = ~gpP[\mean] * ~gpSeq[i][~gpP.ncviIdx].wrapAt(~gapIdx[i]);
				audible = (~b36OnState[i] == 1) or: { ~offAt[i].notNil and: { (Main.elapsedTime - ~offAt[i]) < (~b36Fade + 0.5) } };
				if (audible) { ~b36PlaySeg.(i, bufs, b0, t0, dur, fade, s.latency) 				};
				~gapIdx[i] = ~gapIdx[i] + 1;
				~segIdx[i] = idx + 1;
				(dur + gap).wait;
				}
			}
		}.play(SystemClock);
	};

	// ---- OCEAN matching (data loaded on first use) ----
	~b36OcNames = ["waves5min", "215"];
	~b36OcLoad = { var dir = ~b36Sharp +/+ "ocean_match", fv, ot;
		if (~b36OcVoice.isNil) {
			fv = File.readAllString(dir +/+ "features_voices.json").parseJSON["voices"];
			~b36OcVoice = ~b36Meta["voices"].collect { |v| fv[v["voice"].asInteger.asString].collect { |sg| [sg[2].collect(_.asFloat), sg[3].asFloat] } } };
		ot = File.readAllString(dir +/+ ("ocean_" ++ ~b36OcNames[~b36Ocean[\target]] ++ ".json")).parseJSON;
		~b36OcHop = ot["hop"].asFloat; ~b36OcDur = ot["dur"].asFloat; ~b36OcPath = ot["path"];
		~b36OcShape = ot["shape"].collect { |f| f.collect(_.asFloat) }; ~b36OcRms = ot["rms"].collect(_.asFloat);
		~b36OcMed = ~b36OcRms.copy.sort[~b36OcRms.size div: 2];
		("breath36: OCEAN " ++ ~b36OcNames[~b36Ocean[\target]] ++ " loaded (" ++ ~b36OcShape.size ++ " frames)").postln };
	// the breath of voice i whose shape is closest to the ocean lat seconds from now; returns [segment, gain]
	~b36OcPick = { |i, lat| var pos = ((Main.elapsedTime + lat) - (~b36OcT0 ? Main.elapsedTime)) % ~b36OcDur, f = (pos / ~b36OcHop).floor.asInteger.clip(0, ~b36OcShape.size - 1);
		var tgt = ~b36OcShape[f], segs = ~b36OcVoice[i], d, order, pick, gdb;
		d = segs.collect { |sg| var a = sg[0], acc = 0; a.size.do { |b| acc = acc + (a[b] - tgt[b]).squared }; acc };
		order = d.order; pick = order[(~b36Ocean[\topK].asInteger.max(1).min(order.size)).rand];
		gdb = ((~b36OcRms[f] - ~b36OcMed) * ~b36Ocean[\loud]).clip(-18, 18);
		[pick, gdb.dbamp] };
	~b36OcHearSyn = nil;
	SynthDef(\b36OcHear, { |buf, amp = 0.1, out = 0, ambi = 0, abus = 0|
		var x = PlayBuf.ar(4, buf, BufRateScale.kr(buf), loop: 1);   // ambiX (W Y Z X, SN3D) or stereo padded to 4
		Out.ar(out, [x[0], x[1]] * amp.lag(0.2) * (1 - ambi));
		Out.ar(abus, [x[0] * 0.7071, x[3], x[1], x[2]] * amp.lag(0.2) * ambi);   // ambiX -> ATK B-format
	}).add;
	~b36OcHear = { |on| ~b36OcHearSyn !? { ~b36OcHearSyn.free }; ~b36OcHearSyn = nil; ~b36OcHearBuf !? { ~b36OcHearBuf.free }; ~b36OcHearBuf = nil;
		if (on and: { ~b36OcPath.notNil }) { fork {
			var amb = ~b36OcPath.contains("ambiX") and: { ~ambiBus.notNil };
			~b36OcHearBuf = Buffer.readChannel(s, ~b36OcPath, channels: if (~b36OcPath.contains("ambiX")) { [0, 1, 2, 3] } { [0, 1, 0, 1] }); s.sync;
			~b36OcHearSyn = Synth.tail(s, \b36OcHear, [\buf, ~b36OcHearBuf, \amp, ~b36Ocean[\hearDb].dbamp, \ambi, amb.asInteger,
				\abus, if (amb) { ~ambiBus.index } { (~b36OcDummy = ~b36OcDummy ?? { Bus.audio(s, 4) }).index }, \out, 0]);
			~b36OcT0 = Main.elapsedTime + s.latency } } };   // the matching clock follows what is heard
	~b36OcSet = { |on| if (on) { ~b36OcLoad.(); ~b36OcT0 = Main.elapsedTime } { ~b36OcHear.(false) }; ~b36Ocean[\on] = on;
		if (on and: { ~b36Ocean[\hear] }) { ~b36OcHear.(true) } };

	// ---- PULSE engine ----
	~b36PulseN = 0;
	~b36PulsePeriod = { (60 / (if (~b36Pulse[\src] == 0) { ~msBpm ? 60 } { ~b36Pulse[\bpm] }).max(1)) * ~b36Pulse[\every] };
	// one voice's next breath, lasting at most maxDur, starting lat seconds from now
	~b36PulseVoice = { |i, maxDur, lat, seg, gain = 1|
		var k = if (seg.notNil) { 0 } { ~spLevel[i] }, bufs, ons, b0, total, n, idx, t0, t1, d, fade;
		if (~spBufs[i][k].isNil or: { ~spBufs[i][k].any { |b| b.numFrames.isNil } }) { k = 0 };
		bufs = ~spBufs[i][k]; ons = ~spOnsets[i][k]; b0 = bufs[0]; total = b0.numFrames / b0.sampleRate; n = ons.size;
		if (~segIdx[i].isNil) { ~segIdx[i] = (~segPhase[i] * n).floor.asInteger; ~segN[i] = n };
		idx = if (seg.notNil) { seg.clip(0, n - 1) } { ~segIdx[i] % n }; t0 = ons[idx]; t1 = if (idx + 1 < n) { ons[idx + 1] } { total };
		d = (t1 - t0).max(0.05).min(maxDur.max(0.05)); fade = ~gpP.fade.min(d * 0.45);
		~b36PlaySeg.(i, bufs, b0, t0, d, fade, lat.max(0.01), gain);
		if (seg.isNil) { ~segIdx[i] = idx + 1 } };
	~b36Tier = { |i| i % 3 };   // 0 = A (beat), 1 = B (beat / 8th), 2 = C (16ths)
	~b36PulseHits = 0;
	// ONE PULSE AHEAD (2026-10-02: 20 ms of margin gave the server "late" messages): when pulse n fires, its breaths are stamped
	// for the NEXT pulse (now + period, + offset), so attacks land on the predicted beat with >= 150 ms of scheduling margin
	~b36PulseFire = { var per = ~b36PulsePeriod.(), base = per + (~b36Pulse[\offset] / 1000);
		var base2 = if (base < 0.15) { base + per } { base };
		var jit = { (~b36Pulse[\jitter] / 1000).rand }, beat = per / ~b36Pulse[\every].max(1), g = ~b36Pulse[\gate];
		if (~b36Pulse[\mode] == 0) {
			nv.do { |i| if (~b36OnState[i] == 1) { var lat = base2 + jit.(), pk = if (~b36Ocean[\on] == true) { ~b36OcPick.(i, lat) } { [nil, 1] };
				~b36PulseVoice.(i, per * g, lat, pk[0], pk[1]); ~b36PulseHits = ~b36PulseHits + 1 } }
		} {
			// TIERS: the beat is 4 sixteenths; slot j starts j x beat/4 after the beat
			nv.do { |i| if (~b36OnState[i] == 1) {
				var tier = ~b36Tier.(i), cnt = 0;
				var slots = switch (tier, 0, { [0] }, 1, { [0, 2] }, { [0, 1, 2, 3] });
				var p = [~b36Pulse[\pA], ~b36Pulse[\pB], ~b36Pulse[\pC]][tier];
				var len = [beat, beat / 2, beat / 4][tier] * g;
				slots.do { |j| if (p.coin and: { (tier != 2) or: { cnt < ~b36Pulse[\maxC] } }) {
					var lat = base2 + (j * beat / 4) + jit.(), pk = if (~b36Ocean[\on] == true) { ~b36OcPick.(i, lat) } { [nil, 1] };
					cnt = cnt + 1; ~b36PulseHits = ~b36PulseHits + 1;
					~b36PulseVoice.(i, len, lat, pk[0], pk[1]) } } } } };
		~b36PulseN = ~b36PulseN + 1; ~b36Dirty = true };
	// metronome beats (the metro server's /msBeat; counts from its start)
	OSCdef(\b36Beat, { |msg, time, addr| var n = msg[3].asInteger;
		if ((~b36Pulse[\on] == true) and: { ~b36Pulse[\src] == 0 } and: { ~msServer.notNil } and: { addr.port == ~msServer.addr.port }
			and: { ((n - 1) % ~b36Pulse[\every].max(1)) == 0 }) { ~b36PulseFire.() } }, '/msBeat');
	// own tempo
	~b36PulseRout !? { ~b36PulseRout.stop };
	~b36PulseRestart = { ~b36PulseRout !? { ~b36PulseRout.stop };
		~b36PulseRout = Routine { loop { if ((~b36Pulse[\on] == true) and: { ~b36Pulse[\src] == 1 }) { ~b36PulseFire.() }; ~b36PulsePeriod.().wait } }.play(SystemClock) };
	~b36PulseSet = { |on| ~b36Pulse[\on] = on;
		if (on and: { ~b36Pulse[\src] == 0 } and: { ~msSynth.isNil }) { "breath36: PULSE follows the metronome -- start the metronome (tab 4), or choose own tempo".warn };
		~b36PulseRestart.() };
	~b36PulseRestart.();

	// ---------------- GUI ----------------
	~b36Win !? { ~b36Win.onClose = nil; if (~b36Win.isClosed.not) { ~b36Win.close } };
	// ---- display rate limit (Jon: nothing on screen may change faster than 4 times a second -- vestibular
	// migraine). Sound changes at once; a control moved by the nanoKONTROL2 (or by another control) is
	// redrawn by ONE shared routine every 0.25 s: ~uiLater.(key, { widget.value = x }) -- the last one wins.
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
			p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
	~b36Win = if (~stHost.notNil) { ~stHost.(\breath36) } { Window("36 breaths -> pitched harmonium  |  speed  |  gap  |  nanoKONTROL2", Rect(60, 40, 1120, 1000)).front };   // in a tab of show_tabs.scd, or its own window
	// nanoKONTROL2 follows the FRONT window: bringing this window forward makes it the owner
	~b36Win.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\breath36).asSet.asArray; ~mkOwner = \breath36;
		{ ~mkStatus !? { ~mkStatus.string = "nanoKONTROL2: this window (front)" } }.defer });
	~b36Count = StaticText().string_("0 voices").align_(\center).font_(Font.default.size_(40).boldVariant);
	~b36Slider = Slider().orientation_(\horizontal).fixedHeight_(40).step_(1 / nv).value_(~b36N / nv)
		.action_({ |sl| ~b36Set.(sl.value * nv) });     // 0 .. nv voices
	~spText = StaticText().string_("speed 1x").align_(\center).font_(Font.default.size_(26).boldVariant);
	~spSlider = Slider().orientation_(\horizontal).fixedHeight_(32).step_(0.01).value_(0)
		.action_({ |sl| var x = sl.value * (levelNames.size - 1); ~spSetAll.(x);
			~uiLater.(~spText, { ~spText.string = "speed " ++ levelNames[x.round.asInteger].asString ++ "x   (" ++ x.round(0.01).asString ++ ")" }) });
	~spSpread = Slider().orientation_(\horizontal).fixedHeight_(20).value_(~spP.spread / 1.5)
		.action_({ |sl| ~spRollOffsets.(sl.value * 1.5) });
	~spRollBtn = Button().states_([["re-roll offsets"]]).fixedWidth_(110)
		.action_({ ~spRollOffsets.(~spP.spread, Date.getDate.rawSeconds.asInteger) });
	~gpText = StaticText().string_("gap 0.0 s").align_(\center).font_(Font.default.size_(26).boldVariant);
	~gpSlider = Slider().orientation_(\horizontal).fixedHeight_(32).step_(0.005).value_(0)
		.action_({ |sl| ~gpSet.(sl.value.squared * 12); ~uiLater.(~gpText, { ~gpText.string = "gap " ++ ~gpP[\mean].round(0.1).asString ++ " s" }) });
	~gpNcvi = PopUpMenu().items_(gapLevels.collect { |l| "gap nCVI " ++ l.round.asInteger.asString }).value_(~gpP.ncviIdx)
		.action_({ |pm| ~gpP.ncviIdx = pm.value });
	~gpFadeBox = NumberBox().clipLo_(5).clipHi_(500).step_(5).scroll_step_(5).decimals_(0).value_(~gpP.fade * 1000).fixedWidth_(56)
		.action_({ |nb| ~gpP.fade = nb.value / 1000 });
	~b36VText = Array.newClear(nv); ~spLvlText = Array.newClear(nv);
	~b36VSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(130).step_(0.005).value_(0)
			.action_({ |sl| ~b36SetMorph.(i, sl.value); ~mkRelease !? { ~mkRelease.([~mkGroup[i]]) } });   // mouse moved it: its fader must catch up again
	};
	~b36AllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(130).step_(0.005)
		.value_(0).action_({ |sl| nv.do { |i| ~b36SetMorph.(i, sl.value) }; ~b36SliderSync = true; ~mkRelease !? { ~mkRelease.((0..7)) } });
	// FORCE header above voice sliders 1-6 (toggle + offset knob, like the Korg's knob above its fader); a spacer of the
	// same height above the rest of the top row keeps the sliders aligned
	// FORCE strip: one column per Korg fader group, toggle + offset knob (Korg knob g), like the Korg's knob above its fader
	~b36FToggles = Array.newClear(8); ~b36FKnobs = Array.newClear(8); ~b36FKText = Array.newClear(8);
	~b36FCol = { |g| var src = ~b36FSensorOf[g], lab = if (src.isNil) { "no sensor" } { if (src == 6) { "CENTRAL" } { "sensor " ++ (src + 1) } };
		~b36FToggles[g] = CheckBox().string_("on").value_(~b36F[\on][g]).action_({ |c| ~b36F[\on][g] = c.value; ~b36FApply.(g);
			~uiLater.(("b36FK" ++ g).asSymbol, { ~b36FKText[g].string = "+-" ++ (~b36FAmt.(g) * 100).round.asInteger ++ "%" }) });
		~b36FKnobs[g] = Knob().fixedSize_(Size(34, 34)).value_(~b36F[\knob][g]).action_({ |k| ~b36F[\knob][g] = k.value; ~b36FApply.(g);
			~uiLater.(("b36FK" ++ g).asSymbol, { ~b36FKText[g].string = "+-" ++ (~b36FAmt.(g) * 100).round.asInteger ++ "%" }) });
		~b36FKText[g] = StaticText().string_("+-" ++ (~b36FAmt.(g) * 100).round.asInteger ++ "%").align_(\center).fixedWidth_(110).font_(Font.default.size_(10));
		VLayout(StaticText().string_("fader " ++ (g + 1) ++ ": " ++ lab).align_(\center).fixedWidth_(110).font_(Font.default.boldVariant),
			StaticText().string_("v " ++ (~b36FGroups[g] + 1).join(" ")).align_(\center).fixedWidth_(110).font_(Font.default.size_(9)),
			HLayout(nil, ~b36FToggles[g], ~b36FKnobs[g], nil), ~b36FKText[g]).spacing_(1) };
	~b36FStrip = HLayout(*(8.collect { |g| ~b36FCol.(g) } ++ [nil]));
	// LIVE bar beside every voice slider: the morph the voice actually has (slider + force + tab 7), read from the morph
	// buses 4 x a second. Voices 1-6: the pale band is how far the force knob lets it go (slider +- 0.5 x knob).
	~b36Eff = 0 ! nv;
	~b36VMeters = nv.collect { |i| UserView().fixedWidth_(12).minHeight_(130).background_(Color.grey(0.93)).drawFunc_({ |uv|
		var h = uv.bounds.height, w = uv.bounds.width, y = { |v| h * (1 - v.clip(0, 1)) }, e = ~b36Eff[i] ? 0, c = ~b36Morph[i] ? 0;
		if (~b36FAmt.notNil) { var a = ~b36FAmt.(~b36FGroupOf[i]);
			if (a > 0) { Pen.fillColor = Color(0.35, 0.55, 0.75, 0.22); Pen.fillRect(Rect(0, y.(c + a), w, y.(c - a) - y.(c + a))) } };
		Pen.fillColor = if ((e - c).abs > 0.005) { if (e > c) { Color(0.25, 0.45, 0.75) } { Color(0.75, 0.45, 0.25) } } { Color.grey(0.55) };
		Pen.fillRect(Rect(2, y.(e), w - 4, h - y.(e)));   // the live level
		Pen.fillColor = Color.black; Pen.fillRect(Rect(0, y.(c) - 1, w, 2));   // tick = where the slider is
	}) };
	~b36Cols = nv.collect { |i|
		~b36VText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		~spLvlText[i] = StaticText().string_("1x").align_(\center).fixedWidth_(46).font_(Font.default.size_(10));
		VLayout(*([] ++ [
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46).font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			StaticText().string_(~b36Notes[i]).align_(\center).fixedWidth_(46).font_(Font.default.boldVariant),
			HLayout(nil, ~b36VSliders[i], ~b36VMeters[i], nil).margins_(0).spacing_(1),
			~b36VText[i], ~spLvlText[i]
		])).spacing_(2)
	};
	~b36PulseBox = CheckBox().string_("PULSE (unison breaths)").value_(false).action_({ |c| ~b36PulseSet.(c.value) });
	~b36PulseSrc = PopUpMenu().items_(["metronome beats", "own tempo"]).value_(~b36Pulse[\src]).fixedWidth_(150)
		.action_({ |m| ~b36Pulse[\src] = m.value; ~b36PulseRestart.() });
	~b36PulseEvery = PopUpMenu().items_(["every beat", "every 2", "every 3", "every 4", "every 8"]).value_([1, 2, 3, 4, 8].indexOf(~b36Pulse[\every]) ? 0).fixedWidth_(100)
		.action_({ |m| ~b36Pulse[\every] = [1, 2, 3, 4, 8][m.value]; ~b36PulseRestart.() });
	~b36PulseNb = { |key, lo, hi, step, dec| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec).value_(~b36Pulse[key]).fixedWidth_(52)
		.action_({ |b| ~b36Pulse[key] = b.value }) };
	~b36PulseText = StaticText().string_("").fixedWidth_(170);
	~b36LoadText = StaticText().string_("").fixedWidth_(330).font_(Font.default.size_(11));
	~b36OcBox = CheckBox().string_("OCEAN match (which breath)").value_(false).action_({ |c| ~b36OcSet.(c.value) });
	~b36OcMenu = PopUpMenu().items_(["ocean waves (5 min)", "ocean 215 (ambiX, 1 min)"]).value_(~b36Ocean[\target]).fixedWidth_(190)
		.action_({ |m| ~b36Ocean[\target] = m.value; if (~b36Ocean[\on]) { ~b36OcSet.(true) } });
	~b36OcNb = { |key, lo, hi, step, dec| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec).value_(~b36Ocean[key]).fixedWidth_(52)
		.action_({ |b| ~b36Ocean[key] = b.value; if (key == \hearDb) { ~b36OcHearSyn !? { ~b36OcHearSyn.set(\amp, b.value.dbamp) } } }) };
	~b36OcHearBox = CheckBox().string_("hear the ocean").value_(false).action_({ |c| ~b36Ocean[\hear] = c.value; if (~b36Ocean[\on]) { ~b36OcHear.(c.value) } });
	~b36PulseMode = PopUpMenu().items_(["unison", "tiers (A beat / B 8ths / C 16ths)"]).value_(~b36Pulse[\mode]).fixedWidth_(230)
		.action_({ |m| ~b36Pulse[\mode] = m.value });
	~b36FSig = PopUpMenu().items_(["AC (press up, release down)", "DC (press pushes up)"]).value_(~b36F[\signal]).fixedWidth_(200)
		.action_({ |m| ~b36F[\signal] = m.value; ~b36FApplyAll.() });
	~b36FSens = NumberBox().clipLo_(0).clipHi_(5).step_(0.1).scroll_step_(0.1).decimals_(1).value_(~b36F[\sens]).fixedWidth_(46)
		.action_({ |b| ~b36F[\sens] = b.value; ~b36FApplyAll.() });
	~b36FSmooth = NumberBox().clipLo_(0).clipHi_(5).step_(0.05).scroll_step_(0.05).decimals_(2).value_(~b36F[\smooth]).fixedWidth_(46)
		.action_({ |b| ~b36F[\smooth] = b.value; ~b36FApplyAll.() });
	~b36FCBox = CheckBox().string_("CENTRAL -> speed").value_(~b36FC[\on]).action_({ |c| ~b36FCSetOn.(c.value); c.value = ~b36FC[\on] });
	~b36FCKnob = Knob().fixedSize_(Size(30, 30)).value_(~b36FC[\knob]).action_({ |k| ~b36FC[\knob] = k.value });
	~b36FCMenu = PopUpMenu().items_(["ensemble activity (5 s)", "ensemble slow level", "central DC", "central AC"]).value_(~b36FC[\signal]).fixedWidth_(170)
		.action_({ |m| ~b36FC[\signal] = m.value; ~b36FCSyn !? { ~b36FCSyn.set(\csig, m.value) } });
	~b36FCText = StaticText().string_("").fixedWidth_(230);
	~b36FadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~b36Fade).fixedWidth_(56).action_({ |nb| ~b36Fade = nb.value });
	~b36HpfBox = NumberBox().clipLo_(10).clipHi_(300).step_(5).scroll_step_(5).decimals_(0).value_(~b36Hpf).fixedWidth_(52).action_({ |nb| ~b36Hpf = nb.value });
	~b36GlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1).value_(~b36Glide).fixedWidth_(56).action_({ |nb| ~b36Glide = nb.value });
	~b36AmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2).value_(~b36Amp).fixedWidth_(56);
	~b36VolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~b36SetAmp = { |a|
		~b36Amp = a.clip(0, 2); ~b36VolBus !? { ~b36VolBus.set(~b36Amp) };
		~uiLater.(\b36Amp, { ~b36AmpBox.value = ~b36Amp;
		   ~b36VolText.string = if (~b36Amp <= 0.01) { "-inf dB" } { ~b36Amp.ampdb.round(0.5).asString ++ " dB" } });
	};   // new breaths pick the level up; running ones finish at the old level (each breath is < 4 s)
	~b36VolSlider = Slider().orientation_(\vertical).fixedWidth_(44).minHeight_(160)
		.value_(\db.asSpec.copy.minval_(-40).maxval_(6).unmap(~b36Amp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value); ~b36SetAmp.(if (sl.value <= 0.001) { 0 } { db.dbamp }) });
	~b36AmpBox.action_({ |nb| ~b36SetAmp.(nb.value); ~b36VolSlider.value = ControlSpec(-40, 6).unmap(nb.value.max(0.0001).ampdb) });
	~b36CompBtn = Button().states_([["level comp off", Color.black, Color.white], ["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.action_({ |b| ~b36Comp = (b.value == 1) });
	~mkStatus = StaticText().string_("nanoKONTROL2: off").fixedHeight_(16);
	~b36Win.layout = HLayout([VLayout(
		~b36Count, ~b36Slider,
		HLayout(StaticText().string_("0"), nil, StaticText().string_(nv.asString ++ " voices")),
		HLayout([VLayout(~spText, ~spSlider,
			HLayout(*(levelNames.collect { |n| StaticText().string_(n.asString ++ "x").align_(\center) })),
			HLayout(StaticText().string_("spread (steps 0..1.5)").fixedWidth_(130), ~spSpread, ~spRollBtn), ~b36LoadText,
			HLayout(~b36FCBox, ~b36FCKnob, ~b36FCMenu, StaticText().string_("delay s"),
			NumberBox().clipLo_(0).clipHi_(60).decimals_(1).step_(0.5).scroll_step_(0.5).value_(~b36FC[\delay]).fixedWidth_(46)
				.action_({ |b| ~b36FC[\delay] = b.value }),
			StaticText().string_("smooth s"), NumberBox().clipLo_(0).clipHi_(10).decimals_(1).step_(0.1).scroll_step_(0.1).value_(~b36FC[\smooth]).fixedWidth_(46)
				.action_({ |b| ~b36FC[\smooth] = b.value; ~b36FCSyn !? { ~b36FCSyn.set(\csmooth, b.value) } }),
				nil), HLayout(~b36FCText, nil)), stretch: 3],
			[VLayout(~gpText, ~gpSlider, HLayout(StaticText().string_("0"), nil, StaticText().string_("12 s")),
			HLayout(~gpNcvi, nil, StaticText().string_("seg fade ms"), ~gpFadeBox)), stretch: 2]),
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   (" ++ ns ++ " FlowEdit steps);  small number = speed level").fixedHeight_(18),
		HLayout(*(~b36Cols.keep(nv.div(2) + (nv % 2)) ++ [nil])),
		HLayout(*(~b36Cols.drop(nv.div(2) + (nv % 2)) ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "), StaticText().string_(" "),
				HLayout(nil, ~b36AllSlider, nil).margins_(0), StaticText().string_(" "), StaticText().string_(" ")).spacing_(2),
			nil])),
		HLayout(StaticText().string_("fade s"), ~b36FadeBox, StaticText().string_("morph glide s"), ~b36GlideBox, StaticText().string_("low cut Hz"), ~b36HpfBox,
			StaticText().string_("level"), ~b36AmpBox, ~b36CompBtn,
			CheckBox().string_("QUAD -> outs " ++ (~b36QuadOuts + 1).join(" ")).value_(~b36Quad).action_({ |c| ~b36Quad = c.value }), nil,
			StaticText().string_("tiled " ++ performers.collect(_.keep(1)).join("/") ++ "; speed levels loaded for "
				++ ~spAvail.count(_ == levelNames.size) ++ "/" ++ nv ++ " voices")),
		HLayout(~b36PulseBox, ~b36PulseSrc, ~b36PulseEvery, StaticText().string_("own BPM"), ~b36PulseNb.(\bpm, 10, 400, 1, 0),
			StaticText().string_("gate"), ~b36PulseNb.(\gate, 0.05, 1, 0.05, 2), StaticText().string_("loosen ms"), ~b36PulseNb.(\jitter, 0, 500, 10, 0),
			StaticText().string_("offset ms"), ~b36PulseNb.(\offset, -300, 300, 5, 0), ~b36PulseText, nil),
		HLayout(StaticText().string_("PULSE mode"), ~b36PulseMode, StaticText().string_("  chance per slot:  A (beat)"), ~b36PulseNb.(\pA, 0, 1, 0.05, 2),
			StaticText().string_("B (beat / 8th)"), ~b36PulseNb.(\pB, 0, 1, 0.05, 2), StaticText().string_("C (16ths)"), ~b36PulseNb.(\pC, 0, 1, 0.05, 2),
			StaticText().string_("C max per beat"), ~b36PulseNb.(\maxC, 0, 4, 1, 0), nil),
		HLayout(~b36OcBox, ~b36OcMenu, StaticText().string_("pick among closest"), ~b36OcNb.(\topK, 1, 12, 1, 0),
			StaticText().string_("loudness follows ocean"), ~b36OcNb.(\loud, 0, 1, 0.1, 1), ~b36OcHearBox, StaticText().string_("dB"), ~b36OcNb.(\hearDb, -60, 0, 1, 0), nil),
		HLayout(StaticText().string_("FORCE per fader group (Korg knob g = depth; morph = slider + 0.5 x knob x signal)").font_(Font.default.boldVariant),
			~b36FSig, StaticText().string_("sens x"), ~b36FSens, StaticText().string_("smooth s"), ~b36FSmooth, nil),
		~b36FStrip,

		~mkStatus
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~b36VolSlider, nil).margins_(0), ~b36VolText).spacing_(4)
	);
	{ ~b36SetAmp.(~b36Amp) }.defer(0.5);
	~b36Dirty = true;
	~b36Rout = Routine { loop {
		if (~b36SliderSync == true) { ~b36SliderSync = false; nv.do { |i| ~b36VSliders[i].value = ~b36Morph[i] } };
		~b36MorphBus.getn(nv, { |v| ~b36Eff = v }); ~b36VMeters.do(_.refresh);   // live bars: 4 x a second, never faster
		if (~b36Dirty) {
			~b36Dirty = false;
			~b36Count.string = ~b36N.asString ++ if (~b36N == 1) { " voice" } { " voices" };
			nv.do { |i|
				~b36VText[i].string = case
					{ ~b36Mute[i] } { "MUTE" } { ~b36Solo.includes(true) and: { ~b36Solo[i].not } } { "(solo)" }
					{ i < ~b36N } { (~b36Morph[i] * 100).round.asInteger.asString ++ "%" } { "off" };
				~spLvlText[i].string = levelNames[~spLevel[i]].asString ++ "x";
			};
		};
		~b36LoadText !? { ~b36LoadText.string = if (~b36LoadedLevels < ~b36SpeedLevels.size) {
			"speed levels loading: " ++ ~b36LoadedLevels ++ "/" ++ ~b36SpeedLevels.size ++ " (up to " ++ levelNames[~b36LoadedLevels] ++ "x usable)" } { "" } };
		~b36PulseText.string = if (~b36Pulse[\on] == true) { "pulse " ++ ~b36PulseN ++ ", " ++ ~b36PulseHits ++ " breaths" ++ " @ " ++ (60 / ~b36PulsePeriod.() * ~b36Pulse[\every]).round(0.1) ++ " BPM" } { "" };
		~b36FCText.string = if (~b36FC[\on] and: { ~b36FCX.notNil }) {
			"signal " ++ (~b36FCVal * 100).round.asInteger ++ "%  ->  speed " ++ levelNames[~b36FCX.round.asInteger] ++ "x  (+" ++ ~b36FCOff.round(0.1) ++ " steps)" }
			{ "speed = the slider alone" };
		0.25.wait;
	} }.play(AppClock);

	// ---------------- nanoKONTROL2 ----------------
	// slider g morphs voices g, g+8, g+16, ... (TILED, Jon 2026-10-01; was blocks of 4 5 4 5 4 5 4 5, 2026-09-28)
	~mkGroupVoices = ~b36FGroups;   // tiled: fader g = voices g, g+8, g+16, ...
	~mkGroup = nv.collect { |i| ~mkGroupVoices.detectIndex { |vs| vs.includes(i) } ? 0 };
	~mkLink = false; ~mkLastN = nv;
	~mkLast = IdentityDictionary.new; ~mkCaught = IdentityDictionary.new; ~mkHeld = IdentityDictionary.new;
	// a fader whose voices were changed by something else (mouse, or another fader while LINKED) lets go,
	// and only acts again once it catches up with the new value. Without this, a resting fader that had
	// been caught earlier yanked the voices back on every twitch (the 2026-09-28 "spazzing" faders).
	~mkRelease = { |ccs| ccs.do { |c| ~mkCaught[c] = false; ~mkLast[c] = nil } };
	// jitter filter: a fader keeps moving freely in the direction it is going; turning back needs TWO
	// messages in a row, both at least 4 steps (of 127) back. Measured 2026-09-28 with nobody touching it:
	// fader 7 sent 0,2,1,0,2,... ~4/s and fader 8 sent 119,114,117,114,119,... ~100/s. Noise flips
	// direction on every message, a hand turning back does not, so the noise never gets through.
	~mkDir = IdentityDictionary.new; ~mkPend = IdentityDictionary.new;
	~mkSteady = { |cc, val| var held = ~mkHeld[cc], d, ok = false;
		if (held.isNil) { ~mkHeld[cc] = val; ok = true } {
			d = val - held;
			// any message that is not a >= 4-step turn-back clears the pending turn (repeats included),
			// so only two such messages IN A ROW turn a fader around
			case
				{ d == 0 } { ~mkPend[cc] = nil }
				{ d.sign == (~mkDir[cc] ? 0) } { ok = true; ~mkPend[cc] = nil }
				{ d.abs >= 4 and: { ~mkPend[cc] == d.sign } } { ok = true; ~mkPend[cc] = nil }
				{ d.abs >= 4 } { ~mkPend[cc] = d.sign }
				{ ~mkPend[cc] = nil };
			if (ok) { ~mkHeld[cc] = val; ~mkDir[cc] = d.sign } };
		ok };
	// soft takeover: a control only acts once it has passed through (or come within 3 % of) the current value
	~mkPick = { |cc, v, current|
		var last = ~mkLast[cc], caught = ~mkCaught[cc] ? false;
		if (caught.not) {
			if (((v - current).abs < 0.03) or: { last.notNil and: { ((last - current).sign != (v - current).sign) } }) { caught = true };
		};
		~mkLast[cc] = v; ~mkCaught[cc] = caught; caught;
	};
	~mkCC = (sliders: (0..7), knobs: (16..23), sBtn: (32..39), mBtn: (48..55), rBtn: (64..71), play: 41, stop: 42, cycle: 46, rew: 43, ff: 44, rec: 45);
	~mkGroupMorph = { |g| var vs = ~mkGroupVoices[g]; if (vs.isEmpty) { 0 } { vs.collect { |i| ~b36Morph[i] }.mean } };
	// sound follows every fader message; the on-screen sliders catch up in the 4-per-second GUI tick (~b36Rout)
	~mkSetGroup = { |g, v| (if (~mkLink) { (0..(nv - 1)) } { ~mkGroupVoices[g] }).do { |i| ~b36SetMorph.(i, v) }; ~b36SliderSync = true;
		if (~mkLink) { ~mkRelease.((0..7).reject { |c| c == g }) } };   // LINKED: only the fader being moved drives
	// KNOBS (2026-10-01, Jon): knob g = the FORCE offset depth of fader group g (0 = none, full = +-0.5). Volume, gap,
	// voices, speed, spread, glide, fade, nCVI are on screen only (before: 1 voices, 2 speed, 3 spread, 4 glide,
	// 5 volume, 6 fade, 7 gap, 8 nCVI).
	~mkKnob = { |g, v|
		if (~mkPick.(16 + g, v, ~b36F[\knob][g])) { ~b36F[\knob][g] = v; ~b36FApply.(g);
			~uiLater.(("mkFK" ++ g).asSymbol, { ~b36FKnobs[g].value = v; ~b36FKText[g].string = "+-" ++ (~b36FAmt.(g) * 100).round.asInteger ++ "%" }) } };
	// a knob moved on screen: its Korg knob must catch up again (soft takeover)
	8.do { |g| ~b36FKnobs[g] !? { |kn| var act = kn.action; kn.action = { |w| act.value(w); ~mkRelease.([16 + g]) } } };
	~mkButton = { |num|
		var g;
		g = ~mkCC.sBtn.indexOf(num); g !? { ~mkGroupVoices[g].do { |i| ~b36Solo[i] = ~b36Solo[i].not }; ~b36ApplyOn.() };
		g = ~mkCC.mBtn.indexOf(num); g !? { ~mkGroupVoices[g].do { |i| ~b36Mute[i] = ~b36Mute[i].not }; ~b36ApplyOn.() };
		// R1-R8 (2026-10-02, Jon): FORCE on/off for fader group g (the "on" box above each group; off at every load)
		g = ~mkCC.rBtn.indexOf(num); g !? { ~b36F[\on][g] = ~b36F[\on][g].not; ~b36FApply.(g);
			~uiLater.(("mkFT" ++ g).asSymbol, { ~b36FToggles[g] !? { |c| c.value = ~b36F[\on][g] };
				~b36FKText[g] !? { |t| t.string = "+-" ++ (~b36FAmt.(g) * 100).round.asInteger ++ "%" } }) };
		if (num == ~mkCC[\rew]) { ~spRollOffsets.(~spP.spread, Date.getDate.rawSeconds.asInteger) };   // was R1
		if (num == ~mkCC[\rec]) { ~b36PulseBox !? { |b| var on = b.value.not; ~b36PulseSet.(on); ~uiLater.(\mkPulse, { b.value = on }) } };
		if (num == ~mkCC[\ff]) { ~b36OcBox !? { |b| var on = b.value.not; ~b36OcSet.(on); ~uiLater.(\mkOcean, { b.value = on }) } };
		if (num == ~mkCC[\play]) { ~b36Set.(~mkLastN.max(1)); ~b36Slider.value = ~b36N / nv };
		if (num == ~mkCC[\stop]) { if (~b36N > 0) { ~mkLastN = ~b36N }; ~b36Set.(0); ~b36Slider.value = 0 };
		if (num == ~mkCC.cycle) { ~mkLink = ~mkLink.not; ~mkStatus.string = "nanoKONTROL2: connected" ++ if (~mkLink) { "   [sliders LINKED]" } { "" } };
	};
	if (~b36Midi) {
		// the surface is SHARED with wall_live / sweep_live: ~mkOwner says who listens; TRACK < > passes it on
		~mkOwners = (~mkOwners ? []).add(\breath36).asSet.asArray; ~mkOwner = \breath36;
		~mkPassOwner = { |dir| ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + dir);
			{ ~mkStatus.string = "nanoKONTROL2 owner: " ++ ~mkOwner ++ if (~mkOwner == \breath36) { "  (this window)" } { "" } }.defer };
		MIDIClient.init(verbose: false); MIDIIn.connectAll(verbose: false);   // always rescan: picks up a controller plugged in after SC started
		if (MIDIClient.sources.any { |e| e.device.contains("nanoKONTROL") }) { ~mkStatus.string = "nanoKONTROL2: connected, this window owns it (TRACK < > passes it)" } { ~mkStatus.string = "nanoKONTROL2: not found (plug in, re-evaluate)" };
		MIDIdef.cc(\b36cc, { |val, cc, chan|
			var v = val / 127;
			{
				var g = ~mkCC.sliders.indexOf(cc), k = ~mkCC.knobs.indexOf(cc);
				if ((cc == 58 or: { cc == 59 }) and: { val > 0 }) { ~mkPassOwner.(if (cc == 59) { 1 } { -1 }) };
				if (~mkOwner == \breath36 and: { (g.isNil and: { k.isNil }) or: { ~mkSteady.(cc, val) } }) {
					g !? { if (~mkPick.(cc, v, ~mkGroupMorph.(g))) { ~mkSetGroup.(g, v) } };
					k !? { ~mkKnob.(k, v) };
					if (g.isNil and: { k.isNil } and: { val > 0 } and: { cc != 58 } and: { cc != 59 }) { ~mkButton.(cc) };
				};
			}.defer;
		}).permanent_(true);
		MIDIdef.noteOn(\b36note, { |vel, note, chan| {   // Jon's unit sends some buttons as notes
			if (note == 58 or: { note == 59 }) { ~mkPassOwner.(if (note == 59) { 1 } { -1 }) } { if (~mkOwner == \breath36) { ~mkButton.(note) } } }.defer }).permanent_(true);
	};

	~b36Win.onClose = { ~b36Rout.stop; ~b36Players.do(_.stop); ~b36Synths.do(_.free);
		~b36FCRout.stop; ~b36FCSyn !? { ~b36FCSyn.free }; ~b36FCSyn = nil; ~b36FCBus.free;
		~b36PulseRout !? { ~b36PulseRout.stop }; OSCdef(\b36Beat).free; ~b36Pulse[\on] = false; ~b36LoadRout !? { ~b36LoadRout.stop };
		~b36OcHearSyn !? { ~b36OcHearSyn.free }; ~b36OcHearBuf !? { ~b36OcHearBuf.free }; ~b36Ocean[\on] = false; ~mkOwners !? { ~mkOwners.remove(\breath36); ~mkOwner = ~mkOwners.first };
		~b36Silent.free; ~b36MorphBus.free; ~b36GainBus.free; ~b36VolBus !? { ~b36VolBus.free }; ~b36VolBus = nil;
		MIDIdef(\b36cc).free; MIDIdef(\b36note).free;
		~spBufs.flat.do { |b| b !? { b.free } } };
	// ---- the speed levels, in the background ----
	~b36LoadRout !? { ~b36LoadRout.stop };
	~b36LoadRout = Routine {
		~b36SpeedLevels.do { |lv, li| var k = li + 1, t0 = Main.elapsedTime, bufs, missing;
			bufs = nv.collect { |i| ~spFiles[i][li] !? { |files| files.collect { |p| Buffer.read(s, p) } } };
			s.sync;
			block { |done| 5.do { missing = bufs.flat.reject(_.isNil).select { |b| b.numFrames.isNil };
				if (missing.isEmpty) { done.value }; missing.do { |b| b.updateInfo }; s.sync; 0.2.wait } };
			nv.do { |i| ~spBufs[i][k] = bufs[i] };
			~spAvail = ~spBufs.collect { |sets| sets.detectIndex(_.isNil) ? sets.size };
			~b36LoadedLevels = k;
			{ ~spSetAll.(~spP.x) }.defer;   // voices waiting for a faster level step up now
			("breath36: speed " ++ lv ++ "x loaded (" ++ (Main.elapsedTime - t0).round(0.1) ++ " s)").postln;
			~b36Dirty = true;
		};
		"breath36: all speed levels loaded".postln;
	}.play(AppClock);
	("BREATH36_READY  (" ++ nv ++ " voices tiled " ++ performers.join("/") ++ "; speed levels " ++ levelNames.asString
		++ "; groups " ++ ~mkGroupVoices.collect(_.size).asString ++ ")").postln;
	};
};
)
