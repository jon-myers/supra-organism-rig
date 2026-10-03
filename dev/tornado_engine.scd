/*
tornado_engine.scd -- TORNADO (tab 12, key =): the ending, generated LIVE and steered by hand (2026-10-02, Jon: "get this into a
supercollider patch, driven by the live signals, and built in such a way so I can control the ending" ... "I'm not sure how long
it is supposed to take ... I'm going to need to be able to really push it to the limit if the piece is about to end, and then do
like a hard cut").

The same rules as the offline render (rig/sharp/accents/render_tornado4.py, "3c"), but nothing is on a fixed clock: BUILD (0..1)
is where the piece is, and every layer reads it.
  BUILD     the fader. AUTO creeps it forward (minutes from 0 to the peak); PEAK glides it to 1 over N s; HOLD freezes it;
            you can always grab it. At 1 everything runs at its peak rate for as long as you stay there.
  MASTER    fader + FADE OUT / FADE IN over N s (FADE OUT also stops new events once it is silent). START begins again from BUILD.
  THE END   (2026-10-03, Jon: "the hard cut might need ... sitar strings sympathetic strings ringing over everything ... muting with a
            finger? or a little percussive accent?" -> he picked sharp/ring/out/ring_finger_soft.wav)
            HARD CUT = a FINGER MUTE: the highs go first, silent in ~40 ms (untick for a 4-ms choke); every voice freed, layers stopped.
            STRINGS: 13 sitar sympathetic strings (the idtap Karplus-Strong string with stiffness, in-loop damping and JAWARI, + the
            fitted body; tuned C D E G A, C3-E5, what the harmonium peak sounds), driven by everything the tornado plays. They ring
            26 dB under the music the whole time (level 0 dB), never jump; the cut just exposes them, dying over ~4 s ("ring").
            FADE OUT fades them too. (First tries, same night: plain comb filters + a JPverb room -- "corny and cheap sounding".)
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
FOLLOW (OFF by default -- Jon didn't like it) FOLLOW (2026-10-03, Jon: "can it also affect the volumes of different elements, their activity? like a trailing avg maybe?"):
  each layer's volume follows a TRAILING AVERAGE of the dancers' motion (AC RMS, one-pole over "window" s, / its 95th percentile in the
  10-02 run, on a square-root scale so typical motion = 0 dB): still dancers -> about -0.8 x depth dB, a sustained surge -> +depth dB.
  Each layer picks its driver (ensemble of 1-6, one dancer 1-7, or off). Acts LIVE on everything already sounding.
Out: one B-format bus -> the AMBI tab (quad + binaural); no AMBI tab = a stereo fold-down on outs 1-2. Needs the FORCE tab on the
live OSC for the dancers. Display: everything redraws 4 times a second at most.
*/
(
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/tornado_engine.scd".standardizePath).pathOnly;
~tnRoot = here +/+ ".." +/+ "sharp" +/+ "accents";
~tnP = ~tnP ? (master: 0.0, fade: 8, toClimax: 240, climaxS: 20, sens: 1, lines: 0, perc: 0, harm: 0, birds: 0, snatch: 0, ambi: true);
~tnRingGain = 0.66;   // calibration: lvl 0 dB = 26 dB under the music (headless, BUILD 0.9: strings 22.4 dB under at gain 1; 2026-10-03)
~tnP = (ringOn: true, ringLvl: 0, ringT60: 4, finger: true, folOn: false, folWin: 4, folDepth: 6, folDrv: (lines: 7, perc: 7, harm: 7, birds: 7, snatch: 8)).putAll(~tnP);   // folDrv: 0-6 = dancer 1-7, 7 = ensemble, 8 = off   // the RING after HARD CUT
~tnP[\folOn] = false;   // FOLLOW off (Jon, 2026-10-03: "I actually didn't like the people driving the volume of the elements"); tick it to try again
~tnX = ~tnX ? 0; ~tnRun = false; ~tnAuto = false; ~tnClimaxAt = nil; ~tnAtClimax = nil; ~tnHold = false; ~tnGlide = nil; ~tnLat = 0.05; ~tnAct = 0;
~tnStats = (entries: 0, hits: 0, events: 0); ~tnLoaded = false;
s = Server.default;
s.waitForBoot { fork {
	var man, rd, n = 0, total, loadList;
	// ---- tear down a previous evaluation ----
	{ ~tnWin !? { if (~tnWin.isClosed.not) { ~tnWin.onClose = nil; ~tnWin.close } } }.defer;
	~tnStop !? { ~tnStop.() }; ~tnJolt !? { ~tnJolt.free }; ~tnFolSyn !? { ~tnFolSyn.free }; ~tnMasterSyn !? { ~tnMasterSyn.free }; ~tnRingSyn !? { ~tnRingSyn.free }; ~tnGrp !? { ~tnGrp.free };
	~tnAllBufs !? { ~tnAllBufs.do(_.free) }; OSCdef(\tnHit).free; OSCdef(\tnAct).free; OSCdef(\tnLvl).free; MIDIdef(\tncc).free; MIDIdef(\tnnote).free;
	~tnBus !? { ~tnBus.free }; ~tnBus = Bus.audio(s, 4); ~tnRingIn !? { ~tnRingIn.free }; ~tnRingIn = Bus.audio(s, 1); ~tnDummy4 !? { ~tnDummy4.free }; ~tnDummy4 = Bus.audio(s, 4);
	~tnZero !? { ~tnZero.free }; ~tnZero = Bus.control(s, 14).setn(0 ! 14);
	~tnLBus !? { ~tnLBus.free }; ~tnLBus = Bus.control(s, 5).setn(1 ! 5); ~tnLayerIx = (lines: 0, perc: 1, harm: 2, birds: 3, snatch: 4);   // FOLLOW: live level per layer

	man = File.readAllString(~tnRoot +/+ "live" +/+ "live.json").parseJSON;
	~tnGains = (); man["gains"].keysValuesDo { |k, v| ~tnGains[k.asSymbol] = v.asFloat };
	~tnThr = man["jolt_thr"].collect(_.asFloat); ~tnAct95 = man["act95"].asFloat;
	~tnSpeeds = man["speeds"].collect(_.asFloat);

	// ---- synths ----
	SynthDef(\tnMono, { |buf, amp = 1, az = 0, width = 0.8, dur = 0, att = 0.002, rel = 0.05, out = 0, lbus = 0|
		var lv = In.kr(lbus);
		var d = Select.kr(dur > 0, [BufDur.ir(buf), dur]);
		var env = EnvGen.kr(Env([0, 1, 1, 0], [att, (d - att - rel).max(0), rel]), doneAction: 2);
		var b = FoaPanB.ar(PlayBuf.ar(1, buf, BufRateScale.ir(buf), doneAction: 2) * env * amp * lv, az, 0);
		Out.ar(out, [b[0], b[1] * width, b[2] * width, b[3] * width]) }).load(s);
	SynthDef(\tnStereo, { |buf, amp = 1, az = 0, spread = 0.52, width = 0.8, dur = 0, att = 0.002, rel = 0.05, out = 0, lbus = 0|
		var lv = In.kr(lbus);
		var d = Select.kr(dur > 0, [BufDur.ir(buf), dur]);
		var env = EnvGen.kr(Env([0, 1, 1, 0], [att, (d - att - rel).max(0), rel]), doneAction: 2);
		var x = PlayBuf.ar(2, buf, BufRateScale.ir(buf), doneAction: 2) * env * amp * lv;
		var b = FoaPanB.ar(x[0], az + spread, 0) + FoaPanB.ar(x[1], az - spread, 0);
		Out.ar(out, [b[0], b[1] * width, b[2] * width, b[3] * width]) }).load(s);
	// HARD CUT (gate 0): finger = like a hand on the strings (Jon's pick, ring_finger_soft): the highs go first (lowpass 20 kHz -> 400 Hz
	// in ~8 ms), gone in ~40 ms; finger 0 = choke in 4 ms
	SynthDef(\tnMaster, { |in = 0, out = 0, abus = 0, ambi = 0, master = 1, mlag = 0.1, gate = 1, ringbus = 0, finger = 1|
		var fc = 400 * (50 ** Lag.kr(gate, 0.008)), sw = finger * (gate < 0.5);
		var raw = In.ar(in, 4).collect { |r| Select.ar(sw, [r, LPF.ar(r, fc)]) };
		var g = raw * Lag.kr(gate, Select.kr(finger, [0.004, 0.04])), b = g * VarLag.kr(master, mlag, warp: \sin);
		Out.ar(ringbus, g[0]);                                                            // the RING's input: after the cut, before the fader
		SendPeakRMS.kr(b[0], 4, 3, '/tnLvl');
		Out.ar(abus, b * ambi.lag(0.05));
		Out.ar(out, [b[0] * 2.sqrt + b[2], b[0] * 2.sqrt - b[2]] * 0.5 * (1 - ambi).lag(0.05)) }).load(s);
	// RING (2026-10-03, Jon picked sharp/ring/out/ring_finger_soft.wav): the idtap sitar string (kernels.py ks_string) as 13 sympathetic
	// strings tuned C D E G A, C3-E5. Each: a delay loop (LocalIn = one block + DelayC) with the stiffness allpass, a one-pole lowpass
	// and the loop gain from T60 inside it, and JAWARI -- the sounding length shortened by the string's own displacement (the buzz);
	// never plucked, only driven through the "bridge" by what the tornado plays (after the cut gate, so a finger mute stops the drive
	// too). Then the fitted sitar body (6 resonators, kernels.py SITAR_BODY_*). Calibrated (gain) so lvl 0 dB rings 26 dB under the music.
	SynthDef(\tnRing, { |in = 0, out = 0, abus = 0, ambi = 0, master = 1, mlag = 0.1, on = 1, t60 = 4, lvl = 1, drive = 0.005, gain = 1|
		var srL = s.sampleRate ? 48000, bs = BlockSize.ir, x = In.ar(in, 1) * drive;
		var midis = [48, 50, 52, 55, 57, 60, 62, 64, 67, 69, 72, 74, 76], a = 0.4995871023130969, jaw = 0.4966044493908164, thr = 0.0028586992022563043;
		var fb = LocalIn.ar(midis.size), strs, b;
		var bodyF = [61.551765783016805, 394.76819702770854, 356.6305040103169, 550.0312125345872, 1133.764848607439, 2634.183052925333], bodyQ = [6, 8, 6, 5, 4, 3], bodyMix = 0.558298962867979;
		strs = midis.collect { |m, j|
			var f = m.midicps, w = 2pi * f / srL, pd = atan2(sin(w) * (1 - a.squared), (2 * a) + ((1 + a.squared) * cos(w))) / w, d = (srL / f) - pd;
			var g = (10 ** (-3 / (f * t60))).min(0.99999), dd = (d * (1 - (jaw * (fb[j] - thr).max(0)))).max(bs + 1);
			x + (g * OnePole.ar(FOS.ar(DelayC.ar(fb[j], 0.03, (dd - bs) / srL), a, 1, a.neg), 0.004)) };
		LocalOut.ar(strs);
		b = strs.collect { |y, j| FoaPanB.ar(y, j * 137.50776.degrad, 0) }.sum / midis.size.sqrt;
		b = b.collect { |c| (bodyMix * bodyF.collect { |bf, k| BPF.ar(c, bf, bodyQ[k].reciprocal) * bodyQ[k] }.sum) + ((1 - bodyMix) * c) };
		SendPeakRMS.kr(strs.abs.reduce(\max), 2, 3, '/tnRingPk');
		b = LeakDC.ar(b) * gain * lvl * VarLag.kr(master, mlag, warp: \sin) * Lag.kr(on, 0.1);
		Out.ar(abus, b * ambi.lag(0.05));
		Out.ar(out, [b[0] * 2.sqrt + b[2], b[0] * 2.sqrt - b[2]] * 0.5 * (1 - ambi).lag(0.05)) }).load(s);
	// FOLLOW: trailing averages of the dancers -> a level per layer on ~tnLBus
	SynthDef(\tnFollow, { |fbus = 0, out = 0, win = 4, depth = 6, on = 1|
		var ac = In.kr(fbus + 7, 7).clip(-1, 1), sq = ac.squared ++ [ac.keep(6).squared.sum / 6];
		var coef = exp(-1 / (win.max(0.2) * ControlRate.ir)), tr = sq.collect { |q| OnePole.kr(q, coef).max(0).sqrt };
		var u = (tr / \p95.kr(0.6 ! 8)).clip(0, 1.2).sqrt, db = depth * ((u - 0.45) / 0.55).clip(-1, 1);
		var lv = \drv.kr(7 ! 5).collect { |d| Select.kr(d, db ++ [0]) };
		Out.kr(out, (lv * on).dbamp.lag(0.5)) }).load(s);
	// JOLTS: a jump of a sensor's AC between frames, over that sensor's 99th percentile today (x sens); at most one per 0.12 s
	SynthDef(\tnJolt, { |fbus = 0, sens = 1, act95 = 0.56|
		var ac = In.kr(fbus + 7, 7), thr = \thr.kr(0.08 ! 7);
		7.do { |k| var j = (ac[k] - Delay1.kr(ac[k])).abs / thr[k] * sens; SendReply.kr(Trig1.kr(j > 1, 0.12), '/tnHit', [k, j], k) };
		SendReply.kr(Impulse.kr(10), '/tnAct', [(Lag.kr(ac.keep(6).squared.sum / 6, 1.0).sqrt / act95)]) }).load(s);
	s.sync;

	// ---- GUI (2026-10-02 night, redesigned: Jon couldn't read the first one -- "surely you should be able to see how much time is
	// left, and to set it even") ----
	{
		var big = Font.default.size_(15).boldVariant, huge = Font.default.size_(28).boldVariant, head = Font.default.size_(12).boldVariant;
		var hd = { |t| StaticText().string_(t).font_(head).stringColor_(Color.grey(0.35)) };
		var box = { |key, lo, hi, step, dec, w = 56, fn| var b = NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec)
			.value_(~tnP[key]).fixedWidth_(w).action_({ |bx| ~tnP[key] = bx.value; fn.(bx.value) }); ~tnBoxes[key] = b; b };   // returns the BOX
		var lbl = { |t, w| var st = StaticText().string_(t); w !? { st.fixedWidth_(w) }; st };
		~tnBoxes = ();
		~tnWin = if (~stHost.notNil) { ~stHost.(\tornado) } { Window("TORNADO -- the ending, live", Rect(80, 60, 1100, 640)).front };
		~uiPending = ~uiPending ? IdentityDictionary.new; ~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
		if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
			~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
		// transport
		~tnInfo = StaticText().string_(if (~tnLoaded) { "ready" } { "loading sounds ..." });
		~tnRunBtn = Button().states_([["START", Color.black, Color.green(0.75)], ["STOP (let ring)", Color.white, Color.blue(0.5)]]).fixedSize_(Size(160, 46)).font_(big)
			.action_({ |b| if (b.value == 1) { ~tnStart.() } { ~tnStop.() } });
		~tnStartBtn = ~tnRunBtn;
		~tnCutBtn = Button().states_([["HARD CUT", Color.white, Color.red(0.75)]]).fixedSize_(Size(170, 46)).font_(big).action_({ ~tnHardCut.(); ~tnRunBtn.value = 0 });
		// the clock
		~tnCountdown = StaticText().string_("AUTO is off").font_(huge).fixedWidth_(420);
		~tnAutoBox = CheckBox().string_("AUTO").font_(big).value_(~tnAuto).action_({ |c| ~tnSetAuto.(c.value) });
		~tnMinBox = NumberBox().clipLo_(0).clipHi_(60).step_(1).decimals_(0).value_((~tnP[\toClimax] / 60).floor).fixedWidth_(46);
		~tnSecBox = NumberBox().clipLo_(0).clipHi_(59).step_(5).decimals_(0).value_(~tnP[\toClimax] % 60).fixedWidth_(46);
		~tnSetBtn = Button().states_([["SET + AUTO", Color.black, Color.new(1, 0.85, 0.5)]]).fixedWidth_(110)
			.action_({ ~tnP[\toClimax] = (~tnMinBox.value * 60) + ~tnSecBox.value; ~tnSetAuto.(true) });
		~tnMinus = Button().states_([["-30 s"]]).fixedWidth_(56).action_({ ~tnNudge.(-30) });
		~tnPlus = Button().states_([["+30 s"]]).fixedWidth_(56).action_({ ~tnNudge.(30) });
		~tnHoldBtn = Button().states_([["HOLD", Color.black, Color.grey(0.85)], ["HOLDING (clock paused)", Color.white, Color.new(0.7, 0.45, 0)]]).fixedWidth_(190)
			.action_({ |b| ~tnHold = b.value == 1; if (~tnHold) { ~tnGlide = nil } });
		~tnClimaxBtn = Button().states_([["PEAK NOW", Color.black, Color.new(1, 0.6, 0.2)]]).fixedWidth_(120)
			.action_({ ~tnHold = false; ~tnHoldBtn.value = 0; ~tnGlideTo.(1, ~tnP[\climaxS]) });
		// BUILD
		~tnBuild = Slider().orientation_(\horizontal).fixedHeight_(44).value_(~tnX).action_({ |sl| ~tnGlide = nil; ~tnX = sl.value });
		~tnBuildTxt = StaticText().string_("BUILD " ++ (~tnX * 100).round ++ " %").fixedWidth_(130).font_(big);
		~tnNowTxt = StaticText().string_("").font_(Font.default.size_(13));
		// output
		~tnMaster = Slider().orientation_(\horizontal).fixedHeight_(30).value_((~tnP[\master].dbamp / 2).sqrt.min(1)).action_({ |sl|
			var a = 2 * sl.value.squared; ~tnP[\master] = a.max(0.00001).ampdb; ~tnMasterSyn !? { ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, a) }; ~tnRingSyn !? { ~tnRingSyn.set(\mlag, 0.1, \master, a) }; ~uiLater.(\tnM, { ~tnMasterTxt.string = if (a < 0.0001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } }) });
		~tnMasterTxt = StaticText().string_(~tnP[\master].round(0.5).asString ++ " dB").fixedWidth_(64);
		~tnFadeOut = Button().states_([["FADE OUT", Color.white, Color.red(0.55)]]).fixedWidth_(100).action_({ ~tnFade.(0, ~tnP[\fade]) });
		~tnFadeIn = Button().states_([["FADE IN", Color.black, Color.green(0.8)]]).fixedWidth_(90).action_({ ~tnFade.(~tnMasterAmp.(), ~tnP[\fade]) });
		~tnAmbiBox = CheckBox().string_("AMBI (else stereo on outs 1-2)").value_(~tnP[\ambi]).action_({ |c| ~tnSetAmbi.(c.value) });
		~tnStatus = StaticText().string_("").font_(Font.monospace(12));
		~tnWin.layout = VLayout(
			HLayout(~tnRunBtn, ~tnCutBtn, ~tnInfo, nil),
			View().fixedHeight_(1).background_(Color.grey(0.6)),
			hd.("THE CLOCK -- when the peak comes"),
			HLayout(~tnCountdown, ~tnAutoBox, lbl.("peak in"), ~tnMinBox, lbl.("min"), ~tnSecBox, lbl.("s"), ~tnSetBtn, ~tnMinus, ~tnPlus, nil),
			HLayout(~tnHoldBtn, ~tnClimaxBtn, lbl.("over"), box.(\climaxS, 1, 300, 1, 0), lbl.("s"), nil),
			View().fixedHeight_(1).background_(Color.grey(0.6)),
			hd.("BUILD -- where the ending is (drag it any time; the clock re-paces from where you leave it)"),
			HLayout(~tnBuildTxt, [~tnBuild, stretch: 1]),
			HLayout(*([lbl.("jump to"), 0, 25, 50, 75, 90].collect { |p| if (p.isKindOf(View)) { p } { Button().states_([[p.asString ++ " %"]]).fixedWidth_(56).action_({ ~tnGlide = nil; ~tnX = p / 100 }) } } ++ [nil])),
			~tnNowTxt,
			View().fixedHeight_(1).background_(Color.grey(0.6)),
			hd.("OUTPUT"),
			HLayout(lbl.("MASTER"), [~tnMaster, stretch: 1], ~tnMasterTxt, lbl.("fade"), box.(\fade, 0.1, 120, 0.5, 1), lbl.("s"), ~tnFadeIn, ~tnFadeOut, ~tnAmbiBox),
			hd.("MIX (dB, 0 = as in the render)"),
			HLayout(lbl.("lines"), box.(\lines, -40, 12, 1, 0), lbl.("  percussion"), box.(\perc, -40, 12, 1, 0), lbl.("  harmonium"), box.(\harm, -40, 12, 1, 0),
				lbl.("  birds"), box.(\birds, -40, 12, 1, 0), lbl.("  snatches"), box.(\snatch, -40, 12, 1, 0),
				lbl.("     dancers' jolt sensitivity"), box.(\sens, 0.1, 5, 0.1, 1, 52, { |v| ~tnJolt !? { ~tnJolt.set(\sens, v) } }), lbl.("x"), nil),
			hd.("FOLLOW -- each layer's volume follows a trailing average of the dancers (live, on everything sounding)"),
			HLayout(CheckBox().string_("follow").value_(~tnP[\folOn]).action_({ |c| ~tnP[\folOn] = c.value; ~tnSetFollow.() }),
				lbl.("  window"), box.(\folWin, 0.5, 60, 0.5, 1, 52, { ~tnSetFollow.() }), lbl.("s   depth"), box.(\folDepth, 0, 18, 1, 0, 44, { ~tnSetFollow.() }), lbl.("dB  "),
				*([\lines, \perc, \harm, \birds, \snatch].collect { |k| [lbl.(["lines", "perc", "harm", "birds", "snatch"][[\lines, \perc, \harm, \birds, \snatch].indexOf(k)]),
					PopUpMenu().items_(["1", "2", "3", "4", "5", "6", "7 ctr", "ensemble", "off"]).value_(~tnP[\folDrv][k] ? 7).fixedWidth_(86)
						.action_({ |m| ~tnP[\folDrv][k] = m.value; ~tnSetFollow.() })] }.flatten ++ [nil])),
			~tnFolTxt = StaticText().string_("").font_(Font.monospace(11)),
			hd.("THE END -- HARD CUT as a finger mute; sitar sympathetic strings (C D E G A, jawari) ring under the music and on after it"),
			HLayout(CheckBox().string_("finger mute (else 4-ms choke)").value_(~tnP[\finger]).action_({ |c| ~tnP[\finger] = c.value; ~tnSetRing.() }),
				CheckBox().string_("   strings").value_(~tnP[\ringOn]).action_({ |c| ~tnP[\ringOn] = c.value; ~tnSetRing.() }),
				lbl.("   level"), box.(\ringLvl, -40, 20, 1, 0, 52, { ~tnSetRing.() }), lbl.("dB (0 = 26 dB under the music)   ring"), box.(\ringT60, 0.5, 30, 0.5, 1, 52, { ~tnSetRing.() }), lbl.("s"), nil),
			View().fixedHeight_(1).background_(Color.grey(0.6)),
			~tnStatus,
			nil);
		// what is in at a given BUILD, and what joins next
		~tnEntries = [[0, "tornado lines (voice)"], [0.10, "birds, snatches"], [0.12, "+ breath lines, harmonium swells"], [0.15, "Articulation phrases, thuds"],
			[0.25, "+ fry lines, kick heartbeat"], [0.30, "booms, harmonium ladder"], [0.38, "+ harmonium lines"], [0.45, "higher harmonium"],
			[0.50, "+ mixed lines"], [0.60, "harmonium stabs"], [0.90, "high harmonium cluster"], [1.0, "PEAK (everything at full rate)"]];
		~tnStatRout = Routine { var last = (entries: 0, hits: 0, events: 0), n = 0; loop {
			var d = (entries: ~tnStats[\entries] - last[\entries], hits: ~tnStats[\hits] - last[\hits], events: ~tnStats[\events] - last[\events]);
			var x = ~tnX, nxt = ~tnEntries.detect { |e| e[0] > (x + 0.0001) }, rem = ~tnRemaining.();
			if (n % 4 == 0) { last = ~tnStats.copy };
			~uiLater.(\tnStat, {
				~tnBuild.value = x; ~tnBuildTxt.string = "BUILD " ++ (x * 100).round.asInteger ++ " %";
				~tnCountdown.string = case
					{ x >= 0.999 } { "AT PEAK  " ++ (Main.elapsedTime - (~tnAtClimax ? Main.elapsedTime)).asTimeString.drop(3).keep(5) }
					{ ~tnHold } { "HOLDING  (" ++ (rem ? 0).asTimeString.drop(3).keep(5) ++ " left)" }
					{ rem.notNil } { "PEAK IN  " ++ rem.asTimeString.drop(3).keep(5) }
					{ "AUTO is off" };
				~tnCountdown.stringColor_(if (x >= 0.999) { Color.red(0.7) } { if (rem.notNil and: { rem < 30 }) { Color.new(0.8, 0.4, 0) } { Color.black } });
				~tnNowTxt.string = "playing now: everything up to \"" ++ (~tnEntries.select { |e| e[0] <= (x + 0.0001) }.last[1]) ++ "\"" ++
					(nxt !? { "     next: " ++ nxt[1] ++ " at " ++ (nxt[0] * 100).round.asInteger ++ " %" + (if (rem.notNil and: { x < 1 }) { "(in ~" ++ ((nxt[0] - x) / (1 - x).max(0.001) * rem).round.asInteger ++ " s)" } { "" }) } ? "");
				~tnLBus !? { ~tnLBus.getn(5, { |v| ~tnFolNow = v }) };
				~tnFolNow !? { |v| ~tnFolTxt.string = if (~tnP[\folOn].not) { "follow off" } { "now  " ++ ["lines", "perc", "harm", "birds", "snatch"].collect { |nm, i| nm ++ " " ++ (v[i].max(0.0001).ampdb.round(0.5)) ++ " dB" }.join("   ") } };
				if (n % 4 == 0) { ~tnStatus.string = (if (~tnRun) { "RUNNING" } { "stopped" }) ++ "   dancers: " ++ d[\hits] ++ " jolts/s, motion " ++ (~tnAct * 100).round.asInteger
					++ " %   new lines " ++ d[\entries] ++ "/s   events " ++ d[\events] ++ "/s   sounding " ++ s.numSynths ++ " voices   out " ++ ((~tnPeak ? 0).max(0.000001).ampdb.round(1)) ++ " dB   CPU " ++ s.avgCPU.round(1) ++ " %" } });
			n = n + 1; 0.25.wait } }.play(AppClock);
		~tnWin.onClose = { ~tnStop.(); ~tnStatRout.stop; ~tnJolt !? { ~tnJolt.free }; ~tnFolSyn !? { ~tnFolSyn.free }; ~tnFolSyn = nil; ~tnMasterSyn !? { ~tnMasterSyn.free }; ~tnRingSyn !? { ~tnRingSyn.free }; ~tnGrp !? { ~tnGrp.free }; ~tnGrp = nil;
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
	~tnMasterSyn = if (~ambiGrp.notNil) { Synth.before(~ambiGrp, \tnMaster, [\in, ~tnBus.index, \ringbus, ~tnRingIn.index]) } { Synth.tail(s, \tnMaster, [\in, ~tnBus.index, \ringbus, ~tnRingIn.index]) };
	~tnRingSyn = Synth.after(~tnMasterSyn, \tnRing, [\in, ~tnRingIn.index]);
	~tnSetRing = { ~tnRingSyn !? { ~tnRingSyn.set(\on, ~tnP[\ringOn].asInteger, \t60, ~tnP[\ringT60], \lvl, ~tnP[\ringLvl].dbamp, \gain, ~tnRingGain) };
		~tnMasterSyn !? { ~tnMasterSyn.set(\finger, ~tnP[\finger].asInteger) } };
	~tnSetRing.();
	~tnSetAmbi = { |on| var a = on and: { ~ambiBus.notNil }; ~tnP[\ambi] = on;
		[~tnMasterSyn, ~tnRingSyn].do { |n| n !? { n.set(\ambi, a.asInteger, \abus, if (a) { ~ambiBus.index } { ~tnDummy4.index }) } };
		if (on and: { ~ambiBus.isNil }) { "TORNADO: AMBI needs the AMBI tab; playing a stereo fold-down".warn } };
	~tnSetAmbi.(~tnP[\ambi]);
	~tnMasterAmp = { ~tnP[\master].dbamp }; ~tnMasterSyn.set(\master, ~tnMasterAmp.()); ~tnRingSyn.set(\master, ~tnMasterAmp.());
	~tnJolt = Synth.head(s, \tnJolt, [\fbus, (~fhBus !? (_.index)) ? ~tnZero.index, \thr, ~tnThr, \sens, ~tnP[\sens], \act95, ~tnAct95]);
	~tnFolSyn = Synth.after(~tnJolt, \tnFollow, [\fbus, (~fhBus !? (_.index)) ? ~tnZero.index, \out, ~tnLBus.index,
		\p95, [0.659, 0.585, 0.727, 0.628, 0.62, 0.614, 0.595, 0.555]]);   // 4-s trailing RMS, 95th pct, 10-02 11:47-13:04 (1-7, ensemble)
	~tnSetFollow = { var dv = ~tnP[\folDrv]; ~tnFolSyn !? { ~tnFolSyn.set(\on, ~tnP[\folOn].asInteger, \win, ~tnP[\folWin], \depth, ~tnP[\folDepth],
		\drv, [\lines, \perc, \harm, \birds, \snatch].collect { |k| dv[k] ? 7 }) } };
	~tnSetFollow.();

	// ---- helpers ----
	~tnCres = { |x| (-22 + (22 * (x ** 1.5))).dbamp };              // the layers' crescendo
	~tnCresL = { |x| (-20 + (20 * x)).dbamp };                         // the lines' crescendo (forann_additive)
	~tnLvl = { |k| ~tnP[k].dbamp };
	~tnPick = { |cats| var pool = cats.collect { |c| ~tnHits[c] ? [] }.flatten; pool.choose };
	~tnPlay = { |def, buf, amp, az, args, layer|
		if (~tnRun and: { buf.notNil }) { ~tnStats[\events] = ~tnStats[\events] + 1;
			s.makeBundle(~tnLat, { Synth(def, [\buf, buf, \amp, amp, \az, az, \out, ~tnBus.index, \lbus, ~tnLBus.index + (~tnLayerIx[layer] ? 1)] ++ (args ? []), ~tnGrp) }) } };
	~tnPlayL = { |layer, def, buf, amp, az, args| ~tnPlay.(def, buf, amp, az, args, layer) };
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
			~tnPlayL.(\lines, \tnMono, b, ~tnCresL.(x) * ~tnGains[\lines] * ~tnLvl.(\lines), (~tnK * ~tnGolden) % 2pi, [\width, 0.75]);
			~tnK = ~tnK + 1; ~tnStats[\entries] = ~tnStats[\entries] + 1;
			(1.5 * ((0.12 / 1.5) ** (x ** 1.6))).wait } },
		pulse: { loop { var x = ~tnX, y;
			if (x < 0.25) { 0.25.wait } {
				~tnPlayL.(\perc, \tnMono, ~tnPick.([\kick, \art_boom]), 0.7 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand, [\width, 0.2]);
				y = (x - 0.25) / 0.75; (1.5 * ((0.07 / 1.5) ** (y ** 1.6)) * rrand(0.92, 1.08)).wait } } },
		phrases: { loop { var x = ~tnX;
			if (x < 0.15) { 0.5.wait } {
				~tnPlayL.(\perc, \tnStereo, ~tnPick.([\art_phrase]), 0.45 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand);
				(30 * ((1.1 / 30) ** (((x - 0.15) / 0.85).max(0) ** 1.3)) * rrand(0.7, 1.3)).wait } } },
		swarm: { loop { var x = ~tnX;
			if ((0.35 + ~tnAct).min(1).coin) { ~tnPlayL.(\perc, \tnMono, ~tnPick.([\klatter_hi, \klatter_mid, \boops, \art_klatter]), 0.3 * ~tnCres.(x) * ~tnGains[\perc] * ~tnLvl.(\perc), 2pi.rand) };
			~tnExp.(1.0 / (0.2 * (200 ** (x ** 1.7)))).max(0.004).min(10).wait } },
		swell: { loop { var x = ~tnX, hi, b;
			if (x < 0.12) { 0.5.wait } {
				hi = (((x - 0.45) / 0.55).max(0)).coin; b = if (hi) { ~tnSwell.copyRange(30, ~tnSwell.size - 1).choose } { ~tnSwell.keep(30).choose };
				~tnPlayL.(\harm, \tnStereo, b, 0.8 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.7]);
				(18 * ((2 / 18) ** (((x - 0.12) / 0.88).max(0) ** 1.2)) * rrand(0.7, 1.3)).wait } } },
		ladder: { loop { var x = ~tnX, y, target, size, cand, len;
			if (x < 0.3) { 0.5.wait } {
				y = (x - 0.3) / 0.7; target = ~tnTop * (y ** 1.15); size = (1 + (5 * (y ** 1.4) + 1.0.rand).floor).min(6).asInteger;
				cand = ~tnNotes.select { |p| (p[0] >= (target - 9)) and: { p[0] <= (target + 1) } };
				if (cand.isEmpty) { cand = [~tnNotes.minItem { |p| (p[0] - target).abs }] };
				len = rrand(0.35, 1.2) * (1 - (0.6 * y));
				size.do { var p = cand.choose; ~tnPlayL.(\harm, \tnStereo, p[1], 0.6 * ~tnCres.(x) / size.sqrt * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.4, \dur, len, \att, 0.01, \rel, 0.15]) };
				(1.2 * ((0.15 / 1.2) ** (y ** 1.3)) * rrand(0.85, 1.15)).wait } } },
		cluster: { loop { var x = ~tnX;
			if (x < 0.9) { 0.5.wait } {
				~tnPlayL.(\harm, \tnStereo, ~tnCluster.choose, 0.9 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), 2pi.rand, [\spread, 0.8]);
				(2.5 * (1 - ((x - 0.9) / 0.1))).max(0.6).wait } } },
		birds: { loop { var x = ~tnX;
			if (x < 0.1) { 0.5.wait } {
				~tnPlayL.(\birds, \tnMono, ~tnBirds.choose, 0.5 * ~tnCres.(x) * ~tnGains[\birds] * ~tnLvl.(\birds), 2pi.rand);
				~tnExp.(1.0 / (0.05 * (60 ** (((x - 0.1) / 0.9).max(0) ** 1.4)))).max(0.02).min(60).wait } } },
		snatch: { var j = 0; loop { var x = ~tnX, kind, pool, b, linesRms, amp;
			if (x < 0.1) { 0.5.wait } {
				kind = if (j.odd) { \pp } { [\rite_open, \rite_open, \rite_open, \rite_mid].choose };
				pool = ~tnSnatch.select { |p| p[0] == kind }; b = (pool.choose ? ~tnSnatch.choose)[1];
				// 10 dB under the lines at this moment: ~ (line level) x sqrt(lines sounding)
				linesRms = ~tnCresL.(x) * ~tnGains[\lines] * ((43.7 * (0.33 ** (x ** 1.6))) / (1.5 * ((0.12 / 1.5) ** (x ** 1.6)))).sqrt;
				~tnPlayL.(\snatch, \tnStereo, b, linesRms * -10.dbamp * ~tnLvl.(\snatch), 2pi.rand, [\spread, 0.6]);
				j = j + 1; (10 + rrand(14, 24)).wait } } }
	);
	// the dancers: every jolt
	OSCdef(\tnHit, { |msg| var k = msg[3].asInteger, j = msg[4], x = ~tnX, az, v, pc = ~tnGains[\perc] * ~tnLvl.(\perc);
		if (~tnRun) { ~tnStats[\hits] = ~tnStats[\hits] + 1;
			az = if (k < 6) { (k * 60 + rrand(-15, 15)).degrad } { 2pi.rand }; v = (0.45 + (0.25 * j)).min(1);
			if ((0.15 + (0.85 * x)).coin) { (1 + ~tnPois.(7 * (x ** 2.2))).min(12).do { |r|
				var b = ~tnPick.([\klatter_hi, \klatter_mid, \art_klatter, \boops]), dt = r * rrand(0.018, 0.055);
				if (~tnRun and: { b.notNil }) { s.makeBundle(~tnLat + dt, { Synth(\tnMono, [\buf, b, \amp, 0.5 * v * ~tnCres.(x) * (0.85 ** r) * pc, \az, az + rrand(-0.2, 0.2), \out, ~tnBus.index, \lbus, ~tnLBus.index + 1], ~tnGrp) }) } } };
			if ((x >= 0.15) and: { j > 1.3 } and: { 0.6.coin }) { ~tnPlayL.(\perc, \tnMono, ~tnPick.([\thud, \art_thud, \fry]), 0.6 * v * ~tnCres.(x) * pc, az) };
			if ((x >= 0.3) and: { (j > 1.4) or: { k == 6 } } and: { (0.35 + (0.65 * x)).coin }) { ~tnPlayL.(\perc, \tnMono, ~tnPick.([\art_boom, \art_boom, \kick]), 0.8 * v * ~tnCres.(x) * pc, az, [\width, 0.3]) };
			if ((x >= 0.6) and: { j > 2.2 } and: { 0.5.coin }) {
				~tnPlayL.(\harm, \tnStereo, if (x.coin) { ~tnStab.copyRange(20, ~tnStab.size - 1).choose } { ~tnStab.keep(20).choose }, 1.1 * ~tnCres.(x) * ~tnGains[\harm] * ~tnLvl.(\harm), az) } } }, '/tnHit', s.addr);
	OSCdef(\tnAct, { |msg| ~tnAct = msg[3] }, '/tnAct', s.addr);
	OSCdef(\tnRingPk, { |msg| ~tnRingPk = msg[3] }, '/tnRingPk', s.addr);   // loudest string displacement (jawari engages above 0.003)
	OSCdef(\tnLvl, { |msg| ~tnPeak = msg[3] }, '/tnLvl', s.addr);

	// ---- transport ----
	~tnRouts = ();
	~tnStart = { if (~tnLoaded) {
		~tnStop.(); ~tnRun = true; ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, ~tnMasterAmp.()); ~tnRingSyn.set(\mlag, 0.1, \master, ~tnMasterAmp.());
		~tnJolt.set(\fbus, (~fhBus !? (_.index)) ? ~tnZero.index); ~tnFolSyn !? { ~tnFolSyn.set(\fbus, (~fhBus !? (_.index)) ? ~tnZero.index) };
		~tnLayers.keysValuesDo { |k, f| ~tnRouts[k] = Routine(f).play(SystemClock) };
		~tnClock = Routine { var last = Main.elapsedTime; loop { var now = Main.elapsedTime, dt = now - last; last = now;
			if (~tnGlide.notNil) { var g = ~tnGlide; ~tnX = (~tnX + (dt * g[\rate])).clip(0, 1); if (((g[\rate] > 0) and: { ~tnX >= g[\to] }) or: { (g[\rate] < 0) and: { ~tnX <= g[\to] } }) { ~tnX = g[\to]; ~tnGlide = nil } } {
				if (~tnHold) { ~tnClimaxAt !? { ~tnClimaxAt = ~tnClimaxAt + dt } } {   // HOLD pauses the countdown
					if (~tnAuto and: { ~tnClimaxAt.notNil }) { var rem = ~tnClimaxAt - now;
						~tnX = if (rem <= dt) { 1 } { (~tnX + (dt * (1 - ~tnX) / rem)).min(1) } } } };
			if (~tnX >= 0.999) { ~tnAtClimax = ~tnAtClimax ? now } { ~tnAtClimax = nil };
			0.05.wait } }.play(SystemClock);
		"TORNADO: running from BUILD " ++ (~tnX * 100).round ++ " %".postln } { "TORNADO: still loading".warn } };
	~tnStop = { ~tnRouts !? { ~tnRouts.do(_.stop) }; ~tnRouts = (); ~tnClock !? { ~tnClock.stop }; ~tnClock = nil; ~tnRun = false };
	~tnHardCut = { ~tnMasterSyn !? { ~tnMasterSyn.set(\gate, 0) };  ~tnStop.(); ~tnFadeRout !? { ~tnFadeRout.stop };
		SystemClock.sched(0.06, { ~tnGrp !? { ~tnGrp.freeAll }; nil }); "TORNADO: HARD CUT".postln };
	~tnFade = { |toAmp, secs| ~tnMasterSyn.set(\gate, 1, \mlag, secs, \master, toAmp); ~tnRingSyn.set(\mlag, secs, \master, toAmp); ~tnFadeRout !? { ~tnFadeRout.stop };
		if (toAmp <= 0) { ~tnFadeRout = Routine { (secs + 0.2).wait; ~tnStop.(); ~tnGrp.freeAll; { ~tnRunBtn !? { ~tnRunBtn.value = 0 } }.defer }.play(SystemClock) } };
	~tnGlideTo = { |to, secs| ~tnGlide = (to: to, rate: (to - ~tnX) / secs.max(0.05)); if (to >= 1) { ~tnClimaxAt = Main.elapsedTime + secs } };
	// THE CLOCK: AUTO = reach the peak at a deadline (now + "peak in"); BUILD paces itself to land on it and re-paces from wherever
	// the fader is left; HOLD pauses the countdown; -30 / +30 s move the deadline
	~tnSetAuto = { |on| ~tnAuto = on; if (on) { ~tnClimaxAt = Main.elapsedTime + ~tnP[\toClimax] } { ~tnClimaxAt = nil };
		{ ~tnAutoBox !? { ~tnAutoBox.value = on } }.defer };
	~tnNudge = { |secs| if (~tnClimaxAt.notNil) { ~tnClimaxAt = (~tnClimaxAt + secs).max(Main.elapsedTime + 1) } { ~tnP[\toClimax] = (~tnP[\toClimax] + secs).max(10);
		{ ~tnMinBox.value = (~tnP[\toClimax] / 60).floor; ~tnSecBox.value = ~tnP[\toClimax] % 60 }.defer } };
	~tnRemaining = { if (~tnAuto and: { ~tnClimaxAt.notNil }) { (~tnClimaxAt - Main.elapsedTime).max(0) } { nil } };

	// ---- nanoKONTROL2 (2026-10-02): shared like the other tabs (TRACK < > passes it on; selecting this tab takes it) ----
	//   fader 1 BUILD   fader 2 MASTER   faders 3-7 levels (lines, percussion, harmonium, birds, snatches: -36 .. +6 dB)   fader 8 jolt sens
	//   knob 1 time to the peak (30 s - 15 min; << starts AUTO with it)   knob 2 PEAK glide s (2-90)   knob 3 fade s (0.5-30)
	//   knob 4 strings ring s (0.5-20)   knob 5 strings level (-30 .. +12 dB)   knob 6 FOLLOW window s (1-30)   knob 7 FOLLOW depth dB (0-18)
	//   PLAY start   STOP stop (let ring)   REC HARD CUT   CYCLE hold   >> peak   << auto on/off   SET fade out   MARKER < fade in
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
		{ num == 43 } { ~tnSetAuto.(~tnAuto.not) }
		{ num == 60 } { ~tnFade.(0, ~tnP[\fade]) }
		{ num == 61 } { ~tnFade.(~tnMasterAmp.(), ~tnP[\fade]) } };
	MIDIClient.init(verbose: false); MIDIIn.connectAll(verbose: false);
	MIDIdef.cc(\tncc, { |val, cc| var v = val / 127;
		if (~mkOwner == \tornado) {
			case
			{ cc == 0 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, ~tnX) }) { ~tnGlide = nil; ~tnX = v } }
			{ cc == 1 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, (~tnP[\master].dbamp / 2).sqrt.min(1)) }) {
				var a = 2 * v.squared; ~tnP[\master] = a.max(0.00001).ampdb; ~tnMasterSyn !? { ~tnMasterSyn.set(\gate, 1, \mlag, 0.1, \master, a) }; ~tnRingSyn !? { ~tnRingSyn.set(\mlag, 0.1, \master, a) };
				~uiLater.(\tnKM, { ~tnMaster.value = v; ~tnMasterTxt.string = if (a < 0.0001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } }) } }
			{ (cc >= 2) and: { cc <= 6 } } { var key = [\lines, \perc, \harm, \birds, \snatch][cc - 2];
				if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, ~tnVOfDb.(~tnP[key])) }) { ~tnSetBox.(key, ~tnDbOf.(v).round(0.5)) } }
			{ cc == 7 } { if (~tnSteady.(cc, val) and: { ~tnCatch.(cc, v, (~tnP[\sens] / 0.25).log / 12.log) }) { var sv = 0.25 * (12 ** v); ~tnSetBox.(\sens, sv.round(0.05)); ~tnJolt !? { ~tnJolt.set(\sens, sv) } } }
			{ cc == 16 } { var t = (30 * (30 ** v)).round(5); ~tnP[\toClimax] = t; ~uiLater.(\tnK16, { ~tnMinBox.value = (t / 60).floor; ~tnSecBox.value = t % 60 }) }
			{ cc == 17 } { ~tnSetBox.(\climaxS, (2 * (45 ** v)).round(1)) }
			{ cc == 18 } { ~tnSetBox.(\fade, (0.5 * (60 ** v)).round(0.1)) }
			{ cc == 19 } { ~tnSetBox.(\ringT60, (0.5 * (40 ** v)).round(0.5)); ~tnSetRing.() }
			{ cc == 20 } { ~tnSetBox.(\ringLvl, (-30 + (42 * v)).round(1)); ~tnSetRing.() }
			{ cc == 21 } { ~tnSetBox.(\folWin, (30 ** v).round(0.5).max(1)); ~tnSetFollow.() }
			{ cc == 22 } { ~tnSetBox.(\folDepth, (18 * v).round(1)); ~tnSetFollow.() }
			{ (val > 0) and: { [41, 42, 43, 44, 45, 46, 60, 61].includes(cc) } } { ~tnButton.(cc) } } }).permanent_(true);
	MIDIdef.noteOn(\tnnote, { |vel, note| if (~mkOwner == \tornado) { ~tnButton.(note) } }).permanent_(true);
	"TORNADO_ENGINE_READY".postln;
} };
)
