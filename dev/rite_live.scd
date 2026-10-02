/*
DEV COPY (rig/dev/rite_live.scd, 2026-10-01): AMBISONIC + TRIGGERS. ../rite_live.scd is the stable one, unchanged.
  AMBI     each render has its own direction round the circle, 45 deg apart, CLOCKWISE from the front (1 front, 2 front-
           right, 3 right, ... 8 front-left); its stereo becomes a 30-deg arc. Goes to dev/ambi.scd's ~ambiBus (quad +
           binaural there). Tick-box "AMBI" (on by default once the AMBI tab loads); off = the old stereo mix.
  OFFSETS  every render reads the shared playhead minus its OWN offset (0 .. "offset range" s, default 0.8): slightly out-of-
           step copies of the same music round the room (smear / echo / chorus). Each reader has its own loop-seam dip.
  GO 1-8   (buttons, and the Korg S buttons when the RITE tab owns it) fade that render in over "fade in" s to "GO level" with
           a fresh RANDOM offset; press again = fade out over "fade out" s. Faders still set levels directly.
  SWIRL    fires N neighbouring renders in circle order (clockwise or counter), each entering "step" ms after the last, with
           offsets GROWING along the way (k / (N-1) x range, +-10 % jitter), so the entrance travels round the room.
           Start = a chosen render or random. ALL = an 8-render swirl. SCATTER = all 8 at once, random offsets.
           RE-ROLL = new random offsets for what is sounding (glides over 1.5 s: a short tape-like pitch wobble).
           HUSH = fade everything out.

rite_live.scd -- eight concatenator renders of the Rite of Spring (1929 Stravinsky recording, first 2:30), all
looping together sample-aligned; eight faders bring each one in. Every fader starts at 0 (silent).

The eight (2026-09-29): one per corpus, microtonal (mic-) throughout, at whichever setting scored higher
in score_similarity.py (notes/scores/rite1929_*.csv); slot 8 is the densest (20 layers, rendered 2026-09-29).
Change ~rtPick before evaluating to swap any of them (file names in concatenator-corpus/out/listen-rite1929/).

ONE synth plays all eight: one shared playhead, eight buffer readers, so they can never drift apart. The loop seam
gets a 20-ms dip so the jump from 2:30 back to 0:00 does not click.
  faders   level of each render (squared: half way = -12 dB)      master   output level (limiter after it)
  PLAY/STOP, position slider = seek.
nanoKONTROL2 when ~mkOwner == \rite: sliders 1-8 = the eight levels (soft takeover + jitter filter, as breath36),
knob 5 master, PLAY / STOP. On-screen faders driven from the controller redraw 4 times a second; the sound
follows every message.
Select all, evaluate. Re-evaluating tears the previous instance down first.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~rtDir = here +/+ ".." +/+ ".." +/+ "concatenator-corpus" +/+ "out" +/+ "listen-rite1929";
~rtPick = ~rtPick ? [
	["everything",  "mic-everything__rite1929first150__part1000_pd0.50_t200_p10__norm.wav"],
	["harmonium",   "mic-harmonium__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["aeolian",     "mic-aeolian__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["voice+breath","mic-voicebreath__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["perc",        "mic-perc__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["fry",         "mic-fry__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["whoosh",      "mic-whoosh__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["dense (mic)", "mic-everything__rite1929first150__part1000_pd0.50_t200_p20__norm.wav"]
];
~rtOutBus = ~rtOutBus ? 0;
~rtLevels = 0 ! 8; ~rtMaster = 0.5;
~rtTP = ~rtTP ? (offRange: 0.8, fadeIn: 0.5, fadeOut: 2, goLevel: 0.85, swirlN: 4, step: 150, dir: 1, start: -1);
~rtOffs = 0 ! 8; ~rtGo = false ! 8; ~rtAmbi = ~rtAmbi ? false;
s = Server.default;
s.options.numBuffers = s.options.numBuffers.max(4096);
s.waitForBoot {
	var ok;
	// ---- tear down a previous evaluation ----
	~rtWin !? { if (~rtWin.isClosed.not) { ~rtWin.onClose = nil; ~rtWin.close } };
	~rtRout !? { ~rtRout.stop };
	~rtSynth !? { ~rtSynth.free }; ~rtSynth = nil; ~rtLimiter !? { ~rtLimiter.free }; ~rtLimiter = nil;
	~rtBufs !? { ~rtBufs.do { |b| b !? { b.free } } }; ~rtBufs = nil;
	~rtBufsHalf !? { ~rtBufsHalf.do { |b| b !? { b.free } } }; ~rtBufsHalf = nil;
	MIDIdef(\rtcc).free; MIDIdef(\rtnote).free; OSCdef(\rtPos).free;

	// per render: level with its own fade time (VarLag), read offset in seconds (lagged by offLag), direction az
	// HALF SPEED (2026-10-01, for Grisha): each render also has an octave-down version (bufs2, toward the half-speed target,
	// 300 s) on its OWN playhead (ph2, frames2: twice as long); \slow (0/1 per render, 50 ms crossfade) picks which one sounds.
	SynthDef(\rtMix, { |amp = 0.5, frames = 1, frames2 = 1, rate = 1, t_reset = 0, resetPos = 0, resetPos2 = 0, run = 0, out = 0, ambi = 0, abus = 0, offLag = 0|
		var bufs = \bufs.kr(0 ! 8), bufs2 = \bufs2.kr(0 ! 8), lv = VarLag.kr(\lv.kr(0 ! 8), \fade.kr(0.08 ! 8), warp: \sin);
		var slow = Lag.kr(\slow.kr(0 ! 8), 0.05);
		var off = Lag.kr(\off.kr(0 ! 8), offLag), sr = BufSampleRate.ir(bufs[0]);
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos), ph2 = Phasor.ar(t_reset, rate * run, 0, frames2, resetPos2);
		var reads = 8.collect { |i| var p = (ph - (off[i] * sr)).wrap(0, frames), p2 = (ph2 - (off[i] * sr)).wrap(0, frames2);
			var seam = (p.min(frames - p) / (0.01 * SampleRate.ir)).clip(0, 1);   // each reader's own 10 ms dip at the loop point
			var seam2 = (p2.min(frames2 - p2) / (0.01 * SampleRate.ir)).clip(0, 1);
			((BufRd.ar(2, bufs[i], p, 1, 4) * seam * (1 - slow[i])) + (BufRd.ar(2, bufs2[i], p2, 1, 4) * seam2 * slow[i])) * lv[i].squared };
		var st = reads.sum, half = 15.degrad;
		var bf = reads.collect { |r, i| var az = (i * -45).degrad;   // clockwise from the front (+ = left in ATK)
			FoaPanB.ar(r[0], az + half, 0) + FoaPanB.ar(r[1], az - half, 0) }.sum;
		SendReply.kr(Impulse.kr(4), '/rtPos', A2K.kr(ph));
		Out.ar(out, st * amp.lag(0.05) * (1 - ambi).lag(0.05));
		Out.ar(abus, bf * amp.lag(0.05) * ambi.lag(0.05));
	}).add;
	SynthDef(\rtLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add;
	s.sync;

	ok = ~rtPick.collect { |p| File.exists(~rtDir +/+ p[1]) };
	~rtBufs = ~rtPick.collect { |p, i| if (ok[i]) { Buffer.read(s, ~rtDir +/+ p[1]) } };
	s.sync;
	~rtFrames = ~rtBufs.select(_.notNil).collect(_.numFrames).minItem ? 0;
	~rtSR = ~rtBufs.detect(_.notNil) !? (_.sampleRate) ? 44100; ~rtDur = ~rtFrames / ~rtSR;
	~rtLimiter = Synth.tail(s, \rtLimit, [\out, ~rtOutBus]);
	~rtDummy4 !? { ~rtDummy4.free }; ~rtDummy4 = Bus.audio(s, 4);   // where the B-format goes while there is no AMBI tab
	~rtSynth = Synth.before(~rtLimiter, \rtMix, [\bufs, ~rtBufs.collect { |b| b !? (_.bufnum) ? 0 },
		\lv, ~rtLevels, \amp, ~rtMaster, \frames, ~rtFrames.max(1), \rate, ~rtSR / s.sampleRate, \run, 0, \out, ~rtOutBus,
		\ambi, 0, \abus, ~rtDummy4.index]);
	~rtPlaying = false; ~rtPos = 0;
	// ---- the octave-down (half-speed) renders: same picks, named *__rite1929half300__*, in listen-rite1929half/ ----
	~rtDirHalf = ~rtDir ++ "half";   // .../listen-rite1929 -> .../listen-rite1929half
	~rtHalfFile = { |i| ~rtPick[i][1].replace("rite1929first150", "rite1929half300") };
	~rtBufsHalf = ~rtBufsHalf ? (nil ! 8); ~rtSlow = false ! 8;
	~rtLoadHalf = { fork {
		8.do { |i| var f = ~rtDirHalf +/+ ~rtHalfFile.(i);
			if (~rtBufsHalf[i].isNil and: { File.exists(f) }) { ~rtBufsHalf[i] = Buffer.read(s, f) } };
		s.sync;
		~rtFrames2 = ~rtBufsHalf.select(_.notNil).collect(_.numFrames).minItem ? 1;
		~rtSynth !? { ~rtSynth.set(\bufs2, ~rtBufsHalf.collect { |b| b !? (_.bufnum) ? 0 }, \frames2, ~rtFrames2) };
		("rite: octave-down renders loaded " ++ ~rtBufsHalf.count(_.notNil) ++ "/8").postln;
		{ ~rtSlowBtns !? { 8.do { |i| ~rtSlowBtns[i].enabled = ~rtBufsHalf[i].notNil } } }.defer } };
	~rtSetSlow = { |i, on| if (on.not or: { ~rtBufsHalf[i].notNil }) { ~rtSlow[i] = on; ~rtSynth !? { ~rtSynth.seti(\slow, i, on.asInteger) } } };
	~rtLoadHalf.();
	OSCdef(\rtPos, { |m| ~rtPos = m[3] / ~rtSR }, '/rtPos');

	~rtSetLevel = { |i, v, fade = 0.08| ~rtLevels[i] = v.clip(0, 1);
		~rtSynth !? { ~rtSynth.seti(\fade, i, fade); ~rtSynth.seti(\lv, i, ~rtLevels[i]) }; ~rtDirty = true };
	// ---- AMBI + triggers ----
	~rtSetAmbi = { |on| ~rtAmbi = on and: { ~ambiBus.notNil };
		~rtSynth !? { ~rtSynth.set(\ambi, ~rtAmbi.asInteger, \abus, if (~rtAmbi) { ~ambiBus.index } { ~rtDummy4.index }) };
		if (on and: { ~ambiBus.isNil }) { "rite: AMBI needs the AMBI tab (dev/ambi.scd)".warn }; ~rtDirty = true };
	~rtSetOff = { |i, secs, glide = 0| ~rtOffs[i] = secs; ~rtSynth !? { ~rtSynth.set(\offLag, glide); ~rtSynth.seti(\off, i, secs) } };
	~rtRandOff = { ~rtTP[\offRange].rand };
	~rtGoOn = { |i, offset| if (~rtBufs[i].notNil) {
		if (~rtLevels[i] < 0.01) { ~rtSetOff.(i, offset ?? { ~rtRandOff.() }) };   // a new offset only from silence (no jump heard)
		~rtGo[i] = true; ~rtSetLevel.(i, ~rtTP[\goLevel], ~rtTP[\fadeIn]); ~rtFaderSync = true;
		if (~rtPlaying.not) { ~rtPlay.() } } };
	~rtGoOff = { |i| ~rtGo[i] = false; ~rtSetLevel.(i, 0, ~rtTP[\fadeOut]); ~rtFaderSync = true };
	~rtGoToggle = { |i| if (~rtGo[i] or: { ~rtLevels[i] > 0.01 }) { ~rtGoOff.(i) } { ~rtGoOn.(i) } };
	~rtSwirl = { |n| var start = if (~rtTP[\start] < 0) { 8.rand } { ~rtTP[\start] }, dir = ~rtTP[\dir], range = ~rtTP[\offRange];
		n = (n ? ~rtTP[\swirlN]).clip(1, 8);
		Routine { n.do { |k| var i = (start + (dir * k)).wrap(0, 7);
			var off = (if (n > 1) { k / (n - 1) } { 0 } * range * (1 + 0.1.rand2)).clip(0, range.max(0.001));
			{ ~rtGoOn.(i, off) }.defer; (~rtTP[\step] / 1000).wait } }.play(SystemClock) };
	~rtScatter = { 8.do { |i| ~rtGoOn.(i, ~rtRandOff.()) } };
	~rtReroll = { 8.do { |i| if (~rtLevels[i] > 0.01) { ~rtSetOff.(i, ~rtRandOff.(), 1.5) } } };
	~rtHush = { 8.do { |i| ~rtGoOff.(i) } };
	~rtPlay = { ~rtPlaying = true; ~rtSynth !? { ~rtSynth.set(\run, 1) }; { ~rtPlayBtn.value = 1 }.defer };
	~rtStop = { ~rtPlaying = false; ~rtSynth !? { ~rtSynth.set(\run, 0) }; { ~rtPlayBtn.value = 0 }.defer };
	~rtSeek = { |secs| ~rtSynth !? { ~rtSynth.set(\resetPos, (secs.clip(0, ~rtDur) * ~rtSR).asInteger,
		\resetPos2, ((secs.clip(0, ~rtDur) * 2 * ~rtSR).asInteger).min((~rtFrames2 ? 1) - 1), \t_reset, 1) } };   // half speed: the same moment is twice as far in

	// ---- GUI ----
	// ---- display rate limit (Jon: nothing on screen may change faster than 4 times a second -- vestibular
	// migraine). Sound changes at once; a control moved by the nanoKONTROL2 (or by another control) is
	// redrawn by ONE shared routine every 0.25 s: ~uiLater.(key, { widget.value = x }) -- the last one wins.
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
			p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
	~rtWin = if (~stHost.notNil) { ~stHost.(\rite) } { Window("rite of spring renders", Rect(80, 80, 820, 420)).front };
	~rtWin.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\rite).asSet.asArray; ~mkOwner = \rite;
		{ ~rtMidiText !? { ~rtMidiText.string = "nanoKONTROL2: this window (front)" } }.defer });
	~rtFaders = 8.collect { |i|
		Slider().orientation_(\vertical).minHeight_(180).fixedWidth_(46).value_(~rtLevels[i]).enabled_(ok[i])
			.action_({ |sl| ~rtSetLevel.(i, sl.value); ~rtRelease !? { ~rtRelease.([i]) } }) };   // mouse moved it: its fader lets go
	~rtDbText = 8.collect { StaticText().string_("off").align_(\center).fixedWidth_(80).font_(Font.default.size_(11)) };
	~rtGoBtns = 8.collect { |i| Button().states_([["GO " ++ (i + 1)], ["GO " ++ (i + 1), Color.white, Color(0.2, 0.45, 0.75)]]).fixedWidth_(70)
		.enabled_(ok[i]).action_({ |b| ~rtGoToggle.(i); b.value = ~rtGo[i].asInteger }) };
	~rtSlowBtns = 8.collect { |i| Button().states_([["1929 speed"], ["½× oct down", Color.white, Color(0.55, 0.35, 0.15)]]).fixedWidth_(80)
		.enabled_(~rtBufsHalf[i].notNil).value_(~rtSlow[i].asInteger).action_({ |b| ~rtSetSlow.(i, b.value == 1); b.value = ~rtSlow[i].asInteger }) };
	~rtNb = { |key, lo, hi, step, dec| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec).value_(~rtTP[key]).fixedWidth_(52)
		.action_({ |b| ~rtTP[key] = b.value }) };
	~rtAmbiBox = CheckBox().string_("AMBI (render k at its own direction, clockwise from front)").value_(~rtAmbi).action_({ |c| ~rtSetAmbi.(c.value); c.value = ~rtAmbi });
	~rtTrig = VLayout(
		HLayout(~rtAmbiBox, nil, StaticText().string_("offset range s"), ~rtNb.(\offRange, 0, 2, 0.05, 2),
			StaticText().string_("fade in s"), ~rtNb.(\fadeIn, 0, 20, 0.1, 1), StaticText().string_("fade out s"), ~rtNb.(\fadeOut, 0, 30, 0.1, 1),
			StaticText().string_("GO level"), ~rtNb.(\goLevel, 0, 1, 0.05, 2)),
		HLayout(Button().states_([["SWIRL"]]).fixedWidth_(80).action_({ ~rtSwirl.() }),
			StaticText().string_("size"), ~rtNb.(\swirlN, 1, 8, 1, 0), StaticText().string_("step ms"), ~rtNb.(\step, 0, 2000, 10, 0),
			PopUpMenu().items_(["clockwise", "counter-clockwise"]).value_(if (~rtTP[\dir] > 0) { 0 } { 1 }).fixedWidth_(140).action_({ |m| ~rtTP[\dir] = if (m.value == 0) { 1 } { -1 } }),
			StaticText().string_("start"), PopUpMenu().items_(["random"] ++ (1..8).collect { |k| "render " ++ k }).value_(~rtTP[\start] + 1).fixedWidth_(100)
				.action_({ |m| ~rtTP[\start] = m.value - 1 }),
			Button().states_([["ALL (8-swirl)"]]).action_({ ~rtSwirl.(8) }), Button().states_([["SCATTER"]]).action_({ ~rtScatter.() }),
			Button().states_([["RE-ROLL offsets"]]).action_({ ~rtReroll.() }), Button().states_([["HUSH"]]).action_({ ~rtHush.() }), nil),
		HLayout(StaticText().string_("OCTAVE DOWN: the buttons under GO switch each render to its version toward the half-speed Rite (own playhead, 5:00 loop)"),
			Button().states_([["rescan ½× renders"]]).action_({ ~rtLoadHalf.() }), nil));
	~rtCols = 8.collect { |i|
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~rtFaders[i], nil).margins_(0),
			~rtDbText[i], ~rtGoBtns[i], ~rtSlowBtns[i],
			StaticText().string_(if (ok[i]) { ~rtPick[i][0] } { "MISSING" }).align_(\center).fixedWidth_(80)
				.font_(Font.default.size_(11)).stringColor_(if (ok[i]) { Color.black } { Color.red })
		).spacing_(3) };
	~rtMasterSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(~rtMaster)
		.action_({ |sl| ~rtMaster = sl.value; ~rtSynth !? { ~rtSynth.set(\amp, ~rtMaster) } });
	~rtPlayBtn = Button().states_([["PLAY"], ["STOP", Color.white, Color.green(0.5)]]).fixedWidth_(80)
		.action_({ |b| if (b.value == 1) { ~rtPlay.value } { ~rtStop.value } });
	~rtPosSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0).action_({ |sl| ~rtSeek.(sl.value * ~rtDur) });
	~rtPosText = StaticText().string_("0:00 / " ++ (~rtDur / 60).floor.asInteger ++ ":" ++ (~rtDur % 60).round.asInteger.asString.padLeft(2, "0")).fixedWidth_(90);
	~rtMidiText = StaticText().string_("").fixedHeight_(16);
	~rtWin.layout = VLayout(
		StaticText().string_("Rite of Spring (1929, first 2:30) -- eight concatenator renders, looping together").font_(Font.default.boldVariant),
		HLayout(*(~rtCols ++ [nil])),
		~rtTrig,
		HLayout(StaticText().string_("master").fixedWidth_(60), ~rtMasterSl),
		HLayout(~rtPlayBtn, ~rtPosSl, ~rtPosText),
		~rtMidiText, nil
	);
	~rtDirty = true; ~rtFaderSync = false;
	~rtRout = Routine { var n = 0; loop {
		if (~rtFaderSync) { ~rtFaderSync = false; 8.do { |i| ~rtFaders[i].value = ~rtLevels[i] } };
		if (~rtDirty) { ~rtDirty = false; 8.do { |i| var a = ~rtLevels[i].squared;
			~rtDbText[i].string = if (a < 0.0001) { "off" } { a.ampdb.round(0.1).asString ++ " dB" }
				++ if (a >= 0.0001 and: { ~rtOffs[i] > 0.0005 }) { "  +" ++ (~rtOffs[i] * 1000).round.asInteger ++ "ms" } { "" };
			~rtGoBtns[i].value = ~rtGo[i].asInteger } };
		if (~rtPlaying) { var p = ~rtPos;
			~rtPosText.string = (p / 60).floor.asInteger.asString ++ ":" ++ (p % 60).floor.asInteger.asString.padLeft(2, "0")
				++ " / " ++ (~rtDur / 60).floor.asInteger ++ ":" ++ (~rtDur % 60).round.asInteger.asString.padLeft(2, "0");
			if (n % 4 == 0) { ~rtPosSl.value = p / ~rtDur.max(1) } };   // position bar steps once a second
		n = n + 1; 0.25.wait } }.play(AppClock);

	// ---- nanoKONTROL2 (shared ownership; same soft takeover + jitter filter as breath36) ----
	~mkOwners = (~mkOwners ? []).add(\rite).asSet.asArray; ~mkOwner = \rite;
	~rtLast = IdentityDictionary.new; ~rtCaught = IdentityDictionary.new;
	~rtHeld = IdentityDictionary.new; ~rtWay = IdentityDictionary.new; ~rtPend = IdentityDictionary.new;
	~rtRelease = { |ccs| ccs.do { |c| ~rtCaught[c] = false; ~rtLast[c] = nil } };
	~rtCatch = { |cc, v, cur| var last = ~rtLast[cc], caught = ~rtCaught[cc] ? false;
		if (caught.not) { if (((v - cur).abs < 0.03) or: { last.notNil and: { (last - cur).sign != (v - cur).sign } }) { caught = true } };
		~rtLast[cc] = v; ~rtCaught[cc] = caught; caught };
	// a fader moves freely the way it is going; turning back needs two messages in a row >= 4 steps back
	~rtSteady = { |cc, val| var held = ~rtHeld[cc], d, go = false;
		if (held.isNil) { ~rtHeld[cc] = val; go = true } {
			d = val - held;
			case
				{ d == 0 } { ~rtPend[cc] = nil }
				{ d.sign == (~rtWay[cc] ? 0) } { go = true; ~rtPend[cc] = nil }
				{ d.abs >= 4 and: { ~rtPend[cc] == d.sign } } { go = true; ~rtPend[cc] = nil }
				{ d.abs >= 4 } { ~rtPend[cc] = d.sign }
				{ ~rtPend[cc] = nil };
			if (go) { ~rtHeld[cc] = val; ~rtWay[cc] = d.sign } };
		go };
	MIDIClient.init(verbose: false); MIDIIn.connectAll(verbose: false);
	~rtMidiText.string = if (MIDIClient.sources.any { |e| e.device.contains("nanoKONTROL") })
		{ "nanoKONTROL2: sliders 1-8 = the eight levels, S 1-8 = GO, knob 5 master, PLAY / STOP" } { "nanoKONTROL2: not found (plug in, re-evaluate)" };
	MIDIdef.cc(\rtcc, { |val, cc, chan| var v = val / 127;
		{ if (~mkOwner == \rite) {
			if (cc < 8) { if (~rtSteady.(cc, val) and: { ~rtCatch.(cc, v, ~rtLevels[cc]) }) { ~rtSetLevel.(cc, v); ~rtFaderSync = true } };
			if (cc == 20) { if (~rtSteady.(cc, val) and: { ~rtCatch.(cc, v, ~rtMaster) }) { ~rtMasterSl.action.value(Ref(v)); ~uiLater.(~rtMasterSl, { ~rtMasterSl.value = v }) } };
			if (val > 0) { if (cc == 41) { ~rtPlay.value }; if (cc == 42) { ~rtStop.value };
				if ((cc >= 32) and: { cc <= 39 }) { ~rtGoToggle.(cc - 32) } };   // S buttons = GO 1-8
		} }.defer }).permanent_(true);
	MIDIdef.noteOn(\rtnote, { |vel, note| { if (~mkOwner == \rite) { if (note == 41) { ~rtPlay.value }; if (note == 42) { ~rtStop.value };
		if ((note >= 32) and: { note <= 39 }) { ~rtGoToggle.(note - 32) } } }.defer }).permanent_(true);

	~rtWin.onClose = { ~rtRout.stop; ~rtDummy4 !? { ~rtDummy4.free }; ~rtDummy4 = nil; ~rtBufsHalf !? { ~rtBufsHalf.do { |b| b !? { b.free } } }; ~rtBufsHalf = nil; ~rtSynth !? { ~rtSynth.free }; ~rtSynth = nil; ~rtLimiter !? { ~rtLimiter.free; ~rtLimiter = nil };
		~rtBufs !? { ~rtBufs.do { |b| b !? { b.free } } }; ~rtBufs = nil;
		MIDIdef(\rtcc).free; MIDIdef(\rtnote).free; OSCdef(\rtPos).free; ~mkOwners !? { ~mkOwners.remove(\rite); ~mkOwner = ~mkOwners.first } };
	("RITE_LIVE_READY (" ++ ok.count(_ == true) ++ "/8 renders, " ++ ~rtDur.round(0.1) ++ " s)").postln;
};
)
