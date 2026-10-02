/*
tornado_live.scd -- FOLLOW (tab 11, key -): a SET of renders played together (the tornado ending's microtonal sets, or the eight
Rite renders), their balance following the dancers. Jon, 2026-10-02: "raise and lower the volumes of each one, sort of against
the others ... follows the data, but still adds to 1 ... constantly renormalizing, but with a good deal of lag so motion is slow
... the lag could even be controlled by the center 7 one".

THE ENGINE (same maths as rig/sharp/follow_mix/follow_study.py, where it was tested on the 2026-10-01 logs)
  feature x_k per sensor k, 0..1:
    AC activity   RMS of the AC over the last `win` s, divided by that sensor's 95th percentile in the 2026-10-01 run (so each
                  dancer's own range counts, not who has the most sensitive sensor), x sens, clipped     <- RECOMMENDED
    DC pressure   bus DC / its 95th percentile x sens. Note: the hub clips DC at 0 and the hardware sends -0.7..0.9, so live
                  DC loses 18-58 % of the samples; DC also jumps whenever a sensor is re-seated (30-60 times per sensor-hour).
  drive   d_i = floor + x_{sensor of i} ^ contrast        (each render picks its sensor; default render i <- sensor i)
  lag     D_i = Lag(d_i, tau)                              (tau = SC lag time: within 60 dB after tau s; time constant tau/6.9)
  share   w_i = D_i / sum D                                (always sums to 1)
  gain    g_i = sqrt(w_i)  (equal power: loudness stays put while the balance moves)  or  w_i  (equal amplitude)
  tau     fixed, or set by the CENTRAL sensor's activity c: tau = slow x (fast / slow) ^ c   (c 0 = still -> slow;
          'reverse' flips it: busy centre -> slower)
  'off' = every render at 1/N (the plain mix).
On the 2026-10-01 run (63 min): AC activity at 60 s lets the lead pass every ~20 s and the balance drift ~5 % per s; DC at 30 s
sits on whoever presses hardest (one render led 75-96 % of the time in the listening tests). Listening files:
rig/sharp/follow_mix/out/{tornado,rite}_{equal,ACactivity_lag60,ACactivity_lag60to10_by7,DC_lag30}.wav.

SOUND  one synth plays every render off one playhead (no drift). ambiX sets (the tornado) go into the AMBI tab's B-format bus
       with their own spatial image; stereo sets (Rite) are placed around the circle (render i at i x 360/N, a 30-degree pair).
       No AMBI tab: a plain stereo fold-down on outs 1-2.
Display: share bars and readouts redraw 4 times a second at most.
*/
(
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/tornado_live.scd".standardizePath).pathOnly;
var so = here +/+ ".." +/+ "..";
var tor = so +/+ "tornado" +/+ "forann_line" +/+ "out_mic", rh = so +/+ "concatenator-corpus" +/+ "out" +/+ "listen-rite1929half";
var r1 = so +/+ "concatenator-corpus" +/+ "out" +/+ "listen-rite1929";
var rnames = ["everything p10", "harmonium", "aeolian", "voice+breath", "perc", "fry", "whoosh", "everything p20"];
var rfiles = ["mic-everything__X__part1000_pd0.50_t200_p10", "mic-harmonium__X__part1000_pd0.95_t50_p5", "mic-aeolian__X__part1000_pd0.95_t50_p5",
	"mic-voicebreath__X__part1000_pd0.50_t200_p5", "mic-perc__X__part1000_pd0.50_t200_p5", "mic-fry__X__part1000_pd0.50_t200_p5",
	"mic-whoosh__X__part1000_pd0.95_t50_p5", "mic-everything__X__part1000_pd0.50_t200_p20"];
var tsets = ["breath", "sung", "fry", "harmonium", "mixed"];
~fwSets = [
	(name: "tornado, microtonal (5 sets, ambiX, 4 min)", kind: \ambix, labels: tsets, files: tsets.collect { |t| tor +/+ ("forann_mic-" ++ t ++ "_tornado_ambiX.wav") }),
	(name: "rebuilt, microtonal (5 sets, ambiX, 3 min)", kind: \ambix, labels: tsets, files: tsets.collect { |t| tor +/+ ("forann_mic-" ++ t ++ "_rebuilt_ambiX.wav") }),
	(name: "Rite octave down (8 renders, 5 min)", kind: \stereo, labels: rnames, files: rfiles.collect { |f| rh +/+ (f.replace("X", "rite1929half300") ++ "__norm.wav") }),
	(name: "Rite 1x (8 renders, 2.5 min)", kind: \stereo, labels: rnames, files: rfiles.collect { |f| r1 +/+ (f.replace("X", "rite1929first150") ++ "__norm.wav") })
];
// per-sensor 95th percentiles ON THE BUS (DC clipped >= 0, AC clipped +-1) over the 2026-10-01 run, 16:44-17:47
~fwAct95 = [0.83, 0.769, 0.794, 0.732, 0.716, 0.656, 0.557];
~fwDc95 = [0.455, 0.237, 0.546, 0.446, 0.827, 0.707, 1.18];
~fwMax = 8;
~fwOutBus = ~fwOutBus ? 0;
~fwP = ~fwP ? (set: 0, feat: 0, sens: 1, win: 4, floor: 0.05, contrast: 2.5, lag: 60, lag7: true, slow: 60, fast: 10, rev: false,
	norm: 0, master: 0, ambi: true, assign: [0, 1, 2, 3, 4, 5, 0, 1]);
s = Server.default;
s.waitForBoot { fork {
	~fwWin !? { if (~fwWin.isClosed.not) { ~fwWin.onClose = nil; ~fwWin.close } };
	~fwShareSyn !? { ~fwShareSyn.free }; ~fwPlaySyn !? { ~fwPlaySyn.free }; ~fwShareSyn = nil; ~fwPlaySyn = nil;
	~fwBufs !? { ~fwBufs.do(_.free) }; ~fwBufs = nil; OSCdef(\fwMeter).free;
	~fwWBus !? { ~fwWBus.free }; ~fwWBus = Bus.control(s, ~fwMax);
	~fwDummy4 !? { ~fwDummy4.free }; ~fwDummy4 = Bus.audio(s, 4);
	~fwZero !? { ~fwZero.free }; ~fwZero = Bus.control(s, 14).setn(0 ! 14);
	~fwSilent2 !? { ~fwSilent2.free }; ~fwSilent4 !? { ~fwSilent4.free };
	~fwSilent2 = Buffer.alloc(s, 2, 2); ~fwSilent4 = Buffer.alloc(s, 2, 4); s.sync;

	// ---- the share engine: sensors -> 8 gains on a control bus ----
	SynthDef(\fwShare, { |fbus = 0, out = 0, n = 5, feat = 0, sens = 1, win = 4, floor = 0.05, contrast = 2.5, lag = 60,
		lag7 = 1, slow = 60, fast = 10, rev = 0, norm = 0, off = 0|
		var dc = In.kr(fbus, 7), ac = In.kr(fbus + 7, 7), act95 = \act95.kr(~fwAct95), dc95 = \dc95.kr(~fwDc95), assign = \assign.kr(~fwP[\assign]);
		var act = 7.collect { |k| (Lag.kr(ac[k].squared, win).sqrt / act95[k] * sens).clip(0, 1) };
		var pr = 7.collect { |k| (dc[k] / dc95[k] * sens).clip(0, 1) };
		var x = 7.collect { |k| Select.kr(feat, [act[k], pr[k]]) };
		var c = LagUD.kr(act[6], 0.5, 3), cc = Select.kr(rev, [c, 1 - c]);
		var tau = Select.kr(lag7, [lag, slow * ((fast / slow.max(0.01)) ** cc)]).max(0.05);
		var drive = 8.collect { |i| var xi = Select.kr(assign[i].clip(0, 6), x); (floor + (xi ** contrast)) * (i < n) };
		var lagged = drive.collect { |d| Lag.kr(d, tau) };
		var w = lagged / lagged.sum.max(1e-6);
		var w2 = 8.collect { |i| Select.kr(off, [w[i], (i < n) / n.max(1)]) };
		var g = 8.collect { |i| Select.kr(norm, [w2[i].sqrt, w2[i]]) };
		Out.kr(out, g);
		SendReply.kr(Impulse.kr(4), '/fwMeter', w2 ++ [tau, c]);
	}).load(s);
	// ---- players: one playhead, gains from the bus ----
	SynthDef(\fwAmbiX, { |frames = 1, rate = 1, run = 0, t_reset = 0, resetPos = 0, master = 1, wbus = 0, ambi = 0, abus = 0, out = 0|
		var bufs = \bufs.kr(0 ! 8), g = In.kr(wbus, 8);
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos), seam = (ph.min(frames - ph) / (0.01 * SampleRate.ir)).clip(0, 1);
		var x = 8.collect { |i| BufRd.ar(4, bufs[i], ph, 1, 4) * g[i].lag(0.05) }.sum * seam * master.lag(0.1);
		var bf = [x[0] * 0.5.sqrt, x[3], x[1], x[2]];                // ambiX (W Y Z X, SN3D) -> ATK B-format (W X Y Z)
		Out.ar(abus, bf * ambi.lag(0.05));
		Out.ar(out, [bf[0] * 2.sqrt + bf[2], bf[0] * 2.sqrt - bf[2]] * 0.5 * (1 - ambi).lag(0.05));   // fold-down: W +- Y
		SendReply.kr(Impulse.kr(4), '/fwPos', A2K.kr(ph));
	}).load(s);
	SynthDef(\fwStereo, { |frames = 1, rate = 1, run = 0, t_reset = 0, resetPos = 0, master = 1, wbus = 0, ambi = 0, abus = 0, out = 0, n = 8|
		var bufs = \bufs.kr(0 ! 8), g = In.kr(wbus, 8), half = 15.degrad;
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos), seam = (ph.min(frames - ph) / (0.01 * SampleRate.ir)).clip(0, 1);
		var r = 8.collect { |i| BufRd.ar(2, bufs[i], ph, 1, 4) * g[i].lag(0.05) * seam };
		var bf = r.collect { |y, i| var az = (i * -2pi / n.max(1)); FoaPanB.ar(y[0], az + half, 0) + FoaPanB.ar(y[1], az - half, 0) }.sum;
		Out.ar(abus, bf * master.lag(0.1) * ambi.lag(0.05));
		Out.ar(out, r.sum * master.lag(0.1) * (1 - ambi).lag(0.05));
		SendReply.kr(Impulse.kr(4), '/fwPos', A2K.kr(ph));
	}).load(s);
	s.sync;

	~fwShareArgs = { [\n, ~fwN ? 5, \feat, ~fwP[\feat], \sens, ~fwP[\sens], \win, ~fwP[\win], \floor, ~fwP[\floor], \contrast, ~fwP[\contrast],
		\lag, ~fwP[\lag], \lag7, ~fwP[\lag7].asInteger, \slow, ~fwP[\slow], \fast, ~fwP[\fast], \rev, ~fwP[\rev].asInteger,
		\norm, ~fwP[\norm].min(1), \off, (~fwP[\norm] == 2).asInteger, \assign, ~fwP[\assign]] };
	~fwShareSyn = Synth.head(s, \fwShare, [\fbus, (~fhBus !? (_.index)) ? ~fwZero.index, \out, ~fwWBus.index] ++ ~fwShareArgs.());
	~fwSetShare = { ~fwShareSyn !? { ~fwShareSyn.set(*~fwShareArgs.()) } };
	~fwFbus = { ~fwShareSyn.set(\fbus, (~fhBus !? (_.index)) ? ~fwZero.index) };
	~fwPlaying = false; ~fwN = 0;
	~fwSetAmbi = { |on| var a = on and: { ~ambiBus.notNil }; ~fwP[\ambi] = on;
		~fwPlaySyn !? { ~fwPlaySyn.set(\ambi, a.asInteger, \abus, if (a) { ~ambiBus.index } { ~fwDummy4.index }) };
		if (on and: { ~ambiBus.isNil }) { "follow: AMBI needs the AMBI tab (dev/ambi.scd); playing a stereo fold-down".warn } };
	~fwLoad = { |si| fork {
		var set = ~fwSets[si], ok = set[\files].select { |f| File.exists(f) }, old = ~fwBufs, oldSyn = ~fwPlaySyn, was = ~fwPlaying;
		if (ok.size < set[\files].size) { ("follow: missing " ++ (set[\files].size - ok.size) ++ " of " ++ set[\files].size ++ " files").warn };
		~fwBufs = set[\files].collect { |f| if (File.exists(f)) { Buffer.read(s, f) } }; s.sync;
		~fwKind = set[\kind]; ~fwN = set[\files].size; ~fwLabels = set[\labels];
		~fwFrames = ~fwBufs.select(_.notNil).collect(_.numFrames).minItem ? 1; ~fwSR = ~fwBufs.detect(_.notNil) !? (_.sampleRate) ? 44100;
		~fwPlaySyn = Synth.after(~fwShareSyn, if (~fwKind == \ambix) { \fwAmbiX } { \fwStereo },
			[\bufs, ~fwBufs.collect { |b| b !? (_.bufnum) ? (if (~fwKind == \ambix) { ~fwSilent4 } { ~fwSilent2 }).bufnum }
				++ ((if (~fwKind == \ambix) { ~fwSilent4 } { ~fwSilent2 }).bufnum ! (~fwMax - ~fwN)),
			\frames, ~fwFrames.max(1), \rate, ~fwSR / s.sampleRate, \run, was.asInteger, \wbus, ~fwWBus.index, \n, ~fwN,
			\master, ~fwP[\master].dbamp, \out, ~fwOutBus, \ambi, 0, \abus, ~fwDummy4.index]);
		oldSyn !? { oldSyn.free }; ~fwSetAmbi.(~fwP[\ambi]); ~fwSetShare.();
		old !? { 0.5.wait; old.do { |b| b !? { b.free } } };
		("follow: " ++ set[\name] ++ " loaded (" ++ ok.size ++ " files, " ++ (~fwFrames / ~fwSR).round(0.1) ++ " s)").postln;
		{ ~fwInfo.string_(set[\name] ++ ": " ++ ok.size ++ " files, " ++ (~fwFrames / ~fwSR).round(0.1) ++ " s"); ~fwRelabel.() }.defer } };

	// ---- GUI ----
	{
		var nb = { |key, lo, hi, step, dec, w = 52| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec)
			.value_(~fwP[key]).fixedWidth_(w).action_({ |b| ~fwP[key] = b.value; ~fwSetShare.() }) };
		~fwWin = if (~stHost.notNil) { ~stHost.(\follow) } { Window("FOLLOW -- renders balanced by the dancers", Rect(90, 60, 980, 620)).front };
		~uiPending = ~uiPending ? IdentityDictionary.new; ~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
		if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
			~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
		~fwSetMenu = PopUpMenu().items_(~fwSets.collect(_[\name])).value_(~fwP[\set]).fixedWidth_(320).action_({ |m| ~fwP[\set] = m.value; ~fwLoad.(m.value) });
		~fwInfo = StaticText().string_("loading ...");
		~fwPlayBtn = Button().states_([["PLAY", Color.black, Color.green(0.8)], ["STOP", Color.white, Color.red(0.7)]]).fixedWidth_(90)
			.action_({ |b| ~fwPlaying = b.value == 1; ~fwPlaySyn !? { ~fwPlaySyn.set(\run, b.value) } });
		~fwTop = Button().states_([["|< start"]]).fixedWidth_(70).action_({ ~fwPlaySyn !? { ~fwPlaySyn.set(\resetPos, 0, \t_reset, 1) } });
		~fwPos = Slider().orientation_(\horizontal).action_({ |sl| ~fwPlaySyn !? { ~fwPlaySyn.set(\resetPos, sl.value * ~fwFrames.max(1), \t_reset, 1) } });
		~fwTime = StaticText().string_("0:00").fixedWidth_(50);
		~fwFeat = PopUpMenu().items_(["AC activity (motion; recommended)", "DC pressure"]).value_(~fwP[\feat]).fixedWidth_(240)
			.action_({ |m| ~fwP[\feat] = m.value; ~fwSetShare.() });
		~fwNorm = PopUpMenu().items_(["sum to 1, equal power", "sum to 1, equal amplitude", "OFF: plain mix (1/N each)"]).value_(~fwP[\norm]).fixedWidth_(220)
			.action_({ |m| ~fwP[\norm] = m.value; ~fwSetShare.() });
		~fwLag7 = CheckBox().string_("CENTRAL (7) sets the lag").value_(~fwP[\lag7]).action_({ |c| ~fwP[\lag7] = c.value; ~fwSetShare.() });
		~fwRev = CheckBox().string_("reverse (busy centre = slower)").value_(~fwP[\rev]).action_({ |c| ~fwP[\rev] = c.value; ~fwSetShare.() });
		~fwAmbiBox = CheckBox().string_("AMBI").value_(~fwP[\ambi]).action_({ |c| ~fwSetAmbi.(c.value) });
		~fwBars = { LevelIndicator().fixedWidth_(46).fixedHeight_(120).drawsPeak_(false) } ! ~fwMax;
		~fwShareTxt = { StaticText().string_("").fixedWidth_(46).align_(\center).font_(Font.sansSerif(10)) } ! ~fwMax;
		~fwNameTxt = { StaticText().string_("").fixedWidth_(46).align_(\center).font_(Font.sansSerif(9)) } ! ~fwMax;
		~fwAssign = ~fwMax.collect { |i| PopUpMenu().items_(["s1", "s2", "s3", "s4", "s5", "s6", "s7"]).value_(~fwP[\assign][i]).fixedWidth_(46)
			.action_({ |m| ~fwP[\assign][i] = m.value; ~fwSetShare.() }) };
		~fwTauTxt = StaticText().string_("lag --").fixedWidth_(260);
		~fwRelabel = { ~fwMax.do { |i| var on = i < ~fwN;
			~fwNameTxt[i].string_(if (on) { (~fwLabels[i] ? "").keep(8) } { "" }); ~fwAssign[i].visible_(on); ~fwBars[i].visible_(on); ~fwShareTxt[i].visible_(on) } };
		~fwWin.layout = VLayout(
			HLayout(StaticText().string_("set"), ~fwSetMenu, ~fwInfo, nil),
			HLayout(~fwPlayBtn, ~fwTop, ~fwPos, ~fwTime),
			HLayout(StaticText().string_("follow"), ~fwFeat, StaticText().string_("sens"), nb.(\sens, 0, 10, 0.1, 1),
				StaticText().string_("activity window s"), nb.(\win, 0.5, 30, 0.5, 1), ~fwNorm, nil),
			HLayout(StaticText().string_("floor"), nb.(\floor, 0, 1, 0.01, 2), StaticText().string_("contrast"), nb.(\contrast, 0.5, 6, 0.1, 1),
				StaticText().string_("lag s (60 dB)"), nb.(\lag, 0.5, 300, 1, 0), ~fwLag7, StaticText().string_("still"), nb.(\slow, 1, 300, 1, 0),
				StaticText().string_("busy"), nb.(\fast, 0.5, 300, 1, 0), ~fwRev, nil),
			HLayout(StaticText().string_("master dB"), NumberBox().clipLo_(-40).clipHi_(12).value_(~fwP[\master]).fixedWidth_(52)
				.action_({ |b| ~fwP[\master] = b.value; ~fwPlaySyn !? { ~fwPlaySyn.set(\master, b.value.dbamp) } }), ~fwAmbiBox, ~fwTauTxt, nil),
			HLayout(*(~fwMax.collect { |i| VLayout(~fwBars[i], ~fwShareTxt[i], ~fwNameTxt[i], ~fwAssign[i]) } ++ [nil])),
			StaticText().string_("bars = each render's share (all shares add to 1).  sN under a bar = the sensor it follows (s7 = central)."),
			nil);
		OSCdef(\fwMeter, { |msg| var v = msg[3..]; ~uiLater.(\fwMeter, {
			~fwN.do { |i| ~fwBars[i].value = (v[i] ? 0) * ~fwN.max(1) / 2; ~fwShareTxt[i].string = ((v[i] ? 0) * 100).round.asInteger.asString ++ "%" };
			~fwTauTxt.string = "lag now " ++ (v[~fwMax] ? 0).round(0.1) ++ " s   centre activity " ++ ((v[~fwMax + 1] ? 0) * 100).round.asInteger ++ "%" }) }, '/fwMeter', s.addr);
		OSCdef(\fwPos, { |msg| ~uiLater.(\fwPos, { ~fwPos.value = msg[3] / ~fwFrames.max(1); ~fwTime.string = (msg[3] / ~fwSR.max(1)).asTimeString.drop(3).keep(5) }) }, '/fwPos', s.addr);
		~fwWin.onClose = { ~fwShareSyn !? { ~fwShareSyn.free }; ~fwPlaySyn !? { ~fwPlaySyn.free }; ~fwShareSyn = nil; ~fwPlaySyn = nil;
			~fwBufs !? { ~fwBufs.do { |b| b !? { b.free } } }; ~fwBufs = nil; OSCdef(\fwMeter).free; OSCdef(\fwPos).free };
		~fwRelabel.();
		~fwLoad.(~fwP[\set]);
	}.defer;
	"FOLLOW_LIVE_READY".postln;
} };
)
