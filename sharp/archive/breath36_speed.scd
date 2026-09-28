/*
breath36_speed.scd -- a stepped SPEED axis for the 36 breaths. Open breath36.scd FIRST, then
select all + evaluate here (re-evaluating is safe).

Material: breath36_voices/speed/<voice>_slotN_x<L>.wav -- each voice's 8 morph steps re-rendered
through the Stable Audio 3 autoencoder with the latent sequence time-warped (sharp/render_speed_axis.py):
levels 1.5x 2x 3x 4x, local speed wandering around the level in irregular nCVI segments, the same
warp for all 8 steps of a voice. Level 1x = breath36's own buffers.

Control: one slider 1x .. 4x. Each voice sits on a discrete level = round(slider + its own offset);
no voice is ever a blend of two speeds. When the slider moves, voices switch one at a time (random
stagger) with a short fade. "spread" widens the per-voice offsets (0 = all voices on the same level).
Morph, ALL, voice count and volume in the breath36 window keep working across levels.
API for the force layer: ~spSetLevel.(i, level)  (level 0..4 = 1x 1.5x 2x 3x 4x), ~spSetAll.(x).
Closing this window returns every voice to 1x and frees the speed buffers.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
if (~b36Synths.isNil or: { ~b36Bufs.isNil }) { "breath36_speed: open breath36.scd first".warn } {
var nv = ~b36Bufs.size, ns = ~b36Bufs[0].size, dir = ~b36Dir +/+ "speed", meta = ~b36Meta, origMorph, origCount, origAmp;
// ---- tear down an earlier evaluation ourselves (its close handler may be the buggy one) ----
~spOrig !? { origMorph = ~spOrig[\setMorph] ? ~spOrig[\morph]; origCount = ~spOrig[\set] ? ~spOrig[\count]; origAmp = ~spOrig[\setAmp] ? ~spOrig[\amp] };
~spWin !? { if (~spWin.isClosed.not) { ~spWin.onClose = nil; ~spWin.close } };
~spRout !? { ~spRout.stop };
~spSynths !? { ~spSynths.do { |sets| sets.drop(1).do { |sy| sy !? { sy.free } } } };
~spBufs !? { ~spBufs.do { |sets| sets.drop(1).do { |bs| bs !? { bs.do(_.free) } } } };
origMorph !? { ~b36SetMorph = origMorph }; origCount !? { ~b36Set = origCount }; origAmp !? { ~b36SetAmp = origAmp };
~spOrig = nil; ~spSynths = nil; ~spBufs = nil;
~b36Set.(~b36N);                                   // level-1 voices back on for the current count
~spLevels = ~spLevels ? [1.5, 2, 3, 4];            // set a subset before evaluating to save RAM (~3.5 GB per level)
~spP = (x: 0, spread: 0.5, fade: 0.4, stagger: 1.5);
s.waitForBoot {
	var names = [1] ++ ~spLevels;
	// per voice: [level-1 (breath36's), level-1.5, 2, 3, 4] buffer sets; missing renders -> nil (voice stays below)
	~spBufs = nv.collect { |i|
		[~b36Bufs[i]] ++ ~spLevels.collect { |lv|
			var files = meta["voices"][i]["files"].collect { |f| dir +/+ (f.splitext[0] ++ "_x" ++ lv.asString ++ ".wav") };
			if (files.every { |p| File.exists(p) }) { files.collect { |p| Buffer.read(s, p) } } { nil };
		};
	};
	s.sync;
	~spAvail = ~spBufs.collect { |sets| sets.detectIndex(_.isNil) ? sets.size };   // number of usable levels per voice
	("breath36_speed: levels loaded per voice: " ++ ~spAvail.asString).postln;
	~spSynths = nv.collect { |i|
		[~b36Synths[i]] ++ (1..(~spLevels.size)).collect { |k|
			if (~spBufs[i][k].notNil) {
				Synth(\b36Voice, [\bufs, ~spBufs[i][k].collect(_.bufnum), \on, 0, \fade, 0,
					\modbus, ~b36Silent.index, \modamt, 0, \pan, ~b36Pan[i], \amp, ~b36Amp,
					\comp, ~b36CompFor.(~b36N), \morph, ~b36Morph[i], \glide, ~b36Glide]).run(false);
			} { nil };
		};
	};
	~spLevel = 0 ! nv;
	~spOffset = 0 ! nv;
	~spRollOffsets = { |sp| thisThread.randSeed = 4242; ~spOffset = nv.collect { sp.rand2 } };
	~spRollOffsets.(~spP.spread);

	// switch one voice to a level (index into names): fade the old out, the new in; pause the old afterwards
	~spSetLevel = { |i, k, fade|
		var old = ~spLevel[i], f = fade ? ~spP.fade;
		k = k.round.asInteger.clip(0, ~spAvail[i] - 1);
		if (k != old) {
			var oldSy = ~spSynths[i][old], newSy = ~spSynths[i][k];
			~spLevel[i] = k;
			newSy.run(true); newSy.set(\morph, ~b36Morph[i], \fade, f, \on, (i < ~b36N).asInteger);
			oldSy.set(\fade, f, \on, 0);
			if (old > 0) { SystemClock.sched(f + 0.1, { if (~spLevel[i] != old) { oldSy.run(false) } }) };
			~spDirty = true;
		};
	};
	~spSetAll = { |x, stagger|
		~spP.x = x;
		nv.do { |i| var k = (x + ~spOffset[i]).round.asInteger;
			SystemClock.sched((stagger ? ~spP.stagger).rand, { ~spSetLevel.(i, k) }) };
	};

	// hook breath36's controls so morph / voice count / level reach every level's synth
	// keep breath36's originals under explicit keys (an Event answers .set/.setMorph itself -- never use dot access here)
	if (~spOrig.isNil) { ~spOrig = IdentityDictionary[\morph -> ~b36SetMorph, \count -> ~b36Set, \amp -> ~b36SetAmp] };
	~b36SetMorph = { |i, v| ~spOrig[\morph].(i, v);
		~spSynths[i].drop(1).do { |sy| sy !? { sy.set(\glide, ~b36Glide, \morph, ~b36Morph[i]) } } };
	~b36Set = { |n| ~spOrig[\count].(n);      // sets level-1 synths' on/comp; now route "on" to the active level
		nv.do { |i| var k = ~spLevel[i];
			~spSynths[i].do { |sy, kk| sy !? { sy.set(\fade, ~b36Fade, \comp, ~b36CompFor.(~b36N), \on, ((i < ~b36N) and: { kk == k }).asInteger) } } } };
	~b36SetAmp = { |a| ~spOrig[\amp].(a); ~spSynths.flat.do { |sy| sy !? { sy.set(\amp, ~b36Amp) } } };

	// ---------------- GUI ----------------
	~spWin = Window("breath speed (latent time-warp)", Rect(1160, 420, 620, 300)).front;
	~spText = StaticText().string_("1x").align_(\center).font_(Font.default.size_(40).boldVariant);
	~spSlider = Slider().orientation_(\horizontal).fixedHeight_(48).step_(0.01).value_(0)
		.action_({ |sl| var x = sl.value * (names.size - 1); ~spSetAll.(x);
			~spText.string = names[x.round.asInteger].asString ++ "x   (" ++ x.round(0.01).asString ++ ")" });
	~spSpread = Slider().orientation_(\horizontal).fixedHeight_(22).value_(~spP.spread / 1.5)
		.action_({ |sl| ~spP.spread = sl.value * 1.5; ~spRollOffsets.(~spP.spread); ~spSetAll.(~spP.x) });
	~spFadeBox = NumberBox().clipLo_(0.05).clipHi_(10).step_(0.05).scroll_step_(0.05).decimals_(2).value_(~spP.fade).fixedWidth_(60)
		.action_({ |nb| ~spP.fade = nb.value });
	~spStagBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~spP.stagger).fixedWidth_(60)
		.action_({ |nb| ~spP.stagger = nb.value });
	~spRollBtn = Button().states_([["re-roll offsets"]]).action_({ thisThread.randSeed = Date.getDate.rawSeconds.asInteger;
		~spOffset = nv.collect { ~spP.spread.rand2 }; ~spSetAll.(~spP.x) });
	~spLvlText = nv.collect { StaticText().align_(\center).fixedWidth_(28).string_("1") };
	~spWin.layout = VLayout(
		~spText, ~spSlider,
		HLayout(*(names.collect { |n| StaticText().string_(n.asString ++ "x").align_(\center) })),
		HLayout(StaticText().string_("per-voice spread (steps, 0 .. 1.5)").fixedWidth_(220), ~spSpread, ~spRollBtn),
		HLayout(StaticText().string_("switch fade (s)"), ~spFadeBox, nil, StaticText().string_("stagger (s)"), ~spStagBox, nil),
		StaticText().string_("level per voice:").fixedHeight_(16),
		HLayout(*(~spLvlText.keep(18))), HLayout(*(~spLvlText.drop(18)))
	);
	~spDirty = true;
	~spRout = Routine { loop {
		if (~spDirty) { ~spDirty = false;
			nv.do { |i| ~spLvlText[i].string = if (i < ~b36N) { names[~spLevel[i]].asString } { "-" } } };
		0.25.wait } }.play(AppClock);
	~spWin.onClose = {
		var syn = ~spSynths, bufs = ~spBufs;
		~spRout.stop;
		nv.do { |i| ~spSetLevel.(i, 0, 1.0) };
		~b36SetMorph = ~spOrig[\morph]; ~b36Set = ~spOrig[\count]; ~b36SetAmp = ~spOrig[\amp]; ~spOrig = nil;
		{ syn.do { |sets| sets.drop(1).do { |sy| sy !? { sy.free } } };
		  bufs.do { |sets| sets.drop(1).do { |bs| bs !? { bs.do(_.free) } } } }.defer(2.0);
	};
	("BREATH36_SPEED_READY: " ++ names.asString ++ "  voices with all levels: " ++ ~spAvail.count(_ == names.size)).postln;
};
};
)
