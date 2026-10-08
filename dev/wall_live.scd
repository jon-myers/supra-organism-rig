/*
DEV COPY (rig/dev/wall_live.scd, 2026-09-29): master and layer trims act LIVE on everything already sounding
(stable ../wall_live.scd set them only for NEW events, so the master seemed to do nothing -- chords last 300 s).
All layers now go to a private wall bus -> \wlMaster (master gain) -> ~wlOutBus -> limiter; each layer's
(level + trim) is a control bus every event reads. Otherwise identical.

wall_live.scd -- the WALL OF SOUND generated live: three layers, three DENSITY sliders.

bell.py's placement rule, run in real time: every 0.25 s each layer counts its committed events
(an event stops counting for its closing 20-35 %) and, if that count is below the layer's TARGET,
starts another one after an entry gap of 1.5-4 s. Offline the target was a bell curve over 12
minutes; here the target IS the slider. Density is the number of events sounding, not a level.
  dyads   0-8   the 24 harmonium dyad stems (wall_of_sound/stems), no-repeat draw (age^2),
                per-event gain 0..-6 dB, random position and width, apex envelope
  voices  0-4   segments of the four Aug 28 in-tune singers (analysis/live_assets.json), one
                segment per singer at a time, shuffled without reuse; distance EQ (80 Hz HPF,
                -4 dB @200 low shelf, -5 dB @7k high shelf) and the bell.py room (PartConv IR)
  chords  0-2   the two out-of-tune July 23 chords, long fades, fixed pan/width
Levels are bell.py's: everything relative to the median single dyad (+1 dB voices, +3 dB chords).
Lowering a slider never cuts anything: events finish on their own (HUSH fades all out, CUT stops).
Output: ~wlOutBus (default 0) on the default server. nanoKONTROL2 (when ~mkOwner == \wall):
sliders 1-3 = densities, knobs 1-3 = layer trims, knob 5 = master; TRACK < > passes the surface
between patches. Select all, evaluate (after breath36.scd if both are used).
AMBI (2026-10-01): with ~wlAmbi true (the AMBI tab's "WALL -> AMBI" tick-box) and dev/ambi.scd loaded, NEW events go to the
ambisonic field instead: pos -> azimuth pos * pi (the same random placement, now round the whole circle), dyads keep their
L / R as an arc set by their width, voices sit at their singer's home round the circle (dry by default), out-of-tune
chords are spread very wide (three decorrelated copies per channel over each half circle). Room per layer ~wlRoomDb
(default dyads none, voices none, chords -20 dB). Events already sounding finish where they started.
OMBAK (2026-10-03, Jon: "thats pretty cool with the latest wall of sound ombak thing, lets get that wired up in supercollider"):
every dyad and voice is mixed with an OFFSET COPY of itself whose offset follows the dancers, as in sharp/ombak/ombak_wall_combined.py
(OM_SUBTLE=1), on the out-of-tune chords too. Each event keeps its own ratio (x0.7-1.4) to its driver's rate, so no two beat
alike. DRIVE (Jon: "the wall is for combined action"): together (default) = every event follows the ensemble (AC of 1-6
pooled), so the whole wall beats as one; each dancer = every new event takes the next of sensors 1-6. Switching retargets the events
already sounding. The central sensor (7) does not drive the wall (2026-10-03). Activity = AC RMS over
0.5 s / that sensor's 95th percentile in the 10-02 run (clipped 1.5); offset rising fast (0.12 s), relaxing slowly (1.5 s):
  freq   FreqShift copy (true ombak: every partial beats at the same rate)  depth x (0.5 + 9.5 act^2) Hz
  pitch  PitchShift copy (naive: higher partials beat faster)               depth x (3 + 47 act^2) cents
depth 0.1 = the subtle render (0.05-1 Hz / 0.3-5 cents), 1 = the first, strong one. All of it acts LIVE on events already sounding.
Needs the FORCE tab (live OSC). Korg: knob 4 = depth, knob 6 = copy level.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~wlRoot = here +/+ ".." +/+ ".." +/+ "wall_of_sound";   // dev/ is one level deeper
~wlOutBus = ~wlOutBus ? 0;
~wlP = (dyads: 0, voices: 0, chords: 0, master: 0.7, trim: [0, 0, 0], step: 0.25, relTime: 4);
~wlLevelsDb = [0, 1, 3];
~wlOmP = (on: true, mode: 0, depth: 0.1, wetDb: 0, drive: 0).putAll(~wlOmP ? ());   // drive 0 = together (ensemble), 1 = each dancer (1-6)   // OMBAK: mode 0 = freq shift, 1 = pitch shift   // per layer, relative to the median dyad (bell.py VOICE_REL_DB / CHORD_REL_DB)
s = Server.default;
s.options.numBuffers = s.options.numBuffers.max(4096); s.options.memSize = s.options.memSize.max(2.pow(18));
s.waitForBoot {
	var assets = File.readAllString(~wlRoot +/+ "analysis" +/+ "live_assets.json").parseJSON, c = assets["consts"];
	var entryGap = c["entry_gap"].collect(_.asFloat), tailFrac = c["tail_frac"].collect(_.asFloat), dyadGain = c["dyad_gain_db"].collect(_.asFloat);
	var irPath = ~wlRoot +/+ "analysis" +/+ "room_ir_44k.wav", ir, irFrames, fftSize = 2048, irSpec;
	var voiceIds = assets["voices"].keys.asArray.sort, chordIds = assets["chords"].keys.asArray.sort;
	// ---- tear the previous instance down NOW (its window's onClose would run late and free the NEW buffers) ----
	~wlWin !? { ~wlWin.onClose = nil; if (~wlWin.isClosed.not) { ~wlWin.close } };
	~wlTick !? { ~wlTick.stop }; ~wlRout !? { ~wlRout.stop };
	~wlGroup !? { ~wlGroup.free }; ~wlRoom !? { ~wlRoom.free }; ~wlLimiter !? { ~wlLimiter.free; ~wlLimiter = nil };
	~wlDry !? { ~wlDry.free }; ~wlSend !? { ~wlSend.free };
	~wlOmAct !? { ~wlOmAct.free }; ~wlOmAct = nil; ~wlOmBus !? { ~wlOmBus.free }; ~wlOmCtl !? { ~wlOmCtl.free };
	~wlMasterSyn !? { ~wlMasterSyn.free }; ~wlMixBus !? { ~wlMixBus.free };
	~wlMasterA !? { ~wlMasterA.free }; ~wlMasterA = nil; ~wlRoomA !? { ~wlRoomA.free }; ~wlRoomA = nil; ~wlAmbiBus !? { ~wlAmbiBus.free }; ~wlSendA !? { ~wlSendA.free }; ~wlAmpBus !? { ~wlAmpBus.do(_.free) };
	((~wlDyadBufs ? []) ++ (~wlVoiceBufs ? []) ++ (~wlChordBufs ? []) ++ (~wlIrBufs ? [])).do { |b| b !? { b.free } };
	~wlDyadBufs = nil; ~wlVoiceBufs = nil; ~wlChordBufs = nil; ~wlIrBufs = nil;
	MIDIdef(\wlcc).free; MIDIdef(\wlnote).free;
	s.sync;

	// ---- buffers ----
	// a relative "file" (the student pack's live_assets.json) is relative to wall_of_sound/
	~wlFile = { |f| if (f.beginsWith("/")) { f } { ~wlRoot +/+ f } };
	~wlDyadBufs = assets["dyads"].collect { |d| Buffer.read(s, ~wlFile.(d["file"])) };
	~wlVoiceBufs = voiceIds.collect { |v| Buffer.read(s, ~wlFile.(assets["voices"][v]["file"])) };
	~wlChordBufs = chordIds.collect { |k| Buffer.read(s, ~wlFile.(assets["chords"][k]["file"])) };
	ir = Buffer.read(s, irPath); s.sync;
	irFrames = ir.numFrames; irSpec = 2.collect { |ch| var mono = Buffer.alloc(s, irFrames, 1), spec = Buffer.alloc(s, PartConv.calcBufSize(fftSize, ir)); [mono, spec, ch] };
	irSpec.do { |t| var mono = t[0], spec = t[1], ch = t[2]; ir.loadToFloatArray(action: { |arr| mono.loadCollection(arr.clump(2).collect(_[ch]), action: { spec.preparePartConv(mono, fftSize) }) }) };
	s.sync; 0.5.wait;
	~wlIrBufs = [ir] ++ irSpec.collect(_[0]) ++ irSpec.collect(_[1]);
	("wall_live: " ++ ~wlDyadBufs.size ++ " dyads, " ++ ~wlVoiceBufs.size ++ " voices, " ++ ~wlChordBufs.size ++ " chords, IR " ++ (irFrames / 44100).round(0.01) ++ " s").postln;

	// ---- synths ----
	~wlDry = Bus.audio(s, 2); ~wlSend = Bus.audio(s, 2);
	~wlMixBus = Bus.audio(s, 2);                      // the whole wall, before the master
	~wlAmpBus = 3.collect { Bus.control(s, 1) };       // per layer (level + trim), read live by every event
	// ---- OMBAK: 8 drivers (sensors 1-7, ensemble) -> ~wlOmBus [Hz x 8, cents x 8]; ~wlOmCtl [on, mode, copy amp] ----
	~wlOmBus = Bus.control(s, 16); ~wlOmCtl = Bus.control(s, 3);
	~wlOmP95 = [0.721, 0.5816, 0.8169, 0.6585, 0.6852, 0.6536, 0.6305, 0.5748];   // 0.5-s AC RMS, 95th pct, 10-02 11:47-13:04 (ombak_demo.py)
	SynthDef(\wlOmAct, { |fbus = 0, out = 0, depth = 0.1|
		var ac = In.kr(fbus + 7, 7).clip(-1, 1), sq = ac.squared ++ [ac.keep(6).squared.sum / 6];
		var rms = sq.collect { |q| (RunningSum.ar(K2A.ar(q), 24000) / 24000).max(0).sqrt };          // 0.5-s boxcar, as offline
		var act = (A2K.kr(rms) / \p95.kr(0.7 ! 8)).clip(0, 1.5).squared;
		Out.kr(out, (LagUD.kr(0.5 + (9.5 * act), 0.12, 1.5) * depth) ++ (LagUD.kr(3 + (47 * act), 0.12, 1.5) * depth)) }).add;
	// the offset copy, mixed power-preserving with the original; reads the driver's offset LIVE
	~wlOm = { |x, drv|
		var mul = \omMul.kr(1), hz = In.kr(\omBus.kr(0) + drv) * mul, cents = In.kr(\omBus.kr(0) + 8 + drv) * mul, c = In.kr(\omCtl.kr(0), 3);
		var w = (c[0] * c[2]).lag(0.3), y = x.asArray.collect { |ch|
			var cp = Select.ar(c[1], [FreqShift.ar(ch, hz), PitchShift.ar(ch, 0.15, 2 ** (cents / 1200), 0, 0.004)]);
			(ch + (w * cp)) / (1 + w.squared).sqrt };
		if (y.size == 1) { y[0] } { y } };
	SynthDef(\wlDyad, { |gate = 1, rel = 4, buf, dur = 30, apex = 0.5, gain = 1, pos = 0, width = 0.5, amp = 1, out = 0, drv = 0|
		var sig = ~wlOm.(PlayBuf.ar(2, buf, BufRateScale.kr(buf), doneAction: 2), drv);
		var env = EnvGen.kr(Env([0, 1, 0], [apex * dur, (1 - apex) * dur], \sin), doneAction: 2);
		var mono = sig.sum * 0.7071, w = width.clip(0, 1);
		var st = Balance2.ar(sig[0], sig[1], pos);   // keep the stem's own stereo, lean it
		var cut = EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2);   // release on demand (slider lowered)
		Out.ar(out, (st * w + (Pan2.ar(mono, pos) * (1 - w))) * env * cut * gain * amp);
	}).add;
	SynthDef(\wlVoice, { |gate = 1, rel = 4, buf, start = 0, dur = 10, fade = 0.3, gain = 1, pos = 0, amp = 1, dry = 0, send = 0, sendAmt = 0.4, drv = 4|
		var sig = ~wlOm.(PlayBuf.ar(1, buf, BufRateScale.kr(buf), 1, start, 0), drv);
		var env = EnvGen.kr(Env.linen(fade, (dur - (2 * fade)).max(0.05), fade, 1, \sine), doneAction: 2);
		sig = BHiPass.ar(BHiPass.ar(sig, 80), 80);
		sig = BLowShelf.ar(sig, 200, 0.707, -4); sig = BHiShelf.ar(sig, 7000, 0.707, -5);
		sig = sig * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp;
		Out.ar(dry, Pan2.ar(sig, pos)); Out.ar(send, Pan2.ar(sig * sendAmt, pos * 0.5));
	}).add;
	SynthDef(\wlChord, { |gate = 1, rel = 4, buf, start = 0, dur = 300, fadeIn = 45, fadeOut = 45, gain = 1, pos = 0, width = 0.5, amp = 1, out = 0, drv = 7|
		var sig = ~wlOm.(PlayBuf.ar(2, buf, BufRateScale.kr(buf), 1, start, 0), drv);
		var env = EnvGen.kr(Env.linen(fadeIn, (dur - fadeIn - fadeOut).max(1), fadeOut, 1, \sine), doneAction: 2);
		var mono = sig.sum * 0.7071, w = width.clip(0, 1);
		Out.ar(out, (Balance2.ar(sig[0], sig[1], pos) * w + (Pan2.ar(mono, pos) * (1 - w))) * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp);
	}).add;
	SynthDef(\wlMaster, { |in = 0, out = 0, master = 0.7| Out.ar(out, In.ar(in, 2) * master.lag(0.1)) }).add;
	// ---- AMBISONIC versions (2026-10-01, Jon): the stereo placement expanded to the circle. Used for NEW events while
	// ~wlAmbi is true and dev/ambi.scd's ~ambiBus exists. pos -1..1 -> azimuth pos * pi (+ = left; -1 and +1 = behind),
	// so a uniform pos is uniform round the circle. Everything goes to ~wlAmbiBus (B-format) -> \wlMasterA -> ~ambiBus.
	SynthDef(\wlDyadA, { |gate = 1, rel = 4, buf, dur = 30, apex = 0.5, gain = 1, pos = 0, width = 0.5, amp = 1, out = 0, drv = 0|
		var sig = ~wlOm.(PlayBuf.ar(2, buf, BufRateScale.kr(buf), doneAction: 2), drv);
		var env = EnvGen.kr(Env([0, 1, 0], [apex * dur, (1 - apex) * dur], \sin), doneAction: 2);
		var cut = EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2);
		var az = pos * pi, half = width.clip(0, 1) * (pi / 3);   // the stem's L / R spread over an arc: width 0.3-0.9 -> 36-108 deg
		sig = sig * env * cut * gain * amp;
		Out.ar(out, FoaPanB.ar(sig[0], az + half, 0) + FoaPanB.ar(sig[1], az - half, 0));
	}).add;
	SynthDef(\wlVoiceA, { |gate = 1, rel = 4, buf, start = 0, dur = 10, fade = 0.3, gain = 1, pos = 0, amp = 1, out = 0, send = 0, sendAmt = 0, drv = 4|
		var sig = ~wlOm.(PlayBuf.ar(1, buf, BufRateScale.kr(buf), 1, start, 0), drv);
		var env = EnvGen.kr(Env.linen(fade, (dur - (2 * fade)).max(0.05), fade, 1, \sine), doneAction: 2);
		sig = BHiPass.ar(BHiPass.ar(sig, 80), 80);
		sig = BLowShelf.ar(sig, 200, 0.707, -4); sig = BHiShelf.ar(sig, 7000, 0.707, -5);
		sig = sig * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp;
		Out.ar(out, FoaPanB.ar(sig, pos * pi, 0)); Out.ar(send, (sig * sendAmt.lag(0.2)) ! 2);
	}).add;
	// chords: VERY wide -- each channel as three slightly delayed copies spread over its half of the circle (L: +30/+90/+150 deg,
	// R: -30/-90/-150), so the chord surrounds rather than sitting at two points
	SynthDef(\wlChordA, { |gate = 1, rel = 4, buf, start = 0, dur = 300, fadeIn = 45, fadeOut = 45, gain = 1, amp = 1, out = 0, send = 0, sendAmt = 0, drv = 7|
		var sig = ~wlOm.(PlayBuf.ar(2, buf, BufRateScale.kr(buf), 1, start, 0), drv);
		var env = EnvGen.kr(Env.linen(fadeIn, (dur - fadeIn - fadeOut).max(1), fadeOut, 1, \sine), doneAction: 2);
		var dl = [0, 0.0113, 0.0237], b;
		sig = sig * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp;
		b = [30, 90, 150].collect { |deg, k| FoaPanB.ar(DelayN.ar(sig[0], 0.03, dl[k]), deg.degrad, 0) * 0.5774 }.sum
			+ [-30, -90, -150].collect { |deg, k| FoaPanB.ar(DelayN.ar(sig[1], 0.03, dl[2 - k]), deg.degrad, 0) * 0.5774 }.sum;
		Out.ar(out, b); Out.ar(send, sig * sendAmt.lag(0.2));
	}).add;
	// the room for AMBI events: same IR, its L / R placed at +-90 deg (subtle by default; voices 0, chords -20 dB)
	SynthDef(\wlRoomA, { |send, specL, specR, out = 0|
		var sIn = In.ar(send, 2);
		Out.ar(out, FoaPanB.ar(PartConv.ar(sIn[0], fftSize, specL), 0.5pi, 0) + FoaPanB.ar(PartConv.ar(sIn[1], fftSize, specR), -0.5pi, 0));
	}).add;
	SynthDef(\wlMasterA, { |in = 0, out = 0, master = 0.7| Out.ar(out, In.ar(in, 4) * master.lag(0.1)) }).add;
	SynthDef(\wlRoom, { |dry, send, specL, specR, wet = 0.4, out = 0|
		var d = In.ar(dry, 2), sIn = In.ar(send, 2);
		var w = [PartConv.ar(sIn[0], fftSize, specL), PartConv.ar(sIn[1], fftSize, specR)];
		Out.ar(out, d + (w * wet));
	}).add;
	s.sync;
	~wlRoom = Synth.tail(s, \wlRoom, [\dry, ~wlDry, \send, ~wlSend, \specL, irSpec[0][1], \specR, irSpec[1][1], \wet, (-8).dbamp / 0.4, \out, ~wlMixBus]);   // IR is unit-ENERGY (bell.py make_ir); send 0.4 x wet 0.4/... = -8 dB wet
	~wlGroup = Group.head(s);
	~wlOmSet = { ~wlOmCtl.setn([~wlOmP.on.asInteger, ~wlOmP.mode, ~wlOmP.wetDb.dbamp]); ~wlOmAct !? { ~wlOmAct.set(\depth, ~wlOmP.depth) } };
	if (~fhBus.isNil or: { ~fhBus.server != s }) { ~fhBus = Bus.control(s, 14) };   // WALL loads before FORCE; force_hub.scd adopts this bus
	~wlOmAct = Synth.before(~wlGroup, \wlOmAct, [\fbus, ~fhBus.index, \out, ~wlOmBus, \p95, ~wlOmP95, \depth, ~wlOmP.depth]);
	~wlOmSet.(); ~wlOmK = 0;
	~wlOmDrv = { if (~wlOmP.drive == 0) { 7 } { var d = ~wlOmK % 6; ~wlOmK = ~wlOmK + 1; d } };   // 7 = ensemble of 1-6; 0-5 = sensors 1-6
	~wlOmRetarget = { ~wlEvents.do { |evs| evs.do { |e| e[\syn] !? { |sy| sy.set(\drv, ~wlOmDrv.()) } } } };
	~wlOmArgs = { |drv| [\drv, drv, \omBus, ~wlOmBus.index, \omCtl, ~wlOmCtl.index, \omMul, exprand(0.7, 1.4)] };   // each event its own ratio: never two at the same rate
	SynthDef(\wlLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add; s.sync;
	~wlMasterSyn = Synth.after(~wlRoom, \wlMaster, [\in, ~wlMixBus, \out, ~wlOutBus, \master, ~wlP.master]);
	~wlLimiter !? { ~wlLimiter.free }; ~wlLimiter = Synth.after(~wlMasterSyn, \wlLimit, [\out, ~wlOutBus]);   // safety net
	// AMBI path: built when the first ambi event fires (dev/ambi.scd loads after this patch)
	~wlAmbi = ~wlAmbi ? false; ~wlRoomDb = ~wlRoomDb ? [-inf, -inf, -20];   // per layer: dyads, voices, chords (dB; -inf = none)
	~wlAmbiBus = Bus.audio(s, 4); ~wlSendA = Bus.audio(s, 2); ~wlMasterA = nil; ~wlRoomA = nil;
	~wlAmbiOn = { (~wlAmbi == true) and: { ~ambiBus.notNil } };
	~wlEnsureAmbi = { if (~wlMasterA.isNil) {
		~wlRoomA = Synth.after(~wlMasterSyn, \wlRoomA, [\send, ~wlSendA, \specL, irSpec[0][1], \specR, irSpec[1][1], \out, ~wlAmbiBus]);
		~wlMasterA = Synth.after(~wlRoomA, \wlMasterA, [\in, ~wlAmbiBus, \out, ~ambiBus.index, \master, ~wlP.master]) } };
	~wlRoomAmt = { |l| var db = ~wlRoomDb[l]; if (db <= -60) { 0 } { db.dbamp } };

	// ---- the engine: committed counts vs targets ----
	~wlEvents = [List.new, List.new, List.new];       // per layer: (end:, commit:, src:)
	~wlNextOk = [0, 0, 0]; ~wlCount = 0;
	~wlDyadFired = nil ! ~wlDyadBufs.size;
	~wlVoiceOrder = voiceIds.collect { |v| assets["voices"][v]["segments"].size.collect { |i| i }.scramble }; ~wlVoicePtr = 0 ! voiceIds.size;
	~wlSetLayerAmps = { 3.do { |l| ~wlAmpBus[l].set((~wlLevelsDb[l] + ~wlP.trim[l]).dbamp) } };
	~wlSetLayerAmps.();
	~wlLayerAmp = { |l| ~wlAmpBus[l].asMap };   // events read their layer's bus for their whole life; the master is on \wlMaster
	~wlNow = { Main.elapsedTime };
	~wlCommitted = { |l| ~wlEvents[l].count { |e| e.commit > ~wlNow.() } };
	~wlBusy = { |l| ~wlEvents[l].select { |e| e.end > ~wlNow.() }.collect(_.src) };
	~wlLog = { |str| { ~wlLast !? { ~wlLast.string = str } }.defer };
	~wlFire = [
		{   // dyad: Tenney-style age^2 draw
			var w = ~wlDyadBufs.size.collect { |k| var age = if (~wlDyadFired[k].isNil) { 24 } { (~wlCount - ~wlDyadFired[k]).clip(1, 24) }; age.squared };
			var k = (0..(~wlDyadBufs.size - 1)).wchoose(w.normalizeSum), d = assets["dyads"][k], dur = d["dur"].asFloat;
			var gainDb = rrand(dyadGain[0], dyadGain[1]) + d["gain_db"].asFloat, pos = 1.0.rand2, width = rrand(0.3, 0.9), apex = 0.5.gauss(0.125).clip(0.25, 0.75);
			var drv = ~wlOmDrv.();
			~wlLastSyn = if (~wlAmbiOn.()) { ~wlEnsureAmbi.();
				Synth(\wlDyadA, [\buf, ~wlDyadBufs[k], \dur, dur, \apex, apex, \gain, gainDb.dbamp, \pos, pos, \width, width, \amp, ~wlLayerAmp.(0), \out, ~wlAmbiBus] ++ ~wlOmArgs.(drv), ~wlGroup) } {
				Synth(\wlDyad, [\buf, ~wlDyadBufs[k], \dur, dur, \apex, apex, \gain, gainDb.dbamp, \pos, pos, \width, width, \amp, ~wlLayerAmp.(0), \out, ~wlMixBus] ++ ~wlOmArgs.(drv), ~wlGroup) };
			~wlDyadFired[k] = ~wlCount; ~wlLog.("dyad " ++ (k + 1) ++ "  " ++ dur.round(1) ++ " s  pos " ++ pos.round(0.01));
			(dur: dur, src: k);
		},
		{   // voice: a singer not currently sounding, next unused segment
			var busy = ~wlBusy.(1), cands = voiceIds.size.collect { |i| i }.reject { |i| busy.includes(i) };
			if (cands.isEmpty) { nil } {
				var i = cands.choose, v = voiceIds[i], segs = assets["voices"][v]["segments"], seg = segs[~wlVoiceOrder[i].wrapAt(~wlVoicePtr[i])];
				var a = seg[0].asFloat, b = seg[1].asFloat, dur = b - a, sr = ~wlVoiceBufs[i].sampleRate;
				var pos = (assets["voices"][v]["base_pan"].asFloat * 0.45 + 0.85.rand2).clip(-1, 1);
				~wlVoicePtr[i] = ~wlVoicePtr[i] + 1;
				~wlLastSyn = if (~wlAmbiOn.()) { ~wlEnsureAmbi.();
					// ambi: the singer's home is spread round the full circle (base_pan * pi), +- a little
					Synth(\wlVoiceA, [\buf, ~wlVoiceBufs[i], \start, a * sr, \dur, dur, \gain, assets["voices"][v]["gain_db"].asFloat.dbamp,
						\pos, (assets["voices"][v]["base_pan"].asFloat + 0.15.rand2).wrap(-1, 1), \amp, ~wlLayerAmp.(1), \out, ~wlAmbiBus, \send, ~wlSendA, \sendAmt, ~wlRoomAmt.(1)] ++ ~wlOmArgs.(~wlOmDrv.()), ~wlGroup) } {
					Synth(\wlVoice, [\buf, ~wlVoiceBufs[i], \start, a * sr, \dur, dur, \gain, assets["voices"][v]["gain_db"].asFloat.dbamp, \pos, pos,
					\amp, ~wlLayerAmp.(1), \dry, ~wlDry, \send, ~wlSend] ++ ~wlOmArgs.(~wlOmDrv.()), ~wlGroup) };
				~wlLog.("voice " ++ v ++ "  " ++ a.round(0.1) ++ "-" ++ b.round(0.1) ++ " s");
				(dur: dur, src: i);
			};
		},
		{   // chord: one of the two, if not sounding
			var busy = ~wlBusy.(2), cands = chordIds.size.collect { |i| i }.reject { |i| busy.includes(i) };
			if (cands.isEmpty) { nil } {
				var i = cands.choose, k = chordIds[i], ch = assets["chords"][k], dur = ch["dur"].asFloat, sr = ~wlChordBufs[i].sampleRate;
				~wlLastSyn = if (~wlAmbiOn.()) { ~wlEnsureAmbi.();
					Synth(\wlChordA, [\buf, ~wlChordBufs[i], \start, ch["start_s"].asFloat * sr, \dur, dur, \fadeIn, ch["fade_in"].asFloat, \fadeOut, ch["fade_out"].asFloat,
						\gain, ch["gain_db"].asFloat.dbamp, \amp, ~wlLayerAmp.(2), \out, ~wlAmbiBus, \send, ~wlSendA, \sendAmt, ~wlRoomAmt.(2)] ++ ~wlOmArgs.(~wlOmDrv.()), ~wlGroup) } {
					Synth(\wlChord, [\buf, ~wlChordBufs[i], \start, ch["start_s"].asFloat * sr, \dur, dur, \fadeIn, ch["fade_in"].asFloat, \fadeOut, ch["fade_out"].asFloat,
					\gain, ch["gain_db"].asFloat.dbamp, \pos, ch["pan"].asFloat, \width, (ch["width"].asFloat / 90).clip(0, 1), \amp, ~wlLayerAmp.(2), \out, ~wlMixBus] ++ ~wlOmArgs.(~wlOmDrv.()), ~wlGroup) };
				~wlLog.("chord " ++ k ++ "  " ++ dur.round(1) ++ " s");
				(dur: dur, src: i);
			};
		}
	];
	~wlTargets = { [~wlP.dyads, ~wlP.voices, ~wlP.chords] };
	// when a density is lowered below what is sounding, fade the excess out (newest first) instead of waiting
	~wlShed = { |l|
		var now = ~wlNow.(), live = ~wlEvents[l].select { |e| (e[\end] > now) and: { e[\released].isNil } };
		var excess = live.size - ~wlTargets.()[l].round.asInteger;
		if (excess > 0) {
			live.sort { |a, b| a[\start] > b[\start] }.keep(excess).do { |e|
				e[\syn] !? { |sy| sy.set(\rel, ~wlP[\relTime], \gate, 0) };
				e[\released] = true; e[\end] = now + ~wlP[\relTime]; e[\commit] = now };
		};
	};
	~wlTick = Routine { loop {
		var now = ~wlNow.(), tg = ~wlTargets.();
		3.do { |l|
			// List.newFrom: reject returns an ARRAY, whose .add below silently drops items past its capacity (4) unless the result
			// is reassigned -- that capped the wall at 4 tracked dyads while untracked ones piled up on the server (fixed 2026-10-01)
			~wlEvents[l] = List.newFrom(~wlEvents[l].reject { |e| e.end < now });
			if ((now >= ~wlNextOk[l]) and: { ~wlCommitted.(l) < tg[l].round }) {
				var ev = ~wlFire[l].value;
				ev !? { ~wlEvents[l].add((end: now + ev.dur, commit: now + (ev.dur * (1 - rrand(tailFrac[0], tailFrac[1]))), src: ev.src, syn: ~wlLastSyn, start: now));
					~wlCount = ~wlCount + 1; ~wlNextOk[l] = now + rrand(entryGap[0], entryGap[1]) };
			};
		};
		~wlDirty = true;
		~wlP.step.wait;
	} }.play(SystemClock);
	~wlHush = { ~wlP.dyads = 0; ~wlP.voices = 0; ~wlP.chords = 0; { ~wlSliders.do(_.value_(0)) }.defer; ~wlGroup.set(\amp, 0.0001) };   // running events keep their env; amp not lagged: use CUT for silence
	~wlCut = { ~wlHush.(); ~wlGroup.freeAll; ~wlEvents = [List.new, List.new, List.new] };

	// ---- GUI ----
	~wlWin !? { ~wlWin.onClose = nil; if (~wlWin.isClosed.not) { ~wlWin.close } };
	// ---- display rate limit (Jon: nothing on screen may change faster than 4 times a second -- vestibular
	// migraine). Sound changes at once; a control moved by the nanoKONTROL2 (or by another control) is
	// redrawn by ONE shared routine every 0.25 s: ~uiLater.(key, { widget.value = x }) -- the last one wins.
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
			p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
	~wlWin = if (~stHost.notNil) { ~stHost.(\wall) } { Window("wall of sound -- live", Rect(700, 60, 620, 520)).front };   // in a tab of show_tabs.scd, or its own window
	// nanoKONTROL2 follows the FRONT window: bringing this window forward makes it the owner
	~wlWin.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\wall).asSet.asArray; ~mkOwner = \wall;
		{ ~wlMidiText !? { ~wlMidiText.string = "nanoKONTROL2: this window (front)" } }.defer });
	~wlNames = ["dyads", "voices", "chords"]; ~wlMax = [8, 4, 2];
	~wlText = 3.collect { |l| StaticText().align_(\center).font_(Font.default.size_(28).boldVariant).string_("0") };
	~wlSub = 3.collect { StaticText().align_(\center).string_("sounding 0") };
	~wlSliders = 3.collect { |l| Slider().orientation_(\vertical).fixedWidth_(70).minHeight_(260).step_(0.5 / ~wlMax[l]).value_(0)
		.action_({ |sl| var v = sl.value * ~wlMax[l]; switch (l, 0, { ~wlP.dyads = v }, 1, { ~wlP.voices = v }, 2, { ~wlP.chords = v }); ~wlShed.(l); ~wlDirty = true }) };
	~wlTrims = 3.collect { |l| NumberBox().clipLo_(-24).clipHi_(12).step_(0.5).scroll_step_(0.5).decimals_(1).value_(0).fixedWidth_(56)
		.action_({ |nb| ~wlP.trim[l] = nb.value; ~wlSetLayerAmps.() }) };
	~wlMasterSl = Slider().orientation_(\vertical).fixedWidth_(50).minHeight_(260).value_(ControlSpec(-40, 6).unmap(~wlP.master.ampdb))
		.action_({ |sl| ~wlP.master = if (sl.value <= 0.001) { 0 } { ControlSpec(-40, 6).map(sl.value).dbamp }; ~wlMasterSyn !? { ~wlMasterSyn.set(\master, ~wlP.master) }; ~wlMasterA !? { ~wlMasterA.set(\master, ~wlP.master) }; ~wlDirty = true });
	~wlMasterText = StaticText().align_(\center).string_("");
	~wlLast = StaticText().string_("").fixedHeight_(18);
	~wlRelBox = NumberBox().clipLo_(0.2).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~wlP[\relTime]).fixedWidth_(56).action_({ |nb| ~wlP[\relTime] = nb.value });
	~wlHushBtn = Button().states_([["HUSH  (targets to 0, let events end)"]]).action_({ ~wlHush.() });
	~wlCutBtn = Button().states_([["CUT  (stop everything now)", Color.white, Color.red(0.6)]]).action_({ ~wlCut.() });
	~wlMidiText = StaticText().string_("").fixedHeight_(16);
	~wlOmBox = CheckBox().string_("OMBAK  (each dancer beats its dyad / voice)").value_(~wlOmP.on).action_({ |c| ~wlOmP.on = c.value; ~wlOmSet.() });
	~wlOmMode = PopUpMenu().items_(["freq shift (ombak)", "pitch shift (naive)"]).value_(~wlOmP.mode).fixedWidth_(150).action_({ |m| ~wlOmP.mode = m.value; ~wlOmSet.() });
	~wlOmDepth = NumberBox().clipLo_(0.01).clipHi_(2).step_(0.01).scroll_step_(0.01).decimals_(2).value_(~wlOmP.depth).fixedWidth_(52).action_({ |nb| ~wlOmP.depth = nb.value; ~wlOmSet.() });
	~wlOmWet = NumberBox().clipLo_(-40).clipHi_(6).step_(1).scroll_step_(1).decimals_(0).value_(~wlOmP.wetDb).fixedWidth_(44).action_({ |nb| ~wlOmP.wetDb = nb.value; ~wlOmSet.() });
	~wlOmDrive = PopUpMenu().items_(["together (ensemble 1-6)", "each dancer (1-6)"]).value_(~wlOmP.drive).fixedWidth_(170)
		.action_({ |m| ~wlOmP.drive = m.value; ~wlOmRetarget.() });
	~wlOmPreset = { |d| ~wlOmP.depth = d; ~wlOmDepth.value = d; ~wlOmSet.() };
	~wlOmText = StaticText().string_("").font_(Font.monospace(11)).fixedHeight_(16);
	~wlWin.layout = VLayout(
		StaticText().string_("density = how many events are sounding (bell.py's rule, live). Lowering never cuts.").fixedHeight_(18),
		HLayout(*(3.collect { |l| VLayout(StaticText().string_(~wlNames[l] ++ "  0-" ++ ~wlMax[l]).align_(\center).font_(Font.default.boldVariant),
			~wlText[l], HLayout(nil, ~wlSliders[l], nil).margins_(0), ~wlSub[l], HLayout(StaticText().string_("trim dB"), ~wlTrims[l])) }
			++ [VLayout(StaticText().string_("master").align_(\center).font_(Font.default.boldVariant), ~wlMasterText, HLayout(nil, ~wlMasterSl, nil).margins_(0), StaticText().string_(" "), StaticText().string_(" "))])),
		HLayout(StaticText().string_("fade-out when lowered (s)"), ~wlRelBox, nil), HLayout(~wlHushBtn, ~wlCutBtn),
		View().fixedHeight_(1).background_(Color.grey(0.6)),
		HLayout(~wlOmBox, ~wlOmDrive, ~wlOmMode, StaticText().string_("depth"), ~wlOmDepth, Button().states_([["subtle 0.1"]]).action_({ ~wlOmPreset.(0.1) }),
			Button().states_([["strong 1"]]).action_({ ~wlOmPreset.(1) }), StaticText().string_("copy dB"), ~wlOmWet, nil),
		~wlOmText, ~wlLast, ~wlMidiText
	);
	~wlDirty = true;
	~wlRout = Routine { loop {
		if (~wlDirty) { var tg = ~wlTargets.(); ~wlDirty = false;
			3.do { |l| ~wlText[l].string = tg[l].round(0.5).asString; ~wlSub[l].string = "sounding " ++ ~wlEvents[l].size ++ "  committed " ++ ~wlCommitted.(l) };
			~wlMasterText.string = if (~wlP.master <= 0.0001) { "-inf" } { ~wlP.master.ampdb.round(0.5).asString ++ " dB" } };
		~wlOmBus !? { ~wlOmBus.getn(16, { |v| ~wlOmNow = v }) };
		~wlOmNow !? { |v| var hz = ~wlOmP.mode == 0, vals = if (hz) { v.keep(8) } { v.drop(8) };
			~wlOmText.string = if (~wlOmP.on.not) { "ombak off" } { (if (hz) { "beats Hz " } { "cents " }) ++ if (~wlOmP.drive == 0) { "together " ++ vals[7].round(if (hz) { 0.01 } { 0.1 }) } { ["1", "2", "3", "4", "5", "6"].collect { |n, k| n ++ " " ++ vals[k].round(if (hz) { 0.01 } { 0.1 }) }.join("  ") } } };
		0.5.wait } }.play(AppClock);

	// ---- nanoKONTROL2, shared with breath36 via ~mkOwner ----
	~mkOwners = (~mkOwners ? []).add(\wall).asSet.asArray; ~mkOwner = \wall;
	~wlMidiText.string = "nanoKONTROL2: this patch owns the surface (TRACK < > to pass it)";
	~wlLast2 = IdentityDictionary.new; ~wlCaught = IdentityDictionary.new;
	~wlPick = { |cc, v, cur|
		var caught = ~wlCaught[cc] ? false, last = ~wlLast2[cc];
		if (caught.not) { if (((v - cur).abs < 0.03) or: { last.notNil and: { (last - cur).sign != (v - cur).sign } }) { caught = true } };
		~wlLast2[cc] = v; ~wlCaught[cc] = caught; caught };
	if (MIDIClient.initialized.not) { MIDIClient.init(verbose: false) }; MIDIIn.connectAll(verbose: false);
	MIDIdef.cc(\wlcc, { |val, cc, chan| var v = val / 127;
		{ if (cc == 58 or: { cc == 59 }) { if (val > 0) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (cc == 59) { 1 } { -1 });
				~wlMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } };
		  if (~mkOwner == \wall) {
			(0..2).do { |l| if (cc == l) { if (~wlPick.(cc, v, ~wlTargets.()[l] / ~wlMax[l])) { ~wlSliders[l].action.value(Ref(v)); ~uiLater.(~wlSliders[l], { ~wlSliders[l].value = v }) } } };
			(16..18).do { |k, l| if (cc == k) { if (~wlPick.(cc, v, (~wlP.trim[l] + 24) / 36)) { var x = v * 36 - 24; ~wlTrims[l].action.value(Ref(x)); ~uiLater.(~wlTrims[l], { ~wlTrims[l].value = x }) } } };
			if (cc == 20) { if (~wlPick.(cc, v, ~wlMasterSl.value)) { ~wlMasterSl.action.value(Ref(v)); ~uiLater.(~wlMasterSl, { ~wlMasterSl.value = v }) } };
			if (cc == 42 and: { val > 0 }) { ~wlHush.() };
			if (cc == 19) { if (~wlPick.(cc, v, (~wlOmP.depth / 0.02).log / 75.log)) { var d = (0.02 * (75 ** v)).round(0.01); ~wlOmP.depth = d; ~wlOmSet.(); ~uiLater.(~wlOmDepth, { ~wlOmDepth.value = d }) } };
			if (cc == 21) { if (~wlPick.(cc, v, (~wlOmP.wetDb + 30) / 36)) { var db = (v * 36 - 30).round(1); ~wlOmP.wetDb = db; ~wlOmSet.(); ~uiLater.(~wlOmWet, { ~wlOmWet.value = db }) } };
		  } }.defer }).permanent_(true);
	MIDIdef.noteOn(\wlnote, { |vel, note| { if (note == 58 or: { note == 59 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (note == 59) { 1 } { -1 });
		~wlMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } }.defer }).permanent_(true);

	~wlWin.onClose = { ~wlTick.stop; ~wlRout.stop; ~wlGroup.free; ~wlRoom.free; ~wlOmAct !? { ~wlOmAct.free }; ~wlOmAct = nil;
		~wlMasterA !? { ~wlMasterA.free }; ~wlMasterA = nil; ~wlRoomA !? { ~wlRoomA.free }; ~wlRoomA = nil; ~wlAmbiBus !? { ~wlAmbiBus.free }; ~wlSendA !? { ~wlSendA.free }; ~wlMasterSyn !? { ~wlMasterSyn.free; ~wlMasterSyn = nil }; ~wlMixBus !? { ~wlMixBus.free; ~wlMixBus = nil }; ~wlAmpBus !? { ~wlAmpBus.do(_.free); ~wlAmpBus = nil }; ~wlLimiter !? { ~wlLimiter.free; ~wlLimiter = nil }; ~wlDry.free; ~wlSend.free;
		MIDIdef(\wlcc).free; MIDIdef(\wlnote).free;
		(~wlDyadBufs ++ ~wlVoiceBufs ++ ~wlChordBufs ++ [ir] ++ irSpec.collect(_[0]) ++ irSpec.collect(_[1])).do(_.free);
		~mkOwners.remove(\wall); ~mkOwner = ~mkOwners.first };
	"WALL_LIVE_READY".postln;
};
)
