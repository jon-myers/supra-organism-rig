/*
tornado_engine.scd -- TORNADO (tab 12, key =): the ending, generated LIVE and steered by hand (2026-10-02, Jon: "get this into a
supercollider patch, driven by the live signals, and built in such a way so I can control the ending" ... "I'm not sure how long
it is supposed to take ... I'm going to need to be able to really push it to the limit if the piece is about to end, and then do
like a hard cut").

The same rules as the offline render (rig/sharp/accents/render_tornado4.py, "3c"), but nothing is on a fixed clock: BUILD (0..1)
is where the piece is, and every layer reads it.
  BUILD     the fader. AUTO creeps it forward (minutes from 0 to the climax); CLIMAX glides it to 1 over N s; HOLD freezes it;
            you can always grab it. At 1 everything runs at its climax rate for as long as you stay there.
  MASTER    fader + FADE OUT / FADE IN over N s (FADE OUT also stops new events once it is silent); HARD CUT: silent within ~5 ms,
            every voice freed, all layers stopped. START begins again from the current BUILD.
LAYERS (x = BUILD)
  lines     the For Ann line renders (5 materials joining at x 0 / .12 / .25 / .38 / .5), an entry every 1.5 s -> 0.12 s, the lines
            climbing up to 3x faster, each at its own golden-angle direction                                       [clock]
  percussion  every sensor JOLT (|change of AC| over that sensor's 99th percentile today) -> klatter from its dancer's region (rolls
            as x grows), thuds (x > .15), booms (x > .3), high harmonium stabs (x > .6)                              [DANCERS]
            + a swarm whose density follows the ensemble's motion (0.2 -> 40 / s)                                    [DANCERS x clock]
            + a kick heartbeat from x .25 (1.5 s -> 0.07 s) + Articulation phrases from x .15                       [clock]
  harmonium swells (higher versions after x .45), a ladder of growing chords F2 -> A6 from x .3, a high cluster above x .9 [clock]
  birds     Macaulay Library calls from x .1, ~1 per 20 s -> ~3 per s                                                 [clock]
  snatches  a few whole 10-s Rite / Phantom Pain reconstruct stretches, 10 dB under the lines                        [clock]
Out: one B-format bus -> the AMBI tab (quad + binaural); no AMBI tab = a stereo fold-down on outs 1-2. Needs the FORCE tab on the
live OSC for the dancers. Display: everything redraws 4 times a second at most.
*/
(
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/tornado_engine.scd".standardizePath).pathOnly;
~tnRoot = here +/+ ".." +/+ "sharp" +/+ "accents";
~tnP = ~tnP ? (master: 0.0, fade: 8, autoMin: 4, climaxS: 20, sens: 1, lines: 0, perc: 0, harm: 0, birds: 0, snatch: 0, ambi: true);
~tnX = ~tnX ? 0; ~tnRun = false; ~tnAuto = false; ~tnHold = false; ~tnGlide = nil; ~tnLat = 0.05; ~tnAct = 0;
~tnStats = (entries: 0, hits: 0, events: 0); ~tnLoaded = false;
s = Server.default;
s.waitForBoot { fork {
	var man, rd, n = 0, total, loadList;
	// ---- tear down a previous evaluation ----
	{ ~tnWin !? { if (~tnWin.isClosed.not) { ~tnWin.onClose = nil; ~tnWin.close } } }.defer;
	~tnStop !? { ~tnStop.() }; ~tnJolt !? { ~tnJolt.free }; ~tnMasterSyn !? { ~tnMasterSyn.free }; ~tnGrp !? { ~tnGrp.free };
	~tnAllBufs !? { ~tnAllBufs.do(_.free) }; OSCdef(\tnHit).free; OSCdef(\tnAct).free; OSCdef(\tnLvl).free; MIDIdef(\tncc).free; MIDIdef(\tnnote).free;
	~tnBus !? { ~tnBus.free }; ~tnBus = Bus.audio(s, 4); ~tnDummy4 !? { ~tnDummy4.free }; ~tnDummy4 = Bus.audio(s, 4);
	~tnZero !? { ~tnZero.free }; ~tnZero = Bus.control(s, 14).setn(0 ! 14);

	man = File.readAllString(~tnRoot +/+ "live" +/+ "live.json").parseJSON;
	~tnGains = (); man["gains"].keysValuesDo { |k, v| ~tnGains[k.asSymbol] = v.asFloat };
	~tnThr = man["jolt_thr"].collect(_.asFloat); ~tnAct95 = man["act95"].asFloat;
	~tnSpeeds = man["speeds"].collect(_.asFloat);

	// ---- synths ----
	SynthDef(\tnMono, { |buf, amp = 1, az = 0, width = 0.8, dur = 0, att = 0.002, rel = 0.05, out = 0|
		var d = Select.kr(dur > 0, [BufDur.ir(buf), dur]);
		var env = EnvGen.kr(Env([0, 1, 1, 0], [att, (d - att - rel).max(0), rel]), doneAction: 2);
		var b = FoaPanB.ar(PlayBuf.ar(1, buf, BufRateScale.ir(buf), doneAction: 2) * env * amp, az, 0);
		Out.ar(out, [b[0], b[1] * width, b[2] * width, b[3] * width]) }).load(s);
	SynthDef(\tnStereo, { |buf, amp = 1, az = 0, spread = 0.52, width = 0.8, dur = 0, att = 0.002, rel = 0.05, out = 0|
		var d = Select.kr(dur > 0, [BufDur.ir(buf), dur]);
		var env = EnvGen.kr(Env([0, 1, 1, 0], [att, (d - att - rel).max(0), rel]), doneAction: 2);
		var x = PlayBuf.ar(2, buf, BufRateScale.ir(buf), doneAction: 2) * env * amp;
		var b = FoaPanB.ar(x[0], az + spread, 0) + FoaPanB.ar(x[1], az - spread, 0);
		Out.ar(out, [b[0], b[1] * width, b[2] * width, b[3] * width]) }).load(s);
	SynthDef(\tnMaster, { |in = 0, out = 0, abus = 0, ambi = 0, master = 1, mlag = 0.1, gate = 1|
		var b = In.ar(in, 4) * VarLag.kr(master, mlag, warp: \sin) * Lag.kr(gate, 0.004);
		SendPeakRMS.kr(b[0], 4, 3, '/tnLvl');
		Out.ar(abus, b * ambi.lag(0.05));
		Out.ar(out, [b[0] * 2.sqrt + b[2], b[0] * 2.sqrt - b[2]] * 0.5 * (1 - ambi).lag(0.05)) }).load(s);
	// JOLTS: a jump of a sensor's AC between frames, over that sensor's 99th percentile today (x sens); at most one per 0.12 s
	SynthDef(\tnJolt, { |fbus = 0, sens = 1, act95 = 0.56|
		var ac = In.kr(fbus + 7, 7), thr = \thr.kr(0.08 ! 7);
		7.do { |k| var j = (ac[k] - Delay1.kr(ac[k])).abs / thr[k] * sens; SendReply.kr(Trig1.kr(j > 1, 0.12), '/tnHit', [k, j], k) };
		SendReply.kr(Impulse.kr(10), '/tnAct', [(Lag.kr(ac.keep(6).squared.sum / 6, 1.0).sqrt / act95)]) }).load(s);
	s.sync;

	// ---- GUI ----
	{
		var nb = { |key, lo, hi, step, dec, w = 52| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec).value_(~tnP[key]).fixedWidth_(w).action_({ |b| ~tnP[key] = b.value }) };
		var big = Font.default.size_(15).boldVariant;
		~tnBoxes = ();
		~tnWin = if (~stHost.notNil) { ~stHost.(\tornado) } { Window("TORNADO -- the ending, live", Rect(80, 60, 1000, 600)).front };
		~uiPending = ~uiPending ? IdentityDictionary.new; ~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
		if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
			~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
		~tnInfo = StaticText().string_(if (~tnLoaded) { "ready" } { "loading sounds ..." });
		~tnRunBtn = Button().states_([["START", Color.black, Color.green(0.75)], ["STOP (let ring)", Color.white, Color.blue(0.5)]]).fixedSize_(Size(150, 46)).font_(big)
			.action_({ |b| if (b.value == 1) { ~tnStart.() } { ~tnStop.() } });
		~tnStartBtn = ~tnRunBtn;
		~tnCutBtn = Button().states_([["HARD CUT", Color.white, Color.red(0.75)]]).fixedSize_(Size(170, 46)).font_(big).action_({ ~tnHardCut.(); ~tnRunBtn.value = 0 });
		~tnBuild = Slider().orientation_(\horizontal).fixedHeight_(44).value_(~tnX).action_({ |sl| ~tnGlide = nil; ~tnX = sl.value });
		~tnBuildTxt = StaticText().string_("BUILD " ++ (~tnX * 100).round ++ " %").fixedWidth_(110).font_(big);
		~tnAutoBox = CheckBox().string_("AUTO: reach the climax in").action_({ |c| ~tnAuto = c.value });
		~tnHoldBtn = Button().states_([["HOLD", Color.black, Color.grey(0.85)], ["HOLDING", Color.white, Color.new(0.7, 0.45, 0)]]).fixedWidth_(110).action_({ |b| ~tnHold = b.value == 1; if (~tnHold) { ~tnGlide = nil } });
		~tnClimaxBtn = Button().states_([["CLIMAX in", Color.black, Color.new(1, 0.75, 0.3)]]).fixedWidth_(100).action_({ ~tnHold = false; ~tnHoldBtn.value = 0; ~tnGlideTo.(1, ~tnP[\climaxS]) });
		~tnMaster = Slider().orientation_(\horizontal).fixedHeight_(30).value_((~tnP[\master].dbamp / 2).sqrt.min(1)).action_({ |sl|
			var a = 2 * sl.value.squared; ~tnP[\master] = a.max(0.00001).ampdb; ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, a); ~uiLater.(\tnM, { ~tnMasterTxt.string = if (a < 0.0001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } }) });
		~tnMasterTxt = StaticText().string_(~tnP[\master].round(0.5).asString ++ " dB").fixedWidth_(64);
		~tnFadeOut = Button().states_([["FADE OUT", Color.white, Color.red(0.55)]]).fixedWidth_(90).action_({ ~tnFade.(0, ~tnP[\fade]) });
		~tnFadeIn = Button().states_([["FADE IN", Color.black, Color.green(0.8)]]).fixedWidth_(80).action_({ ~tnFade.(~tnMasterAmp.(), ~tnP[\fade]) });
		~tnAmbiBox = CheckBox().string_("AMBI").value_(~tnP[\ambi]).action_({ |c| ~tnSetAmbi.(c.value) });
		~tnStatus = StaticText().string_("").font_(Font.monospace(12));
		~tnWin.layout = VLayout(
			HLayout(~tnRunBtn, ~tnCutBtn, ~tnInfo, nil),
			HLayout(~tnBuildTxt, [~tnBuild, stretch: 1]),
			HLayout(~tnAutoBox, (~tnBoxes[\autoMin] = nb.(\autoMin, 0.2, 60, 0.5, 1)), StaticText().string_("min"), ~tnHoldBtn, ~tnClimaxBtn, (~tnBoxes[\climaxS] = nb.(\climaxS, 1, 300, 1, 0)), StaticText().string_("s"),
				Button().states_([["0 %"]]).fixedWidth_(46).action_({ ~tnGlide = nil; ~tnX = 0 }), Button().states_([["50 %"]]).fixedWidth_(50).action_({ ~tnGlide = nil; ~tnX = 0.5 }),
				Button().states_([["80 %"]]).fixedWidth_(50).action_({ ~tnGlide = nil; ~tnX = 0.8 }), nil),
			HLayout(StaticText().string_("MASTER"), [~tnMaster, stretch: 1], ~tnMasterTxt, StaticText().string_("fade s"), (~tnBoxes[\fade] = nb.(\fade, 0.1, 120, 0.5, 1)), ~tnFadeIn, ~tnFadeOut, ~tnAmbiBox),
			HLayout(StaticText().string_("levels dB:"), StaticText().string_("lines"), (~tnBoxes[\lines] = nb.(\lines, -40, 12, 1, 0)), StaticText().string_("percussion"), (~tnBoxes[\perc] = nb.(\perc, -40, 12, 1, 0)),
				StaticText().string_("harmonium"), (~tnBoxes[\harm] = nb.(\harm, -40, 12, 1, 0)), StaticText().string_("birds"), (~tnBoxes[\birds] = nb.(\birds, -40, 12, 1, 0)), StaticText().string_("snatches"), (~tnBoxes[\snatch] = nb.(\snatch, -40, 12, 1, 0)),
				StaticText().string_("jolt sens"), (~tnBoxes[\sens] = NumberBox().clipLo_(0.1).clipHi_(5).step_(0.1).decimals_(1).value_(~tnP[\sens]).fixedWidth_(46).action_({ |b| ~tnP[\sens] = b.value; ~tnJolt !? { ~tnJolt.set(\sens, b.value) } })), nil),
			~tnStatus,
			StaticText().string_("BUILD = where the ending is (0 = the start, 100 % = the climax). Stay at 100 % (or HOLD) as long as you like, then FADE OUT or HARD CUT. The dancers' jolts drive the percussion; needs the FORCE tab on the live OSC."),
			nil);
		~tnStatRout = Routine { var last = (entries: 0, hits: 0, events: 0); loop {
			var d = (entries: ~tnStats[\entries] - last[\entries], hits: ~tnStats[\hits] - last[\hits], events: ~tnStats[\events] - last[\events]);
			last = ~tnStats.copy;
			~uiLater.(\tnStat, {
				~tnBuild.value = ~tnX; ~tnBuildTxt.string = "BUILD " ++ (~tnX * 100).round.asInteger ++ " %";
				~tnStatus.string = "running " ++ ~tnRun ++ "   lines/s " ++ d[\entries] ++ "   jolts/s " ++ d[\hits] ++ "   events/s " ++ d[\events]
					++ "   voices " ++ s.numSynths ++ "   motion " ++ (~tnAct * 100).round.asInteger ++ " %   out peak " ++ ((~tnPeak ? 0).max(0.000001).ampdb.round(1)) ++ " dB   CPU " ++ s.avgCPU.round(1) ++ " %" });
			1.wait } }.play(AppClock);
		~tnWin.onClose = { ~tnStop.(); ~tnStatRout.stop; ~tnJolt !? { ~tnJolt.free }; ~tnMasterSyn !? { ~tnMasterSyn.free }; ~tnGrp !? { ~tnGrp.free }; ~tnGrp = nil;
			~tnAllBufs !? { ~tnAllBufs.do(_.free) }; ~tnAllBufs = nil; ~tnLoaded = false; OSCdef(\tnHit).free; OSCdef(\tnAct).free; OSCdef(\tnLvl).free;
			MIDIdef(\tncc).free; MIDIdef(\tnnote).free; ~mkOwners !? { ~mkOwners.remove(\tornado); if (~mkOwner == \tornado) { ~mkOwner = ~mkOwners.first } } };
	}.defer;
	// ---- buffers (about 1.3 GB, loaded in the background; START waits for it) ----
	rd = { |rel, ch| var b = Buffer.read(s, ~tnRoot +/+ rel); n = n + 1; ~tnAllBufs = ~tnAllBufs.add(b); if (n % 60 == 0) { s.sync; ~uiLater.(\tnLoad, { ~tnInfo !? { ~tnInfo.string = "loading " ++ n ++ " / " ++ total } }) }; b };
	~tnAllBufs = [];
	total = man["lines"].values.collect { |d| d.values.collect(_.size).sum }.sum + man["hits"].values.collect(_.size).sum + man["birds"].size
		+ man["harm_notes"].size + man["harm_swell"].size + man["harm_cluster"].size + man["harm_stab"].size + man["snatch"].size;
	~tnMats = ["voice", "breath", "fry", "harmonium", "mixed"];
	~tnLines = (); ~tnMats.do { |m| ~tnLines[m.asSymbol] = ~tnSpeeds.collect { |sp| (man["lines"][m][sp.asString] ? []).collect { |rel| rd.(rel) } } };
	~tnHits = (); man["hits"].keysValuesDo { |c, l| ~tnHits[c.asSymbol] = l.collect { |rel| rd.(rel) } };
	~tnBirds = man["birds"].collect { |rel| rd.(rel) };
	~tnNotes = man["harm_notes"].collect { |p| [p[0].asInteger, rd.(p[1])] }; ~tnTop = ~tnNotes.collect(_[0]).maxItem;
	~tnSwell = man["harm_swell"].collect { |rel| rd.(rel) }; ~tnCluster = man["harm_cluster"].collect { |rel| rd.(rel) };
	~tnStab = man["harm_stab"].collect { |rel| rd.(rel) }; ~tnSnatch = man["snatch"].collect { |p| [p[0].asSymbol, rd.(p[1])] };
	s.sync; ~tnLoaded = true; ("TORNADO: " ++ n ++ " buffers loaded").postln;
	~uiLater.(\tnLoad, { ~tnInfo !? { ~tnInfo.string = n.asString ++ " sounds loaded -- ready" } });

	// ---- the output: voices -> one B-format bus -> master (fades, hard cut) -> AMBI tab or stereo ----
	~tnGrp = Group.head(s);
	// BEFORE the AMBI tab's decoder group (at the tail): a writer after it is never heard (Group.isPlaying is false for an unwatched group, so no check)
	~tnMasterSyn = if (~ambiGrp.notNil) { Synth.before(~ambiGrp, \tnMaster, [\in, ~tnBus.index]) } { Synth.tail(s, \tnMaster, [\in, ~tnBus.index]) };
	~tnSetAmbi = { |on| var a = on and: { ~ambiBus.notNil }; ~tnP[\ambi] = on;
		~tnMasterSyn.set(\ambi, a.asInteger, \abus, if (a) { ~ambiBus.index } { ~tnDummy4.index });
		if (on and: { ~ambiBus.isNil }) { "TORNADO: AMBI needs the AMBI tab; playing a stereo fold-down".warn } };
	~tnSetAmbi.(~tnP[\ambi]);
	~tnMasterAmp = { ~tnP[\master].dbamp }; ~tnMasterSyn.set(\master, ~tnMasterAmp.());
	~tnJolt = Synth.head(s, \tnJolt, [\fbus, (~fhBus !? (_.index)) ? ~tnZero.index, \thr, ~tnThr, \sens, ~tnP[\sens], \act95, ~tnAct95]);

	// ---- helpers ----
	~tnCres = { |x| (-22 + (22 * (x ** 1.5))).dbamp };              // the layers' crescendo
	~tnCresL = { |x| (-20 + (20 * x)).dbamp };                         // the lines' crescendo (forann_additive)
	~tnLvl = { |k| ~tnP[k].dbamp };
	~tnPick = { |cats| var pool = cats.collect { |c| ~tnHits[c] ? [] }.flatten; pool.choose };
	~tnPlay = { |def, buf, amp, az, args|
		if (~tnRun and: { buf.notNil }) { ~tnStats[\events] = ~tnStats[\events] + 1;
			s.makeBundle(~tnLat, { Synth(def, [\buf, buf, \amp, amp, \az, az, \out, ~tnBus.index] ++ (args ? []), ~tnGrp) }) } };
	~tnExp = { |mean| mean * (1.0 - 1.0.rand).max(1e-9).log.neg };   // exponential wait (Poisson process)
	~tnPois = { |lam| var lim = exp(lam.neg), k = 0, p = 1.0; while { p = p * 1.0.rand; p > lim } { k = k + 1 }; k };
	~tnK = 0; ~tnGolden = 137.50776.degrad; ~tnCount = (voice: 0, breath: 0, fry: 0, harmonium: 0, mixed: 0);
	~tnStages = [0, 0.12, 0.25, 0.38, 0.5];

	// ---- layers: each a routine that reads ~tnX ----
	~tnLayers = (
		lines: { loop { var x = ~tnX, st = (~tnStages.count { |v| x >= v } - 1).max(0), pool = ~tnMats.keep(st + 1), newest = pool.last;
			var stLen = (~tnStages[st + 1] ? 1.0) - ~tnStages[st], m, spw, si, lst, b;
			m = if ((st > 0) and: { (x - ~tnStages[st]) < (0.6 * stLen) } and: { 0.5.coin }) { newest } { pool.choose };
			spw = 0.33 ** (x ** 1.6); si = ~tnSpeeds.collect { |v| (v - spw).abs }.minIndex;
			lst = ~tnLines[m.asSymbol][si]; b = lst.wrapAt(~tnCount[m.asSymbol]); ~tnCount[m.asSymbol] = ~tnCount[m.asSymbol] + 1;
			~tnPlay.(\tnMono, b, ~tnCresL.(x) * ~tnGains[\lines] * ~tnLvl.(\lines), (~tnK * ~tnGolden) % 2pi, [\width, 0.75]);
			~tnK = ~tnK + 1; ~tnStats[\entries] = ~tnStats[\entries] + 1;
			(1.5 * ((0.12 / 1.5) ** (x ** 1.6))).wait } },
		pulse: { loop { var x = ~tnX, y;
			if (x < 0.25) { 0.25.wait } {
				~tnPlay.(\tnMono, ~tnPick.([\kick, \art_boom]), 0.7 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand, [\width, 0.2]);
				y = (x - 0.25) / 0.75; (1.5 * ((0.07 / 1.5) ** (y ** 1.6)) * rrand(0.92, 1.08)).wait } } },
		phrases: { loop { var x = ~tnX;
			if (x < 0.15) { 0.5.wait } {
				~tnPlay.(\tnStereo, ~tnPick.([\art_phrase]), 0.45 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand);
				(30 * ((1.1 / 30) ** (((x - 0.15) / 0.85).max(0) ** 1.3)) * rrand(0.7, 1.3)).wait } } },
		swarm: { loop { var x = ~tnX;
			if ((0.35 + ~tnAct).min(1).coin) { ~tnPlay.(\tnMono, ~tnPick.([\klatter_hi, \klatter_mid, \boops, \art_klatter]), 0.3 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand) };
			~tnExp.(1.0 / (0.2 * (200 ** (x ** 1.7)))).max(0.004).min(10).wait } },
		swell: { loop { var x = ~tnX, hi, b;
			if (x < 0.12) { 0.5.wait } {
				hi = (((x - 0.45) / 0.55).max(0)).coin; b = if (hi) { ~tnSwell.copyRange(30, ~tnSwell.size - 1).choose } { ~tnSwell.keep(30).choose };
				~tnPlay.(\tnStereo, b, 0.8 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.7]);
				(18 * ((2 / 18) ** (((x - 0.12) / 0.88).max(0) ** 1.2)) * rrand(0.7, 1.3)).wait } } },
		ladder: { loop { var x = ~tnX, y, target, size, cand, len;
			if (x < 0.3) { 0.5.wait } {
				y = (x - 0.3) / 0.7; target = ~tnTop * (y ** 1.15); size = (1 + (5 * (y ** 1.4) + 1.0.rand).floor).min(6).asInteger;
				cand = ~tnNotes.select { |p| (p[0] >= (target - 9)) and: { p[0] <= (target + 1) } };
				if (cand.isEmpty) { cand = [~tnNotes.minItem { |p| (p[0] - target).abs }] };
				len = rrand(0.35, 1.2) * (1 - (0.6 * y));
				size.do { var p = cand.choose; ~tnPlay.(\tnStereo, p[1], 0.6 * ~tnCres.(x) / size.sqrt * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.4, \dur, len, \att, 0.01, \rel, 0.15]) };
				(1.2 * ((0.15 / 1.2) ** (y ** 1.3)) * rrand(0.85, 1.15)).wait } } },
		cluster: { loop { var x = ~tnX;
			if (x < 0.9) { 0.5.wait } {
				~tnPlay.(\tnStereo, ~tnCluster.choose, 0.9 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.8]);
				(2.5 * (1 - ((x - 0.9) / 0.1))).max(0.6).wait } } },
		birds: { loop { var x = ~tnX;
			if (x < 0.1) { 0.5.wait } {
				~tnPlay.(\tnMono, ~tnBirds.choose, 0.5 * ~tnCres.(x) * ~tnGains[\birds] * ~tnLvl.(\birds), 2pi.rand);
				~tnExp.(1.0 / (0.05 * (60 ** (((x - 0.1) / 0.9).max(0) ** 1.4)))).max(0.02).min(60).wait } } },
		snatch: { var j = 0; loop { var x = ~tnX, kind, pool, b, linesRms, amp;
			if (x < 0.1) { 0.5.wait } {
				kind = if (j.odd) { \pp } { [\rite_open, \rite_open, \rite_open, \rite_mid].choose };
				pool = ~tnSnatch.select { |p| p[0] == kind }; b = (pool.choose ? ~tnSnatch.choose)[1];
				// 10 dB under the lines at this moment: ~ (line level) x sqrt(lines sounding)
				linesRms = ~tnCresL.(x) * ~tnGains[\lines] * ((43.7 * (0.33 ** (x ** 1.6))) / (1.5 * ((0.12 / 1.5) ** (x ** 1.6)))).sqrt;
				~tnPlay.(\tnStereo, b, linesRms * -10.dbamp * ~tnLvl.(\snatch), 2pi.rand, [\spread, 0.6]);
				j = j + 1; (10 + rrand(14, 24)).wait } } }
	);
	// the dancers: every jolt
	OSCdef(\tnHit, { |msg| var k = msg[3].asInteger, j = msg[4], x = ~tnX, az, v, pc = ~tnGains[\perc] * ~tnLvl.(\perc);
		if (~tnRun) { ~tnStats[\hits] = ~tnStats[\hits] + 1;
			az = if (k < 6) { (k * 60 + rrand(-15, 15)).degrad } { 2pi.rand }; v = (0.45 + (0.25 * j)).min(1);
			if ((0.15 + (0.85 * x)).coin) { (1 + ~tnPois.(7 * (x ** 2.2))).min(12).do { |r|
				var b = ~tnPick.([\klatter_hi, \klatter_mid, \art_klatter, \boops]), dt = r * rrand(0.018, 0.055);
				if (~tnRun and: { b.notNil }) { s.makeBundle(~tnLat + dt, { Synth(\tnMono, [\buf, b, \amp, 0.5 * v * ~tnCres.(x) * (0.85 ** r) * pc, \az, az + rrand(-0.2, 0.2), \out, ~tnBus.index], ~tnGrp) }) } } };
			if ((x >= 0.15) and: { j > 1.3 } and: { 0.6.coin }) { ~tnPlay.(\tnMono, ~tnPick.([\thud, \art_thud, \fry]), 0.6 * v * ~tnCres.(x) * pc, az) };
			if ((x >= 0.3) and: { (j > 1.4) or: { k == 6 } } and: { (0.35 + (0.65 * x)).coin }) { ~tnPlay.(\tnMono, ~tnPick.([\art_boom, \art_boom, \kick]), 0.8 * v * ~tnCres.(x) * pc, az, [\width, 0.3]) };
			if ((x >= 0.6) and: { j > 2.2 } and: { 0.5.coin }) {
				~tnPlay.(\tnStereo, if (x.coin) { ~tnStab.copyRange(20, ~tnStab.size - 1).choose } { ~tnStab.keep(20).choose }, 1.1 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), az) } } }, '/tnHit', s.addr);
	OSCdef(\tnAct, { |msg| ~tnAct = msg[3] }, '/tnAct', s.addr);
	OSCdef(\tnLvl, { |msg| ~tnPeak = msg[3] }, '/tnLvl', s.addr);

	// ---- transport ----
	~tnRouts = ();
	~tnStart = { if (~tnLoaded) {
		~tnStop.(); ~tnRun = true; ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, ~tnMasterAmp.());
		~tnJolt.set(\fbus, (~fhBus !? (_.index)) ? ~tnZero.index);
		~tnLayers.keysValuesDo { |k, f| ~tnRouts[k] = Routine(f).play(SystemClock) };
		~tnClock = Routine { var last = Main.elapsedTime; loop { var now = Main.elapsedTime, dt = now - last; last = now;
			if (~tnGlide.notNil) { var g = ~tnGlide; ~tnX = (~tnX + (dt * g[\rate])).clip(0, 1); if (((g[\rate] > 0) and: { ~tnX >= g[\to] }) or: { (g[\rate] < 0) and: { ~tnX <= g[\to] } }) { ~tnX = g[\to]; ~tnGlide = nil } } {
				if (~tnAuto and: { ~tnHold.not }) { ~tnX = (~tnX + (dt / (~tnP[\autoMin] * 60).max(1))).min(1) } };
			0.05.wait } }.play(SystemClock);
		"TORNADO: running from BUILD " ++ (~tnX * 100).round ++ " %".postln } { "TORNADO: still loading".warn } };
	~tnStop = { ~tnRouts !? { ~tnRouts.do(_.stop) }; ~tnRouts = (); ~tnClock !? { ~tnClock.stop }; ~tnClock = nil; ~tnRun = false };
	~tnHardCut = { ~tnMasterSyn !? { ~tnMasterSyn.set(\gate, 0) }; ~tnStop.(); ~tnFadeRout !? { ~tnFadeRout.stop };
		SystemClock.sched(0.06, { ~tnGrp !? { ~tnGrp.freeAll }; nil }); "TORNADO: HARD CUT".postln };
	~tnFade = { |toAmp, secs| ~tnMasterSyn.set(\gate, 1, \mlag, secs, \master, toAmp); ~tnFadeRout !? { ~tnFadeRout.stop };
		if (toAmp <= 0) { ~tnFadeRout = Routine { (secs + 0.2).wait; ~tnStop.(); ~tnGrp.freeAll; { ~tnRunBtn !? { ~tnRunBtn.value = 0 } }.defer }.play(SystemClock) } };
	~tnGlideTo = { |to, secs| ~tnGlide = (to: to, rate: (to - ~tnX) / secs.max(0.05)) };

	// ---- nanoKONTROL2 (2026-10-02): shared like the other tabs (TRACK < > passes it on; selecting this tab takes it) ----
	//   fader 1 BUILD   fader 2 MASTER   faders 3-7 levels (lines, percussion, harmonium, birds, snatches: -36 .. +6 dB)   fader 8 jolt sens
	//   knob 1 AUTO minutes (0.5-15)   knob 2 CLIMAX glide s (2-90)   knob 3 fade s (0.5-30)
	//   PLAY start   STOP stop (let ring)   REC HARD CUT   CYCLE hold   >> climax   << auto on/off   SET fade out   MARKER < fade in
	~mkOwners = (~mkOwners ? []).add(\tornado).asSet.asArray;
	~tnLast = IdentityDictionary.new; ~tnCaught = IdentityDictionary.new; ~tnHeld = IdentityDictionary.new; ~tnWay = IdentityDictionary.new; ~tnPend = IdentityDictionary.new;
	~tnCatch = { |cc, v, cur| var last = ~tnLast[cc], caught = ~tnCaught[cc] ? false;   // soft takeover (as breath36 / rite)
		if (caught.not) { if (((v - cur).abs < 0.03) or: { last.notNil and: { (last - cur).sign != (v - cur).sign } }) { caught = true } };
		~tnLast[cc] = v; ~tnCaught[cc] = caught; caught };
	~tnSteady = { |cc, val| var held = ~tnHeld[cc], d, go = false;               // jitter filter (as breath36 / rite)
		if (held.isNil) { ~tnHeld[cc] = val; go = true } { d = val - held;
			case { d == 0 } { ~tnPend[cc] = nil } { d.sign == (~tnWay[cc] ? 0) } { go = true; ~tnPend[cc] = nil }
				{ d.abs >= 4 and: { ~tnPend[cc] == d.sign } } { go = true; ~tnPend[cc] = nil } { d.abs >= 4 } { ~tnPend[cc] = d.sign } { ~tnPend[cc] = nil };
			if (go) { ~tnHeld[cc] = val; ~tnWay[cc] = d.sign } }; go };
	~tnDbOf = { |v| -36 + (42 * v) }; ~tnVOfDb = { |db| ((db + 36) / 42).clip(0, 1) };
	~tnSetBox = { |key, val| ~tnP[key] = val; ~uiLater.(("tnBox" ++ key).asSymbol, { ~tnBoxes[key] !? { |b| b.value = val } }) };
	~tnButton = { |num| case
		{ num == 41 } { { ~tnRunBtn.value = 1 }.defer; ~tnStart.() }
		{ num == 42 } { { ~tnRunBtn.value = 0 }.defer; ~tnStop.() }
		{ num == 45 } { ~tnHardCut.(); { ~tnRunBtn.value = 0 }.defer }
		{ num == 46 } { ~tnHold = ~tnHold.not; if (~tnHold) { ~tnGlide = nil }; { ~tnHoldBtn.value = ~tnHold.asInteger }.defer }
		{ num == 44 } { ~tnHold = false; { ~tnHoldBtn.value = 0 }.defer; ~tnGlideTo.(1, ~tnP[\climaxS]) }
		{ num == 43 } { ~tnAuto = ~tnAuto.not; { ~tnAutoBox.value = ~tnAuto }.defer }
		{ num == 60 } { ~tnFade.(0, ~tnP[\fade]) }
		{ num == 61 } { ~tnFade.(~tnMasterAmp.(), ~tnP[\fade]) } };
	MIDIClient.init(verbose: false); MIDIIn.connectAll(verbose: false);
	MIDIdef.cc(\tncc, { |val, cc| var v = val / 127;
		if (~mkOwner == \tornado) {
			case
			{ cc == 0 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, ~tnX) }) { ~tnGlide = nil; ~tnX = v } }
			{ cc == 1 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, (~tnP[\master].dbamp / 2).sqrt.min(1)) }) {
				var a = 2 * v.squared; ~tnP[\master] = a.max(0.00001).ampdb; ~tnMasterSyn !? { ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, a) };
				~uiLater.(\tnKM, { ~tnMaster.value = v; ~tnMasterTxt.string = if (a < 0.0001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } }) } }
			{ (cc >= 2) and: { cc <= 6 } } { var key = [\lines, \perc, \harm, \birds, \snatch][cc - 2];
				if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, ~tnVOfDb.(~tnP[key])) }) { ~tnSetBox.(key, ~tnDbOf.(v).round(0.5)) } }
			{ cc == 7 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, (~tnP[\sens] / 0.25).log / 12.log) }) { var sv = 0.25 * (12 ** v); ~tnSetBox.(\sens, sv.round(0.05)); ~tnJolt !? { ~tnJolt.set(\sens, sv) } } }
			{ cc == 16 } { ~tnSetBox.(\autoMin, (0.5 * (30 ** v)).round(0.1)) }
			{ cc == 17 } { ~tnSetBox.(\climaxS, (2 * (45 ** v)).round(1)) }
			{ cc == 18 } { ~tnSetBox.(\fade, (0.5 * (60 ** v)).round(0.1)) }
			{ (val > 0) and: { [41, 42, 43, 44, 45, 46, 60, 61].includes(cc) } } { ~tnButton.(cc) } } }).permanent_(true);
	MIDIdef.noteOn(\tnnote, { |vel, note| if (~mkOwner == \tornado) { ~tnButton.(note) } }).permanent_(true);
	"TORNADO_ENGINE_READY".postln;
} };
)
