/*
rite_live.scd -- eight concatenator renders of the Rite of Spring (1929 Stravinsky recording, first 2:30), all
looping together sample-aligned; eight faders bring each one in. Every fader starts at 0 (silent).

The eight (2026-09-29): one per corpus, microtonal (mic-) wherever it exists, at whichever setting scored higher
in score_similarity.py (notes/scores/rite1929_*.csv); slot 8 is the densest, best-scoring render overall.
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
~rtDir = here +/+ ".." +/+ "concatenator-corpus" +/+ "out" +/+ "listen-rite1929";
~rtPick = ~rtPick ? [
	["everything",  "mic-everything__rite1929first150__part1000_pd0.50_t200_p10__norm.wav"],
	["harmonium",   "mic-harmonium__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["aeolian",     "mic-aeolian__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["voice+breath","mic-voicebreath__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["perc",        "mic-perc__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["fry",         "mic-fry__rite1929first150__part1000_pd0.50_t200_p5__norm.wav"],
	["whoosh",      "mic-whoosh__rite1929first150__part1000_pd0.95_t50_p5__norm.wav"],
	["dense (aug)", "aug-everything__rite1929first150__part1000_pd0.50_t200_p20__norm.wav"]
];
~rtOutBus = ~rtOutBus ? 0;
~rtLevels = 0 ! 8; ~rtMaster = 0.5;
s = Server.default;
s.options.numBuffers = s.options.numBuffers.max(4096);
s.waitForBoot {
	var ok;
	// ---- tear down a previous evaluation ----
	~rtWin !? { if (~rtWin.isClosed.not) { ~rtWin.onClose = nil; ~rtWin.close } };
	~rtRout !? { ~rtRout.stop };
	~rtSynth !? { ~rtSynth.free }; ~rtSynth = nil; ~rtLimiter !? { ~rtLimiter.free }; ~rtLimiter = nil;
	~rtBufs !? { ~rtBufs.do { |b| b !? { b.free } } }; ~rtBufs = nil;
	MIDIdef(\rtcc).free; MIDIdef(\rtnote).free; OSCdef(\rtPos).free;

	SynthDef(\rtMix, { |amp = 0.5, frames = 1, rate = 1, t_reset = 0, resetPos = 0, run = 0, out = 0|
		var bufs = \bufs.kr(0 ! 8), lv = \lv.kr(0 ! 8).lag(0.08);
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos);
		var seam = (ph.min(frames - ph) / (0.01 * SampleRate.ir)).clip(0, 1);   // 10 ms down, 10 ms up at the loop point
		var sig = 8.collect { |i| BufRd.ar(2, bufs[i], ph, 1, 4) * lv[i].squared }.sum;
		SendReply.kr(Impulse.kr(4), '/rtPos', A2K.kr(ph));
		Out.ar(out, sig * seam * amp.lag(0.05));
	}).add;
	SynthDef(\rtLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add;
	s.sync;

	ok = ~rtPick.collect { |p| File.exists(~rtDir +/+ p[1]) };
	~rtBufs = ~rtPick.collect { |p, i| if (ok[i]) { Buffer.read(s, ~rtDir +/+ p[1]) } };
	s.sync;
	~rtFrames = ~rtBufs.select(_.notNil).collect(_.numFrames).minItem ? 0;
	~rtSR = ~rtBufs.detect(_.notNil) !? (_.sampleRate) ? 44100; ~rtDur = ~rtFrames / ~rtSR;
	~rtLimiter = Synth.tail(s, \rtLimit, [\out, ~rtOutBus]);
	~rtSynth = Synth.before(~rtLimiter, \rtMix, [\bufs, ~rtBufs.collect { |b| b !? (_.bufnum) ? 0 },
		\lv, ~rtLevels, \amp, ~rtMaster, \frames, ~rtFrames.max(1), \rate, ~rtSR / s.sampleRate, \run, 0, \out, ~rtOutBus]);
	~rtPlaying = false; ~rtPos = 0;
	OSCdef(\rtPos, { |m| ~rtPos = m[3] / ~rtSR }, '/rtPos');

	~rtSetLevel = { |i, v| ~rtLevels[i] = v.clip(0, 1); ~rtSynth !? { ~rtSynth.seti(\lv, i, ~rtLevels[i]) }; ~rtDirty = true };
	~rtPlay = { ~rtPlaying = true; ~rtSynth !? { ~rtSynth.set(\run, 1) }; { ~rtPlayBtn.value = 1 }.defer };
	~rtStop = { ~rtPlaying = false; ~rtSynth !? { ~rtSynth.set(\run, 0) }; { ~rtPlayBtn.value = 0 }.defer };
	~rtSeek = { |secs| ~rtSynth !? { ~rtSynth.set(\resetPos, (secs.clip(0, ~rtDur) * ~rtSR).asInteger, \t_reset, 1) } };

	// ---- GUI ----
	~rtWin = if (~stHost.notNil) { ~stHost.(\rite) } { Window("rite of spring renders", Rect(80, 80, 820, 420)).front };
	~rtWin.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\rite).asSet.asArray; ~mkOwner = \rite;
		{ ~rtMidiText !? { ~rtMidiText.string = "nanoKONTROL2: this window (front)" } }.defer });
	~rtFaders = 8.collect { |i|
		Slider().orientation_(\vertical).minHeight_(180).fixedWidth_(46).value_(~rtLevels[i]).enabled_(ok[i])
			.action_({ |sl| ~rtSetLevel.(i, sl.value); ~rtRelease !? { ~rtRelease.([i]) } }) };   // mouse moved it: its fader lets go
	~rtDbText = 8.collect { StaticText().string_("off").align_(\center).fixedWidth_(80).font_(Font.default.size_(11)) };
	~rtCols = 8.collect { |i|
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~rtFaders[i], nil).margins_(0),
			~rtDbText[i],
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
		HLayout(StaticText().string_("master").fixedWidth_(60), ~rtMasterSl),
		HLayout(~rtPlayBtn, ~rtPosSl, ~rtPosText),
		~rtMidiText, nil
	);
	~rtDirty = true; ~rtFaderSync = false;
	~rtRout = Routine { var n = 0; loop {
		if (~rtFaderSync) { ~rtFaderSync = false; 8.do { |i| ~rtFaders[i].value = ~rtLevels[i] } };
		if (~rtDirty) { ~rtDirty = false; 8.do { |i| var a = ~rtLevels[i].squared;
			~rtDbText[i].string = if (a < 0.0001) { "off" } { a.ampdb.round(0.1).asString ++ " dB" } } };
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
		{ "nanoKONTROL2: sliders 1-8 = the eight levels, knob 5 master, PLAY / STOP" } { "nanoKONTROL2: not found (plug in, re-evaluate)" };
	MIDIdef.cc(\rtcc, { |val, cc, chan| var v = val / 127;
		{ if (~mkOwner == \rite) {
			if (cc < 8) { if (~rtSteady.(cc, val) and: { ~rtCatch.(cc, v, ~rtLevels[cc]) }) { ~rtSetLevel.(cc, v); ~rtFaderSync = true } };
			if (cc == 20) { if (~rtSteady.(cc, val) and: { ~rtCatch.(cc, v, ~rtMasterSl.value) }) { ~rtMasterSl.valueAction = v } };
			if (val > 0) { if (cc == 41) { ~rtPlay.value }; if (cc == 42) { ~rtStop.value } };
		} }.defer }).permanent_(true);
	MIDIdef.noteOn(\rtnote, { |vel, note| { if (~mkOwner == \rite) { if (note == 41) { ~rtPlay.value }; if (note == 42) { ~rtStop.value } } }.defer }).permanent_(true);

	~rtWin.onClose = { ~rtRout.stop; ~rtSynth !? { ~rtSynth.free }; ~rtSynth = nil; ~rtLimiter !? { ~rtLimiter.free; ~rtLimiter = nil };
		~rtBufs !? { ~rtBufs.do { |b| b !? { b.free } } }; ~rtBufs = nil;
		MIDIdef(\rtcc).free; MIDIdef(\rtnote).free; OSCdef(\rtPos).free; ~mkOwners !? { ~mkOwners.remove(\rite); ~mkOwner = ~mkOwners.first } };
	("RITE_LIVE_READY (" ++ ok.count(_ == true) ++ "/8 renders, " ++ ~rtDur.round(0.1) ++ " s)").postln;
};
)
