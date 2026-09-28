/*
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
  sliders 1-8  breath -> harmonium morph of a BLOCK of consecutive voices: 4 5 4 5 4 5 4 5 (= 36),
               i.e. slider 1 = voices 1-4, 2 = 5-9, 3 = 10-13, ... 8 = 32-36 (voices are tiled a/g/r/s)
  S / M        solo / mute that group      R1  re-roll speed offsets      CYCLE  link all sliders
  knob 1 voices 0-36 | 2 speed level | 3 speed spread | 4 morph glide | 5 volume | 6 fade | 7 gap s | 8 gap nCVI
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
~b36Dir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ if (~b36Version == \a) { "breath36_voices" } { "breath36b_voices" };
~b36OnsetSuffix = if (~b36Version == \a) { "" } { "_b" };
~b36Sharp = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "sharp";
~b36SpeedLevels = ~b36SpeedLevels ? [1.5, 2, 3, 4, 6, 8, 10];
~b36Midi = ~b36Midi ? true;
~b36N = 0; ~b36Fade = 3.0; ~b36Amp = 0.8; ~b36Comp = false; ~b36Spread = 0.9;
~b36Glide = 0.5;    // seconds for a morph slider move to settle
~spP = (x: 0, spread: 0.5);
~gpP = (mean: 0, ncviIdx: 3, fade: 0.04);

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
	~b36Silent !? { ~b36Silent.free }; ~b36MorphBus !? { ~b36MorphBus.free }; ~b36GainBus !? { ~b36GainBus.free };
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
	SynthDef(\b36Ctl, { |morphOut, gainOut, morph = 0, glide = 0.5, modbus, modamt = 0, on = 0, fade = 3|
		Out.kr(morphOut, (VarLag.kr(morph, glide) + (In.kr(modbus) * modamt)).clip(0, 1));
		Out.kr(gainOut, VarLag.kr(on, fade, warp: \sin));
	}).add;
	SynthDef(\b36Seg, { |start = 0, dur = 1, fade = 0.04, morphBus, gainBus, pan = 0, amp = 0.8, comp = 1, out = 0|
		var bufs = \bufs.kr(0 ! ns);
		var m = In.kr(morphBus) * (ns - 1);
		// LINEAR fades: consecutive segments are the same continuous material, and linear in/out sum to exactly 1 across the overlap
		var env = EnvGen.kr(Env.linen(fade, (dur - fade).max(0.001), fade, 1, \lin), doneAction: 2);
		var sig = ns.collect { |i|
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;      // equal-power triangle window around step i
			PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), 1, start, 0) * w
		}.sum;
		Out.ar(out, Pan2.ar(sig * env * In.kr(gainBus) * amp.lag(0.1) * comp.lag(1), pan));
	}).add;

	slots = Array.interpolation(nv, ~b36Spread.neg, ~b36Spread);
	chosen = [slots.minIndex { |x| x.abs }];
	(nv - 1).do {
		var rest = (0..(nv - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~b36Pan = chosen.collect { |k| slots[k] };

	// ---- buffers: level 1 (originals) + speed levels (skipped per voice if not rendered) ----
	~b36Bufs = meta["voices"].collect { |v| v["files"].collect { |f| Buffer.read(s, ~b36Dir +/+ f) } };
	~spBufs = meta["voices"].collect { |v, i|
		[~b36Bufs[i]] ++ ~b36SpeedLevels.collect { |lv|
			var files = v["files"].collect { |f| ~b36Dir +/+ "speed" +/+ (f.splitext[0] ++ "_x" ++ lv.asString ++ ".wav") };
			if (files.every { |p| File.exists(p) }) { files.collect { |p| Buffer.read(s, p) } } { nil };
		};
	};
	("breath36: reading " ++ ~spBufs.flat.reject(_.isNil).size ++ " buffers ...").postln;
	s.sync;
	~spAvail = ~spBufs.collect { |sets| sets.detectIndex(_.isNil) ? sets.size };

	~b36Silent = Bus.control(s, 1).set(0);
	~b36MorphBus = Bus.control(s, nv); ~b36GainBus = Bus.control(s, nv);
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
				\morph, 0, \glide, ~b36Glide, \modbus, ~b36Silent.index, \modamt, 0, \on, 0, \fade, 0]);
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
	~spSetLevel = { |i, k| ~spLevel[i] = k.round.asInteger.clip(0, ~spAvail[i] - 1); ~b36Dirty = true };   // takes effect at the voice's next breath
	~spSetAll = { |x| ~spP.x = x; nv.do { |i| ~spSetLevel.(i, x + ~spOffset[i]) } };
	~spRollOffsets = { |sp, seed = 4242| ~spP.spread = sp; thisThread.randSeed = seed; ~spOffset = nv.collect { sp.rand2 }; ~spSetAll.(~spP.x) };
	~spRollOffsets.(~spP.spread);
	~gpSet = { |secs| ~gpP[\mean] = secs.clip(0, 12); ~b36Dirty = true };

	// ---- the players: one routine per voice, breath by breath ----
	~b36Players = nv.collect { |i|
		Routine {
			loop {
				var k = ~spLevel[i], bufs = ~spBufs[i][k], ons = ~spOnsets[i][k], b0 = bufs[0];
				var total = b0.numFrames / b0.sampleRate, n = ons.size, idx, t0, t1, dur, fade, gap, audible;
				if (~segIdx[i].isNil) { ~segIdx[i] = (~segPhase[i] * n).floor.asInteger; ~segN[i] = n };
				if (~segN[i] != n) { ~segIdx[i] = (~segIdx[i] / ~segN[i] * n).round.asInteger; ~segN[i] = n };   // level changed: keep the place
				idx = ~segIdx[i] % n;
				t0 = ons[idx]; t1 = if (idx + 1 < n) { ons[idx + 1] } { total };
				dur = (t1 - t0).max(0.05); fade = ~gpP.fade.min(dur * 0.45);
				gap = ~gpP[\mean] * ~gpSeq[i][~gpP.ncviIdx].wrapAt(~gapIdx[i]);
				audible = (~b36OnState[i] == 1) or: { ~offAt[i].notNil and: { (Main.elapsedTime - ~offAt[i]) < (~b36Fade + 0.5) } };
				if (audible) {
					s.makeBundle(s.latency, {
						Synth(\b36Seg, [\bufs, bufs.collect(_.bufnum), \start, t0 * b0.sampleRate, \dur, dur, \fade, fade,
							\morphBus, ~b36MorphBus.index + i, \gainBus, ~b36GainBus.index + i,
							\pan, ~b36Pan[i], \amp, ~b36Amp, \comp, ~b36CompFor.(~b36N)]);
					});
				};
				~gapIdx[i] = ~gapIdx[i] + 1;
				~segIdx[i] = idx + 1;
				(dur + gap).wait;
			}
		}.play(SystemClock);
	};

	// ---------------- GUI ----------------
	~b36Win !? { ~b36Win.onClose = nil; if (~b36Win.isClosed.not) { ~b36Win.close } };
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
			~spText.string = "speed " ++ levelNames[x.round.asInteger].asString ++ "x   (" ++ x.round(0.01).asString ++ ")" });
	~spSpread = Slider().orientation_(\horizontal).fixedHeight_(20).value_(~spP.spread / 1.5)
		.action_({ |sl| ~spRollOffsets.(sl.value * 1.5) });
	~spRollBtn = Button().states_([["re-roll offsets"]]).fixedWidth_(110)
		.action_({ ~spRollOffsets.(~spP.spread, Date.getDate.rawSeconds.asInteger) });
	~gpText = StaticText().string_("gap 0.0 s").align_(\center).font_(Font.default.size_(26).boldVariant);
	~gpSlider = Slider().orientation_(\horizontal).fixedHeight_(32).step_(0.005).value_(0)
		.action_({ |sl| ~gpSet.(sl.value.squared * 12); ~gpText.string = "gap " ++ ~gpP[\mean].round(0.1).asString ++ " s" });
	~gpNcvi = PopUpMenu().items_(gapLevels.collect { |l| "gap nCVI " ++ l.round.asInteger.asString }).value_(~gpP.ncviIdx)
		.action_({ |pm| ~gpP.ncviIdx = pm.value });
	~gpFadeBox = NumberBox().clipLo_(5).clipHi_(500).step_(5).scroll_step_(5).decimals_(0).value_(~gpP.fade * 1000).fixedWidth_(56)
		.action_({ |nb| ~gpP.fade = nb.value / 1000 });
	~b36VText = Array.newClear(nv); ~spLvlText = Array.newClear(nv);
	~b36VSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(130).step_(0.005).value_(0)
			.action_({ |sl| ~b36SetMorph.(i, sl.value) });
	};
	~b36AllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(130).step_(0.005)
		.value_(0).action_({ |sl| nv.do { |i| ~b36SetMorph.(i, sl.value); ~b36VSliders[i].value = sl.value } });
	~b36Cols = nv.collect { |i|
		~b36VText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		~spLvlText[i] = StaticText().string_("1x").align_(\center).fixedWidth_(46).font_(Font.default.size_(10));
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46).font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			StaticText().string_(~b36Notes[i]).align_(\center).fixedWidth_(46).font_(Font.default.boldVariant),
			HLayout(nil, ~b36VSliders[i], nil).margins_(0),
			~b36VText[i], ~spLvlText[i]
		).spacing_(2)
	};
	~b36FadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~b36Fade).fixedWidth_(56).action_({ |nb| ~b36Fade = nb.value });
	~b36GlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1).value_(~b36Glide).fixedWidth_(56).action_({ |nb| ~b36Glide = nb.value });
	~b36AmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2).value_(~b36Amp).fixedWidth_(56);
	~b36VolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~b36SetAmp = { |a|
		~b36Amp = a.clip(0, 2);
		{ ~b36AmpBox.value = ~b36Amp;
		   ~b36VolText.string = if (~b36Amp <= 0.01) { "-inf dB" } { ~b36Amp.ampdb.round(0.5).asString ++ " dB" } }.defer;
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
			HLayout(StaticText().string_("spread (steps 0..1.5)").fixedWidth_(130), ~spSpread, ~spRollBtn)), stretch: 3],
			[VLayout(~gpText, ~gpSlider, HLayout(StaticText().string_("0"), nil, StaticText().string_("12 s")),
			HLayout(~gpNcvi, nil, StaticText().string_("seg fade ms"), ~gpFadeBox)), stretch: 2]),
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   (" ++ ns ++ " FlowEdit steps);  small number = speed level").fixedHeight_(18),
		HLayout(*(~b36Cols.keep(nv.div(2) + (nv % 2)) ++ [nil])),
		HLayout(*(~b36Cols.drop(nv.div(2) + (nv % 2)) ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "), StaticText().string_(" "),
				HLayout(nil, ~b36AllSlider, nil).margins_(0), StaticText().string_(" "), StaticText().string_(" ")).spacing_(2),
			nil])),
		HLayout(StaticText().string_("fade s"), ~b36FadeBox, StaticText().string_("morph glide s"), ~b36GlideBox,
			StaticText().string_("level"), ~b36AmpBox, ~b36CompBtn, nil,
			StaticText().string_("tiled " ++ performers.collect(_.keep(1)).join("/") ++ "; speed levels loaded for "
				++ ~spAvail.count(_ == levelNames.size) ++ "/" ++ nv ++ " voices")),
		~mkStatus
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~b36VolSlider, nil).margins_(0), ~b36VolText).spacing_(4)
	);
	{ ~b36SetAmp.(~b36Amp) }.defer(0.5);
	~b36Dirty = true;
	~b36Rout = Routine { loop {
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
		0.25.wait;
	} }.play(AppClock);

	// ---------------- nanoKONTROL2 ----------------
	// slider g morphs a BLOCK of consecutive voices, sizes 4 5 4 5 4 5 4 5 (Jon, 2026-09-28)
	~mkBlockSizes = [4, 5, 4, 5, 4, 5, 4, 5];
	~mkGroupVoices = ~mkBlockSizes.collect { |sz, g| var start = ~mkBlockSizes.keep(g).sum; (start..(start + sz - 1)).select { |i| i < nv } };
	~mkGroup = nv.collect { |i| ~mkGroupVoices.detectIndex { |vs| vs.includes(i) } ? 0 };
	~mkLink = false; ~mkLastN = nv;
	~mkLast = IdentityDictionary.new; ~mkCaught = IdentityDictionary.new;
	// soft takeover: a control only acts once it has passed through (or come within 3 % of) the current value
	~mkPick = { |cc, v, current|
		var last = ~mkLast[cc], caught = ~mkCaught[cc] ? false;
		if (caught.not) {
			if (((v - current).abs < 0.03) or: { last.notNil and: { ((last - current).sign != (v - current).sign) } }) { caught = true };
		};
		~mkLast[cc] = v; ~mkCaught[cc] = caught; caught;
	};
	~mkCC = (sliders: (0..7), knobs: (16..23), sBtn: (32..39), mBtn: (48..55), rBtn: (64..71), play: 41, stop: 42, cycle: 46);
	~mkGroupMorph = { |g| var vs = ~mkGroupVoices[g]; if (vs.isEmpty) { 0 } { vs.collect { |i| ~b36Morph[i] }.mean } };
	~mkSetGroup = { |g, v| (if (~mkLink) { (0..(nv - 1)) } { ~mkGroupVoices[g] }).do { |i| ~b36SetMorph.(i, v); ~b36VSliders[i].value = v } };
	~mkKnob = { |k, v|
		var lmax = levelNames.size - 1;
		switch (k,
			0, { if (~mkPick.(16, v, ~b36N / nv)) { ~b36Set.(v * nv); ~b36Slider.value = ~b36N / nv } },
			1, { if (~mkPick.(17, v, ~spP.x / lmax)) { var x = (v * lmax).round; if (x != ~spP.x) { ~spSetAll.(x); ~spSlider.value = x / lmax;
					~spText.string = "speed " ++ levelNames[x.asInteger].asString ++ "x" } } },
			2, { if (~mkPick.(18, v, ~spP.spread / 1.5)) { ~spRollOffsets.(v * 1.5); ~spSpread.value = v } },
			3, { if (~mkPick.(19, v, ~b36Glide / 5)) { ~b36Glide = v * 5; ~b36GlideBox.value = ~b36Glide } },
			4, { if (~mkPick.(20, v, ControlSpec(-40, 6).unmap(~b36Amp.max(0.0001).ampdb))) { ~b36VolSlider.valueAction = v } },
			5, { if (~mkPick.(21, v, ~b36Fade / 15)) { ~b36Fade = v * 15; ~b36FadeBox.value = ~b36Fade } },
			6, { if (~mkPick.(22, v, (~gpP[\mean] / 12).sqrt)) { ~gpSlider.valueAction = v } },
			7, { if (~mkPick.(23, v, ~gpP.ncviIdx / (gapLevels.size - 1))) { ~gpNcvi.valueAction = (v * (gapLevels.size - 1)).round } }
		);
	};
	~mkButton = { |num|
		var g;
		g = ~mkCC.sBtn.indexOf(num); g !? { ~mkGroupVoices[g].do { |i| ~b36Solo[i] = ~b36Solo[i].not }; ~b36ApplyOn.() };
		g = ~mkCC.mBtn.indexOf(num); g !? { ~mkGroupVoices[g].do { |i| ~b36Mute[i] = ~b36Mute[i].not }; ~b36ApplyOn.() };
		if (num == ~mkCC.rBtn[0]) { ~spRollOffsets.(~spP.spread, Date.getDate.rawSeconds.asInteger) };
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
				if (~mkOwner == \breath36) {
					g !? { if (~mkPick.(cc, v, ~mkGroupMorph.(g))) { ~mkSetGroup.(g, v) } };
					k !? { ~mkKnob.(k, v) };
					if (g.isNil and: { k.isNil } and: { val > 0 } and: { cc != 58 } and: { cc != 59 }) { ~mkButton.(cc) };
				};
			}.defer;
		}).permanent_(true);
		MIDIdef.noteOn(\b36note, { |vel, note, chan| {   // Jon's unit sends some buttons as notes
			if (note == 58 or: { note == 59 }) { ~mkPassOwner.(if (note == 59) { 1 } { -1 }) } { if (~mkOwner == \breath36) { ~mkButton.(note) } } }.defer }).permanent_(true);
	};

	~b36Win.onClose = { ~b36Rout.stop; ~b36Players.do(_.stop); ~b36Synths.do(_.free); ~mkOwners !? { ~mkOwners.remove(\breath36); ~mkOwner = ~mkOwners.first };
		~b36Silent.free; ~b36MorphBus.free; ~b36GainBus.free;
		MIDIdef(\b36cc).free; MIDIdef(\b36note).free;
		~spBufs.flat.do { |b| b !? { b.free } } };
	("BREATH36_READY  (" ++ nv ++ " voices tiled " ++ performers.join("/") ++ "; speed levels " ++ levelNames.asString
		++ "; groups " ++ ~mkGroupVoices.collect(_.size).asString ++ ")").postln;
	};
};
)
