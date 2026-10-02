/*
stems_live.scd -- SOLO: the octave-down Rite "everything p20" (Jon's pick for the opening, 2026-10-02) split into its particles,
each particle a point in the ambisonic circle, the dancer's motion deciding how loud each one is.

Stems come from concatenator-corpus/cluster_jobs/musaic_stems.py (a seeded re-run of the same render, rebuilt as stems that sum
exactly to the mix), fetched to concatenator-corpus/out/stems/<take>/ and mixed to mono in <set>/mono/ (fetch_stems.sh):
  lanes       the 20 simultaneous activations followed as continuous lanes (a lane keeps playing on through its corpus file
              until the filter jumps; then the jump starts in the lane free longest)
  source      notes / harmonium / breath / voice / fry / perc          performer   anna / grisha / raymond / sora / josh / other
ONE synth plays every stem off one playhead (they cannot drift); with every stem at full level the sum IS the original mix.

POSITIONS  even around the circle (stem i at i x 360/N, clockwise from the front) or a random scatter (RE-ROLL). Fixed: no
           rotation (Jon: rotation gives people headaches). AMBI on = into the AMBI tab's B-format bus; off = stereo on outs 1-2.
MOTION -> LEVEL (force hub buses; AC = motion, signed, rests at 0; DC = pressure 0..~0.8)
  all on      every stem at full level (= the mix)
  tiled       sensor k drives stems k, k+7, k+14 (sensors 1-7; 7 = central), like the breath faders
  density     overall motion (mean of the 7 AC envelopes) decides HOW MANY stems sound: still = only the first `min` (a fixed
              random order), more motion = more join, one at a time with a crossfade
  sensor curve: env = lag(|AC| x sens) with separate rise / fall times, clipped to 0..1; DC mode uses DC x sens instead.
  floor dB: the level a stem never drops below (-60 = can go silent).
Display: the meters redraw 4 times a second at most.
*/
(
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/stems_live.scd".standardizePath).pathOnly;
~soRoot = here +/+ ".." +/+ ".." +/+ "concatenator-corpus" +/+ "out" +/+ "stems";
~soMax = 20;
~soOutBus = ~soOutBus ? 0;
~soP = ~soP ? (set: 0, mode: 0, src: 0, sens: 1.5, rise: 0.15, fall: 1.5, floorDb: -60, minN: 2, master: 0, ambi: true, scatter: false, seed: 1);
s = Server.default;
s.waitForBoot { fork {
	// ---- tear down a previous evaluation ----
	{ ~soWin !? { if (~soWin.isClosed.not) { ~soWin.onClose = nil; ~soWin.close } } }.defer;   // Qt only on the GUI thread (a reload ran this in the boot routine)
	~soSyn !? { ~soSyn.free }; ~soSyn = nil; ~soBufs !? { ~soBufs.do { |b| b !? { b.free } } }; ~soBufs = nil;
	OSCdef(\soMeter).free;
	~soDummy4 !? { ~soDummy4.free }; ~soDummy4 = Bus.audio(s, 4);
	~soSilent !? { ~soSilent.free }; ~soSilent = Buffer.alloc(s, 2, 1); s.sync;

	SynthDef(\soStems, { |frames = 1, rate = 1, run = 0, t_reset = 0, resetPos = 0, master = 1, mlag = 0.1, n = 20, ambi = 0, abus = 0, out = 0,
		fbus = 0, mode = 0, src = 0, sens = 5, rise = 0.15, fall = 1.5, floor = 0, minN = 2|
		var bufs = \bufs.kr(0 ! 20), az = \az.kr(0 ! 20), rank = \rank.kr((0..19));
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos);
		var seam = (ph.min(frames - ph) / (0.01 * SampleRate.ir)).clip(0, 1);
		var dc = In.kr(fbus, 7), ac = In.kr(fbus + 7, 7);
		var env = Select.kr(src, [ac.abs, dc]).collect { |x| LagUD.kr((x * sens).clip(0, 1), rise, fall) };
		var dens = minN + (env.sum / 7 * (n - minN));      // how many stems sound
		var m = 20.collect { |i| var on = (i < n);
			Lag.kr(Select.kr(mode, [1, env[i % 7], (dens - rank[i]).clip(0, 1)]), 0.08) * on };
		var g = m.collect { |x| floor + ((1 - floor) * x) };
		var sig = 20.collect { |i| BufRd.ar(1, bufs[i], ph, 1, 4) * seam * g[i] };
		var st = sig.collect { |x, i| Pan2.ar(x, az[i].sin.neg) }.sum;   // az + = left (ATK), Pan2 + = right
		var bf = sig.collect { |x, i| FoaPanB.ar(x, az[i], 0) }.sum;
		SendReply.kr(Impulse.kr(4), '/soMeter', g ++ [A2K.kr(ph)]);
		Out.ar(out, st * VarLag.kr(master, mlag, warp: \sin) * (1 - ambi).lag(0.05));
		Out.ar(abus, bf * VarLag.kr(master, mlag, warp: \sin) * ambi.lag(0.05));
	}).load(s);   // .load, not .add: keeps it off the metro server (see rite_live.scd, 2026-10-02)
	s.sync;

	~soTakes = { (PathName(~soRoot).folders.collect(_.folderName)).sort };
	~soSetNames = ["lanes", "source", "performer"];
	~soFiles = { |take, set| (PathName(~soRoot +/+ take +/+ set +/+ "mono").files.select { |f| f.extension == "wav" }
		.collect(_.fullPath)).sort.keep(~soMax) };
	~soPositions = { var nn = ~soNames.size.max(1);
		if (~soP[\scatter]) { thisThread.randSeed = ~soP[\seed]; { 2pi.rand } ! ~soMax } { ~soMax.collect { |i| (i * -2pi / nn) } } };
	~soRank = { thisThread.randSeed = ~soP[\seed] + 1000; (0..(~soMax - 1)).scramble.order };   // rank of stem i in the density order
	~soApply = { ~soSyn !? { ~soSyn.set(\az, ~soPositions.(), \rank, ~soRank.(), \n, ~soNames.size) } };
	~soLoad = { |take, set| fork {
		var fs = ~soFiles.(take, set), old = ~soBufs, was = ~soPlaying;
		~soSyn !? { ~soSyn.set(\run, 0) };
		~soBufs = fs.collect { |f| Buffer.read(s, f) }; s.sync;
		~soNames = fs.collect { |f| PathName(f).fileNameWithoutExtension };
		~soFrames = ~soBufs.collect(_.numFrames).minItem ? 1; ~soSR = ~soBufs.first !? (_.sampleRate) ? 44100;
		~soDur = ~soFrames / ~soSR;
		~soSyn.set(\bufs, ~soBufs.collect(_.bufnum) ++ (~soSilent.bufnum ! (~soMax - ~soBufs.size)), \frames, ~soFrames.max(1),
			\rate, ~soSR / s.sampleRate);
		~soApply.();
		old !? { 1.wait; old.do(_.free) };
		if (was == true) { ~soSyn.set(\run, 1) };
		("stems: " ++ take ++ " / " ++ set ++ ": " ++ fs.size ++ " stems, " ++ ~soDur.round(0.1) ++ " s").postln;
		{ ~soInfo.string_(take ++ " / " ++ set ++ ": " ++ fs.size ++ " stems, " ++ ~soDur.round(0.1) ++ " s"); ~soLabel.() }.defer } };

	~soSyn = Synth.head(s, \soStems, [\bufs, ~soSilent.bufnum ! ~soMax, \frames, 1, \run, 0, \out, ~soOutBus,
		\fbus, (~fhBus !? (_.index)) ? 0, \ambi, 0, \abus, ~soDummy4.index, \master, ~soP[\master].dbamp, \mode, ~soP[\mode], \src, ~soP[\src],
		\sens, ~soP[\sens], \rise, ~soP[\rise], \fall, ~soP[\fall], \floor, ~soP[\floorDb].dbamp * (~soP[\floorDb] > -60).asInteger, \minN, ~soP[\minN]]);
	// at the HEAD (2026-10-02): the AMBI tab decodes in a group at the tail; a writer after it would never be heard
	~soPlaying = false; ~soNames = [];
	~soSetAmbi = { |on| var a = on and: { ~ambiBus.notNil }; ~soP[\ambi] = on;
		~soSyn.set(\ambi, a.asInteger, \abus, if (a) { ~ambiBus.index } { ~soDummy4.index });
		if (on and: { ~ambiBus.isNil }) { "stems: AMBI needs the AMBI tab (dev/ambi.scd)".warn } };
	~soFbus = { ~soSyn.set(\fbus, (~fhBus !? (_.index)) ? 0) };   // the force hub may load after this tab

	// ---- GUI ----
	{
		var takes = ~soTakes.(), nb;
		~soWin = if (~stHost.notNil) { ~stHost.(\solo) } { Window("SOLO -- Rite everything p20 as particles", Rect(80, 60, 900, 640)).front };
		// the shared 4-per-second display routine (breath36 / ambi start the same one)
		~uiPending = ~uiPending ? IdentityDictionary.new; ~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
		if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
			~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
		~soTake = PopUpMenu().items_(if (takes.isEmpty) { ["(no takes yet in out/stems/)"] } { takes }).fixedWidth_(260);
		~soSet = PopUpMenu().items_(~soSetNames).value_(~soP[\set]).fixedWidth_(110);
		~soLoadBtn = Button().states_([["load"]]).fixedWidth_(60).action_({ var t = ~soTakes.();
			~soTake.items_(if (t.isEmpty) { ["(no takes yet in out/stems/)"] } { t });
			if (t.notEmpty) { ~soLoad.(t[~soTake.value.min(t.size - 1)], ~soSetNames[~soSet.value]) } });
		~soTake.action_({ ~soLoadBtn.doAction }); ~soSet.action_({ |m| ~soP[\set] = m.value; ~soLoadBtn.doAction });
		~soInfo = StaticText().string_("no stems loaded");
		~soPlayBtn = Button().states_([["PLAY", Color.black, Color.green(0.8)], ["STOP", Color.white, Color.red(0.7)]]).fixedWidth_(90)
			.action_({ |b| ~soPlaying = b.value == 1; ~soSyn.set(\run, b.value) });
		~soTop = Button().states_([["|< start"]]).fixedWidth_(70).action_({ ~soSyn.set(\resetPos, 0, \t_reset, 1) });
		~soPos = Slider().orientation_(\horizontal).action_({ |sl| ~soSyn.set(\resetPos, sl.value * ~soFrames.max(1), \t_reset, 1) });
		~soTime = StaticText().string_("0:00").fixedWidth_(50);
		nb = { |key, lo, hi, step, dec, fn| NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec)
			.value_(~soP[key]).fixedWidth_(52).action_({ |b| ~soP[key] = b.value; fn.(b.value) }) };
		// MASTER fader + FADE IN / FADE OUT (2026-10-02): p -> amp 2 p^2 (0.707 = 0 dB); fades glide on the server, the fader stays put
		~soToAmp = { |p| 2 * p.squared }; ~soToPos = { |a| (a / 2).max(0).sqrt.min(1) };
		~soDbStr = { |a| if (a < 0.0001) { "off" } { (a.ampdb.round(0.5)).asString ++ " dB" } };
		~soFaderAmp = ~soP[\master].dbamp; ~soFadeS = ~soFadeS ? 8;
		~soSetMaster = { |amp, lag = 0.1| ~soSyn !? { ~soSyn.set(\mlag, lag, \master, amp) } };
		~soMasterTxt = StaticText().string_(~soDbStr.(~soFaderAmp)).fixedWidth_(64); ~soFadeTxt = StaticText().string_("").fixedWidth_(170);
		~soFader = Slider().orientation_(\horizontal).fixedHeight_(28).value_(~soToPos.(~soFaderAmp)).action_({ |sl|
			~soFaderAmp = ~soToAmp.(sl.value); ~soP[\master] = ~soFaderAmp.max(0.00001).ampdb; ~soSetMaster.(~soFaderAmp);
			~uiLater.(\soMaster, { ~soMasterTxt.string = ~soDbStr.(~soFaderAmp); ~soFadeTxt.string = "" }) });
		~soFadeNb = NumberBox().clipLo_(0.1).clipHi_(120).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~soFadeS).fixedWidth_(48).action_({ |b| ~soFadeS = b.value });
		~soFadeIn = Button().states_([["FADE IN", Color.black, Color.green(0.8)]]).fixedWidth_(80).action_({
			~soSetMaster.(~soFaderAmp, ~soFadeS); ~soFadeTxt.string = "fading in over " ++ ~soFadeS ++ " s" });
		~soFadeOut = Button().states_([["FADE OUT", Color.white, Color.red(0.6)]]).fixedWidth_(80).action_({
			~soSetMaster.(0, ~soFadeS); ~soFadeTxt.string = "fading out over " ++ ~soFadeS ++ " s" });
		~soMode = PopUpMenu().items_(["all on (= the mix)", "tiled: sensor k -> stems k, k+7, k+14", "density: motion -> how many sound"])
			.value_(~soP[\mode]).fixedWidth_(260).action_({ |m| ~soP[\mode] = m.value; ~soSyn.set(\mode, m.value) });
		~soSrc = PopUpMenu().items_(["AC (motion)", "DC (pressure)"]).value_(~soP[\src]).fixedWidth_(120)
			.action_({ |m| ~soP[\src] = m.value; ~soSyn.set(\src, m.value) });
		~soAmbiBox = CheckBox().string_("AMBI").value_(~soP[\ambi]).action_({ |c| ~soSetAmbi.(c.value) });
		~soScatter = PopUpMenu().items_(["even circle", "random scatter"]).value_(~soP[\scatter].asInteger).fixedWidth_(130)
			.action_({ |m| ~soP[\scatter] = m.value == 1; ~soApply.(); ~soLabel.() });
		~soReroll = Button().states_([["RE-ROLL"]]).fixedWidth_(80).action_({ ~soP[\seed] = 100000.rand; ~soApply.(); ~soLabel.() });
		~soMeters = { LevelIndicator().fixedWidth_(28).fixedHeight_(110).drawsPeak_(false) } ! ~soMax;
		~soNameTexts = { StaticText().string_("").font_(Font.sansSerif(9)).fixedWidth_(28).align_(\center) } ! ~soMax;
		~soAzTexts = { StaticText().string_("").font_(Font.sansSerif(9)).fixedWidth_(28).align_(\center) } ! ~soMax;
		~soLabel = { ~soMax.do { |i| var nm = ~soNames[i], az = ~soPositions.()[i];
			~soNameTexts[i].string_(nm !? { nm.replace("lane_", "").keep(5) } ? "");
			~soAzTexts[i].string_(if (nm.notNil) { (az.raddeg.neg.wrap(0, 360)).round.asInteger.asString ++ "°" } { "" }) } };
		~soWin.layout = VLayout(
			HLayout(StaticText().string_("take"), ~soTake, StaticText().string_("stems"), ~soSet, ~soLoadBtn, ~soInfo, nil),
			HLayout(~soPlayBtn, ~soTop, ~soPos, ~soTime),
			HLayout(StaticText().string_("MASTER"), ~soFader, ~soMasterTxt, StaticText().string_("fade s"), ~soFadeNb, ~soFadeIn, ~soFadeOut, ~soFadeTxt),
			HLayout(
				~soAmbiBox, StaticText().string_("positions"), ~soScatter, ~soReroll, nil),
			HLayout(StaticText().string_("motion -> level"), ~soMode, ~soSrc, StaticText().string_("sens"),
				nb.(\sens, 0, 40, 0.5, 1, { |v| ~soSyn.set(\sens, v) }), nil),
			HLayout(StaticText().string_("rise s"), nb.(\rise, 0, 5, 0.05, 2, { |v| ~soSyn.set(\rise, v) }),
				StaticText().string_("fall s"), nb.(\fall, 0, 10, 0.1, 1, { |v| ~soSyn.set(\fall, v) }),
				StaticText().string_("floor dB"), nb.(\floorDb, -60, 0, 1, 0, { |v| ~soSyn.set(\floor, if (v <= -60) { 0 } { v.dbamp }) }),
				StaticText().string_("density: min stems"), nb.(\minN, 0, 20, 1, 0, { |v| ~soSyn.set(\minN, v) }), nil),
			HLayout(*(~soMax.collect { |i| VLayout(~soMeters[i], ~soNameTexts[i], ~soAzTexts[i]) } ++ [nil])),
			StaticText().string_("meters: each stem's level after the motion mapping (1 = as in the mix). Names: lane number or stem; ° = where it sits, clockwise from the front."),
			nil);
		OSCdef(\soMeter, { |msg| var v = msg[3..]; ~uiLater.(\soMeter, {
			~soMax.do { |i| ~soMeters[i].value = v[i] ? 0 };
			~soPos.value = (v[~soMax] ? 0) / ~soFrames.max(1);
			~soTime.string_(((v[~soMax] ? 0) / ~soSR.max(1)).asTimeString.drop(3).keep(5)) }) }, '/soMeter', s.addr);
		~soWin.onClose = { ~soSyn !? { ~soSyn.free }; ~soSyn = nil; ~soBufs !? { ~soBufs.do(_.free) }; ~soBufs = nil; OSCdef(\soMeter).free };
		~soLabel.();
		if (takes.notEmpty) { ~soLoadBtn.doAction };
		~soSetAmbi.(~soP[\ambi]);
	}.defer;
	"STEMS_LIVE_READY".postln;
} };
)
