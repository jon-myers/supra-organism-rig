/*
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
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~wlRoot = here +/+ ".." +/+ "wall_of_sound";
~wlOutBus = ~wlOutBus ? 0;
~wlP = (dyads: 0, voices: 0, chords: 0, master: 0.7, trim: [0, 0, 0], step: 0.25, relTime: 4);
~wlLevelsDb = [0, 1, 3];   // per layer, relative to the median dyad (bell.py VOICE_REL_DB / CHORD_REL_DB)
s = Server.default;
s.options.numBuffers = s.options.numBuffers.max(4096); s.options.memSize = s.options.memSize.max(2.pow(18));
s.waitForBoot {
	var assets = File.readAllString(~wlRoot +/+ "analysis" +/+ "live_assets.json").parseJSON, c = assets["consts"];
	var entryGap = c["entry_gap"].collect(_.asFloat), tailFrac = c["tail_frac"].collect(_.asFloat), dyadGain = c["dyad_gain_db"].collect(_.asFloat);
	var irPath = ~wlRoot +/+ "analysis" +/+ "room_ir_44k.wav", ir, irFrames, fftSize = 2048, irSpec;
	var voiceIds = assets["voices"].keys.asArray.sort, chordIds = assets["chords"].keys.asArray.sort;

	// ---- buffers ----
	~wlDyadBufs = assets["dyads"].collect { |d| Buffer.read(s, d["file"]) };
	~wlVoiceBufs = voiceIds.collect { |v| Buffer.read(s, assets["voices"][v]["file"]) };
	~wlChordBufs = chordIds.collect { |k| Buffer.read(s, assets["chords"][k]["file"]) };
	ir = Buffer.read(s, irPath); s.sync;
	irFrames = ir.numFrames; irSpec = 2.collect { |ch| var mono = Buffer.alloc(s, irFrames, 1), spec = Buffer.alloc(s, PartConv.calcBufSize(fftSize, ir)); [mono, spec, ch] };
	irSpec.do { |t| var mono = t[0], spec = t[1], ch = t[2]; ir.loadToFloatArray(action: { |arr| mono.loadCollection(arr.clump(2).collect(_[ch]), action: { spec.preparePartConv(mono, fftSize) }) }) };
	s.sync; 0.5.wait;
	("wall_live: " ++ ~wlDyadBufs.size ++ " dyads, " ++ ~wlVoiceBufs.size ++ " voices, " ++ ~wlChordBufs.size ++ " chords, IR " ++ (irFrames / 44100).round(0.01) ++ " s").postln;

	// ---- synths ----
	~wlDry = Bus.audio(s, 2); ~wlSend = Bus.audio(s, 2);
	SynthDef(\wlDyad, { |gate = 1, rel = 4, buf, dur = 30, apex = 0.5, gain = 1, pos = 0, width = 0.5, amp = 1, out = 0|
		var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), doneAction: 2);
		var env = EnvGen.kr(Env([0, 1, 0], [apex * dur, (1 - apex) * dur], \sin), doneAction: 2);
		var mono = sig.sum * 0.7071, w = width.clip(0, 1);
		var st = Balance2.ar(sig[0], sig[1], pos);   // keep the stem's own stereo, lean it
		var cut = EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2);   // release on demand (slider lowered)
		Out.ar(out, (st * w + (Pan2.ar(mono, pos) * (1 - w))) * env * cut * gain * amp);
	}).add;
	SynthDef(\wlVoice, { |gate = 1, rel = 4, buf, start = 0, dur = 10, fade = 0.3, gain = 1, pos = 0, amp = 1, dry = 0, send = 0, sendAmt = 0.4|
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), 1, start, 0);
		var env = EnvGen.kr(Env.linen(fade, (dur - (2 * fade)).max(0.05), fade, 1, \sine), doneAction: 2);
		sig = BHiPass.ar(BHiPass.ar(sig, 80), 80);
		sig = BLowShelf.ar(sig, 200, 0.707, -4); sig = BHiShelf.ar(sig, 7000, 0.707, -5);
		sig = sig * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp;
		Out.ar(dry, Pan2.ar(sig, pos)); Out.ar(send, Pan2.ar(sig * sendAmt, pos * 0.5));
	}).add;
	SynthDef(\wlChord, { |gate = 1, rel = 4, buf, start = 0, dur = 300, fadeIn = 45, fadeOut = 45, gain = 1, pos = 0, width = 0.5, amp = 1, out = 0|
		var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), 1, start, 0);
		var env = EnvGen.kr(Env.linen(fadeIn, (dur - fadeIn - fadeOut).max(1), fadeOut, 1, \sine), doneAction: 2);
		var mono = sig.sum * 0.7071, w = width.clip(0, 1);
		Out.ar(out, (Balance2.ar(sig[0], sig[1], pos) * w + (Pan2.ar(mono, pos) * (1 - w))) * env * EnvGen.kr(Env.asr(0, 1, rel, -3), gate, doneAction: 2) * gain * amp);
	}).add;
	SynthDef(\wlRoom, { |dry, send, specL, specR, wet = 0.4, out = 0|
		var d = In.ar(dry, 2), sIn = In.ar(send, 2);
		var w = [PartConv.ar(sIn[0], fftSize, specL), PartConv.ar(sIn[1], fftSize, specR)];
		Out.ar(out, d + (w * wet));
	}).add;
	s.sync;
	~wlRoom = Synth.tail(s, \wlRoom, [\dry, ~wlDry, \send, ~wlSend, \specL, irSpec[0][1], \specR, irSpec[1][1], \wet, (-8).dbamp / 0.4, \out, ~wlOutBus]);   // IR is unit-ENERGY (bell.py make_ir); send 0.4 x wet 0.4/... = -8 dB wet
	~wlGroup = Group.head(s);
	SynthDef(\wlLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add; s.sync;
	~wlLimiter !? { ~wlLimiter.free }; ~wlLimiter = Synth.after(~wlRoom, \wlLimit, [\out, ~wlOutBus]);   // safety net

	// ---- the engine: committed counts vs targets ----
	~wlEvents = [List.new, List.new, List.new];       // per layer: (end:, commit:, src:)
	~wlNextOk = [0, 0, 0]; ~wlCount = 0;
	~wlDyadFired = nil ! ~wlDyadBufs.size;
	~wlVoiceOrder = voiceIds.collect { |v| assets["voices"][v]["segments"].size.collect { |i| i }.scramble }; ~wlVoicePtr = 0 ! voiceIds.size;
	~wlLayerAmp = { |l| ~wlP.master * (~wlLevelsDb[l] + ~wlP.trim[l]).dbamp };
	~wlNow = { Main.elapsedTime };
	~wlCommitted = { |l| ~wlEvents[l].count { |e| e.commit > ~wlNow.() } };
	~wlBusy = { |l| ~wlEvents[l].select { |e| e.end > ~wlNow.() }.collect(_.src) };
	~wlLog = { |str| { ~wlLast !? { ~wlLast.string = str } }.defer };
	~wlFire = [
		{   // dyad: Tenney-style age^2 draw
			var w = ~wlDyadBufs.size.collect { |k| var age = if (~wlDyadFired[k].isNil) { 24 } { (~wlCount - ~wlDyadFired[k]).clip(1, 24) }; age.squared };
			var k = (0..(~wlDyadBufs.size - 1)).wchoose(w.normalizeSum), d = assets["dyads"][k], dur = d["dur"].asFloat;
			var gainDb = rrand(dyadGain[0], dyadGain[1]) + d["gain_db"].asFloat, pos = 1.0.rand2, width = rrand(0.3, 0.9), apex = 0.5.gauss(0.125).clip(0.25, 0.75);
			~wlLastSyn = Synth(\wlDyad, [\buf, ~wlDyadBufs[k], \dur, dur, \apex, apex, \gain, gainDb.dbamp, \pos, pos, \width, width, \amp, ~wlLayerAmp.(0), \out, ~wlOutBus], ~wlGroup);
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
				~wlLastSyn = Synth(\wlVoice, [\buf, ~wlVoiceBufs[i], \start, a * sr, \dur, dur, \gain, assets["voices"][v]["gain_db"].asFloat.dbamp, \pos, pos,
					\amp, ~wlLayerAmp.(1), \dry, ~wlDry, \send, ~wlSend], ~wlGroup);
				~wlLog.("voice " ++ v ++ "  " ++ a.round(0.1) ++ "-" ++ b.round(0.1) ++ " s");
				(dur: dur, src: i);
			};
		},
		{   // chord: one of the two, if not sounding
			var busy = ~wlBusy.(2), cands = chordIds.size.collect { |i| i }.reject { |i| busy.includes(i) };
			if (cands.isEmpty) { nil } {
				var i = cands.choose, k = chordIds[i], ch = assets["chords"][k], dur = ch["dur"].asFloat, sr = ~wlChordBufs[i].sampleRate;
				~wlLastSyn = Synth(\wlChord, [\buf, ~wlChordBufs[i], \start, ch["start_s"].asFloat * sr, \dur, dur, \fadeIn, ch["fade_in"].asFloat, \fadeOut, ch["fade_out"].asFloat,
					\gain, ch["gain_db"].asFloat.dbamp, \pos, ch["pan"].asFloat, \width, (ch["width"].asFloat / 90).clip(0, 1), \amp, ~wlLayerAmp.(2), \out, ~wlOutBus], ~wlGroup);
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
			~wlEvents[l] = ~wlEvents[l].reject { |e| e.end < now };
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
	~wlWin !? { if (~wlWin.isClosed.not) { ~wlWin.close } };
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
		.action_({ |nb| ~wlP.trim[l] = nb.value }) };
	~wlMasterSl = Slider().orientation_(\vertical).fixedWidth_(50).minHeight_(260).value_(ControlSpec(-40, 6).unmap(~wlP.master.ampdb))
		.action_({ |sl| ~wlP.master = if (sl.value <= 0.001) { 0 } { ControlSpec(-40, 6).map(sl.value).dbamp }; ~wlDirty = true });
	~wlMasterText = StaticText().align_(\center).string_("");
	~wlLast = StaticText().string_("").fixedHeight_(18);
	~wlRelBox = NumberBox().clipLo_(0.2).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~wlP[\relTime]).fixedWidth_(56).action_({ |nb| ~wlP[\relTime] = nb.value });
	~wlHushBtn = Button().states_([["HUSH  (targets to 0, let events end)"]]).action_({ ~wlHush.() });
	~wlCutBtn = Button().states_([["CUT  (stop everything now)", Color.white, Color.red(0.6)]]).action_({ ~wlCut.() });
	~wlMidiText = StaticText().string_("").fixedHeight_(16);
	~wlWin.layout = VLayout(
		StaticText().string_("density = how many events are sounding (bell.py's rule, live). Lowering never cuts.").fixedHeight_(18),
		HLayout(*(3.collect { |l| VLayout(StaticText().string_(~wlNames[l] ++ "  0-" ++ ~wlMax[l]).align_(\center).font_(Font.default.boldVariant),
			~wlText[l], HLayout(nil, ~wlSliders[l], nil).margins_(0), ~wlSub[l], HLayout(StaticText().string_("trim dB"), ~wlTrims[l])) }
			++ [VLayout(StaticText().string_("master").align_(\center).font_(Font.default.boldVariant), ~wlMasterText, HLayout(nil, ~wlMasterSl, nil).margins_(0), StaticText().string_(" "), StaticText().string_(" "))])),
		HLayout(StaticText().string_("fade-out when lowered (s)"), ~wlRelBox, nil), HLayout(~wlHushBtn, ~wlCutBtn), ~wlLast, ~wlMidiText
	);
	~wlDirty = true;
	~wlRout = Routine { loop {
		if (~wlDirty) { var tg = ~wlTargets.(); ~wlDirty = false;
			3.do { |l| ~wlText[l].string = tg[l].round(0.5).asString; ~wlSub[l].string = "sounding " ++ ~wlEvents[l].size ++ "  committed " ++ ~wlCommitted.(l) };
			~wlMasterText.string = if (~wlP.master <= 0.0001) { "-inf" } { ~wlP.master.ampdb.round(0.5).asString ++ " dB" } };
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
			(0..2).do { |l| if (cc == l) { if (~wlPick.(cc, v, ~wlTargets.()[l] / ~wlMax[l])) { ~wlSliders[l].valueAction = v } } };
			(16..18).do { |k, l| if (cc == k) { if (~wlPick.(cc, v, (~wlP.trim[l] + 24) / 36)) { ~wlTrims[l].valueAction = v * 36 - 24 } } };
			if (cc == 20) { if (~wlPick.(cc, v, ~wlMasterSl.value)) { ~wlMasterSl.valueAction = v } };
			if (cc == 42 and: { val > 0 }) { ~wlHush.() };
		  } }.defer }).permanent_(true);
	MIDIdef.noteOn(\wlnote, { |vel, note| { if (note == 58 or: { note == 59 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (note == 59) { 1 } { -1 });
		~wlMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } }.defer }).permanent_(true);

	~wlWin.onClose = { ~wlTick.stop; ~wlRout.stop; ~wlGroup.free; ~wlRoom.free; ~wlLimiter !? { ~wlLimiter.free; ~wlLimiter = nil }; ~wlDry.free; ~wlSend.free;
		MIDIdef(\wlcc).free; MIDIdef(\wlnote).free;
		(~wlDyadBufs ++ ~wlVoiceBufs ++ ~wlChordBufs ++ [ir] ++ irSpec.collect(_[0]) ++ irSpec.collect(_[1])).do(_.free);
		~mkOwners.remove(\wall); ~mkOwner = ~mkOwners.first };
	"WALL_LIVE_READY".postln;
};
)
