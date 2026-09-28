/*
breath36.scd -- 36 individual breaths, each morphing breath -> its own harmonium pitch,
plus a stepped SPEED axis (latent time-warp renders). One patch, one window.

Voices: 36 different ~21 s stretches of the July 23 breathing takes (anna, grisha, raymond,
sora; breathing_1 + breathing_2), each looped from its own breath segments to its own length
(120-160 s, none within 0.5 s of another), so the voices phase and never realign. Pitch
targets C Eb F Bb (wall-of-sound dyads) x octaves 2-5. Renders: breath36.py (harmonium-v2
spn_hz LoRA on 7894). Voices are TILED across performers: slot 1 anna, 2 grisha, 3 raymond,
4 sora, 5 anna ... so the voice-count slider adds performers in rotation.

Speed levels 1.5x 2x 3x 4x: breath36_voices/speed/<file>_x<L>.wav, each voice's 8 morph steps
re-rendered through the Stable Audio 3 autoencoder with the latent sequence time-warped
(sharp/render_speed_axis.py): local speed wanders around the level in irregular nCVI segments,
the same warp for all 8 steps of a voice. Level 1x = the original renders. Each voice sits on
one discrete level = round(speed slider + its own offset) -- never a blend of two speeds --
and voices switch one at a time (random stagger) with a short fade.

Window: voice count (0-36); speed (1x-4x) with per-voice spread; two rows of per-voice morph
sliders (bottom = breath, top = harmonium) labelled performer / note / level; ALL moves every
voice. Server-side modulation per voice: ~b36SetMod.(i, busIndex, amt) adds In.kr(bus) * amt to
that voice's morph on every level (sensor / LFO layers). Speed API: ~spSetLevel.(i, k) with
k = 0..4, ~spSetAll.(x). RAM: ~6.6 GB for 1x + ~3.5 GB per speed level; set
~b36SpeedLevels = [2, 4] (or []) before evaluating to load fewer. Select all, evaluate (or set.scd).
*/
(
~b36OutDevice = "External Headphones";   // nil = system default
~b36Dir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "breath36_voices";
~b36SpeedLevels = ~b36SpeedLevels ? [1.5, 2, 3, 4, 6, 8, 10];   // ~21 GB of buffers in all; [2, 4, 8] is a light set
~b36N = 0; ~b36Fade = 3.0; ~b36Amp = 0.8; ~b36Comp = false; ~b36Spread = 0.9;
~b36Glide = 0.5;    // seconds for a morph slider move to settle
~spP = (x: 0, spread: 0.5, fade: 0.4, stagger: 1.5);

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
s.options.numBuffers = 4096;
s.options.memSize = 2.pow(18);

s.waitForBoot {
	var jp = ~b36Dir +/+ "voices.json", meta, nv, ns, slots, chosen, names, order, performers, levelNames;
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

	SynthDef(\b36Voice, { |on = 0, fade = 3, pan = 0, amp = 0.8, comp = 1, out = 0,
		morph = 0, glide = 0.5, modbus, modamt = 0|
		var bufs = \bufs.kr(0 ! ns);
		// modbus/modamt: server-side modulation (sensors / LFOs / random walks)
		var m = (VarLag.kr(morph, glide) + (In.kr(modbus) * modamt)).clip(0, 1) * (ns - 1);
		var g = VarLag.kr(on, fade, warp: \sin);
		var sig = ns.collect { |i|
			// equal-power triangle window around step i
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;
			PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), loop: 1) * w
		}.sum;
		Out.ar(out, Pan2.ar(sig * g * amp.lag(0.1) * comp.lag(1), pan));
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
	~spAvail = ~spBufs.collect { |sets| sets.detectIndex(_.isNil) ? sets.size };   // usable levels per voice

	~b36Silent = Bus.control(s, 1).set(0);
	~b36Morph = 0 ! nv;
	~spLevel = 0 ! nv;
	~spOffset = 0 ! nv;
	~b36CompFor = { |n| if (~b36Comp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~spSynths = nv.collect { |i|
			levelNames.size.collect { |k|
				if (~spBufs[i][k].notNil) {
					var sy = Synth(\b36Voice, [\bufs, ~spBufs[i][k].collect(_.bufnum), \on, 0,
						\modbus, ~b36Silent.index, \modamt, 0,
						\fade, 0, \pan, ~b36Pan[i], \amp, ~b36Amp, \comp, ~b36CompFor.(~b36N),
						\morph, 0, \glide, ~b36Glide]);
					if (k > 0) { sy.run(false) };
					sy;
				} { nil };
			};
		};
	};
	~b36Synths = ~spSynths.collect(_.first);     // level-1 synths (what force_layer.scd etc. expect)
	~spActive = { |i| ~spSynths[i][~spLevel[i]] };
	~spEach = { |i, f| ~spSynths[i].do { |sy| sy !? { f.(sy) } } };

	~b36SetMod = { |i, busIndex, amt = 1| ~spEach.(i, { |sy| sy.set(\modbus, busIndex ? ~b36Silent.index, \modamt, amt) }) };
	~b36ClearMod = { nv.do { |i| ~spEach.(i, { |sy| sy.set(\modbus, ~b36Silent.index, \modamt, 0) }) } };
	~b36Set = { |n|
		~b36N = n.round.asInteger.clip(0, nv);
		nv.do { |i| ~spEach.(i, { |sy| sy.set(\comp, ~b36CompFor.(~b36N)) });
			~spActive.(i).set(\fade, ~b36Fade, \on, (i < ~b36N).asInteger) };
		~b36Dirty = true;
	};
	~b36SetMorph = { |i, v|
		~b36Morph[i] = v.clip(0, 1);
		~spEach.(i, { |sy| sy.set(\glide, ~b36Glide, \morph, ~b36Morph[i]) });
		~b36Dirty = true;
	};
	// speed: switch voice i to level k (0 = 1x); fade old out / new in, pause the old afterwards
	~spSetLevel = { |i, k, fade|
		var old = ~spLevel[i], f = fade ? ~spP.fade;
		k = k.round.asInteger.clip(0, ~spAvail[i] - 1);
		if (k != old) {
			var oldSy = ~spSynths[i][old], newSy = ~spSynths[i][k];
			~spLevel[i] = k;
			newSy.run(true); newSy.set(\morph, ~b36Morph[i], \fade, f, \on, (i < ~b36N).asInteger);
			oldSy.set(\fade, f, \on, 0);
			SystemClock.sched(f + 0.1, { if (~spLevel[i] != old) { oldSy.run(false) } });
			~b36Dirty = true;
		};
	};
	~spSetAll = { |x, stagger|
		~spP.x = x;
		nv.do { |i| var k = (x + ~spOffset[i]).round.asInteger;
			SystemClock.sched((stagger ? ~spP.stagger).rand, { ~spSetLevel.(i, k) }) };
	};
	~spRollOffsets = { |sp, seed = 4242| thisThread.randSeed = seed; ~spOffset = nv.collect { sp.rand2 } };
	~spRollOffsets.(~spP.spread);

	// ---------------- GUI ----------------
	~b36Win !? { if (~b36Win.isClosed.not) { ~b36Win.close } };
	~b36Win = Window("36 breaths -> pitched harmonium  +  speed", Rect(60, 40, 1120, 980)).front;
	~b36Count = StaticText().string_("0 voices").align_(\center)
		.font_(Font.default.size_(44).boldVariant);
	~b36Slider = Slider().orientation_(\horizontal).fixedHeight_(44)
		.step_(1 / nv).value_(~b36N / nv)
		.action_({ |sl| ~b36Set.(sl.value * nv) });     // 0 .. nv voices
	~spText = StaticText().string_("speed 1x").align_(\center).font_(Font.default.size_(30).boldVariant);
	~spSlider = Slider().orientation_(\horizontal).fixedHeight_(36).step_(0.01).value_(0)
		.action_({ |sl| var x = sl.value * (levelNames.size - 1); ~spSetAll.(x);
			~spText.string = "speed " ++ levelNames[x.round.asInteger].asString ++ "x   (" ++ x.round(0.01).asString ++ ")" });
	~spSpread = Slider().orientation_(\horizontal).fixedHeight_(20).value_(~spP.spread / 1.5)
		.action_({ |sl| ~spP.spread = sl.value * 1.5; ~spRollOffsets.(~spP.spread); ~spSetAll.(~spP.x) });
	~spFadeBox = NumberBox().clipLo_(0.05).clipHi_(10).step_(0.05).scroll_step_(0.05).decimals_(2).value_(~spP.fade).fixedWidth_(56)
		.action_({ |nb| ~spP.fade = nb.value });
	~spStagBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1).value_(~spP.stagger).fixedWidth_(56)
		.action_({ |nb| ~spP.stagger = nb.value });
	~spRollBtn = Button().states_([["re-roll offsets"]]).fixedWidth_(110)
		.action_({ ~spRollOffsets.(~spP.spread, Date.getDate.rawSeconds.asInteger); ~spSetAll.(~spP.x) });
	~b36VText = Array.newClear(nv);
	~spLvlText = Array.newClear(nv);
	~b36VSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(140).step_(0.005).value_(0)
			.action_({ |sl| ~b36SetMorph.(i, sl.value) });
	};
	~b36AllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(140).step_(0.005)
		.value_(0).action_({ |sl|
			nv.do { |i| ~b36SetMorph.(i, sl.value); ~b36VSliders[i].value = sl.value } });
	~b36Cols = nv.collect { |i|
		~b36VText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		~spLvlText[i] = StaticText().string_("1x").align_(\center).fixedWidth_(46).font_(Font.default.size_(10));
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			StaticText().string_(~b36Notes[i]).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			HLayout(nil, ~b36VSliders[i], nil).margins_(0),
			~b36VText[i], ~spLvlText[i]
		).spacing_(2)
	};
	~b36FadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~b36Fade).fixedWidth_(56).action_({ |nb| ~b36Fade = nb.value });
	~b36GlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~b36Glide).fixedWidth_(56).action_({ |nb| ~b36Glide = nb.value });
	~b36AmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~b36Amp).fixedWidth_(56);
	// volume: slider in dB (-40 .. +6), linked to the level box
	~b36VolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~b36SetAmp = { |a|
		~b36Amp = a.clip(0, 2);
		nv.do { |i| ~spEach.(i, { |sy| sy.set(\amp, ~b36Amp) }) };
		{ ~b36AmpBox.value = ~b36Amp;
		   ~b36VolText.string = if (~b36Amp <= 0.01) { "-inf dB" } { ~b36Amp.ampdb.round(0.5).asString ++ " dB" } }.defer;
	};
	~b36VolSlider = Slider().orientation_(\vertical).fixedWidth_(44).minHeight_(160)
		.value_(\db.asSpec.copy.minval_(-40).maxval_(6).unmap(~b36Amp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value);
			~b36SetAmp.(if (sl.value <= 0.001) { 0 } { db.dbamp }) });
	~b36AmpBox.action_({ |nb| ~b36SetAmp.(nb.value);
		~b36VolSlider.value = ControlSpec(-40, 6).unmap(nb.value.max(0.0001).ampdb) });
	~b36CompBtn = Button().states_([["level comp off", Color.black, Color.white],
		["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.action_({ |b| ~b36Comp = (b.value == 1); ~b36Set.(~b36N) });
	~b36Win.layout = HLayout([VLayout(
		~b36Count, ~b36Slider,
		HLayout(StaticText().string_("0"), nil, StaticText().string_(nv.asString ++ " voices")),
		~spText, ~spSlider,
		HLayout(*(levelNames.collect { |n| StaticText().string_(n.asString ++ "x").align_(\center) })),
		HLayout(StaticText().string_("per-voice spread (steps 0..1.5)").fixedWidth_(190), ~spSpread, ~spRollBtn,
			StaticText().string_("switch fade s"), ~spFadeBox, StaticText().string_("stagger s"), ~spStagBox),
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   ("
			++ ns ++ " FlowEdit steps);  small number = speed level").fixedHeight_(18),
		HLayout(*(~b36Cols.keep(nv.div(2) + (nv % 2)) ++ [nil])),
		HLayout(*(~b36Cols.drop(nv.div(2) + (nv % 2)) ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "), StaticText().string_(" "),
				HLayout(nil, ~b36AllSlider, nil).margins_(0), StaticText().string_(" "), StaticText().string_(" ")).spacing_(2),
			nil])),
		HLayout(StaticText().string_("fade s"), ~b36FadeBox,
			StaticText().string_("morph glide s"), ~b36GlideBox,
			StaticText().string_("level"), ~b36AmpBox, ~b36CompBtn, nil,
			StaticText().string_("voices tiled a/g/r/s; speed levels loaded: "
				++ ~spAvail.count(_ == levelNames.size) ++ "/" ++ nv ++ " voices"))
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~b36VolSlider, nil).margins_(0), ~b36VolText).spacing_(4)
	);
	{ ~b36SetAmp.(~b36Amp) }.defer(0.5);   // after the s.bind voices exist
	~b36Dirty = true;
	~b36Rout = Routine { loop {
		if (~b36Dirty) {
			~b36Dirty = false;
			~b36Count.string = ~b36N.asString ++ if (~b36N == 1) { " voice" } { " voices" };
			nv.do { |i|
				~b36VText[i].string = if (i < ~b36N) { (~b36Morph[i] * 100).round.asInteger.asString ++ "%" } { "off" };
				~spLvlText[i].string = levelNames[~spLevel[i]].asString ++ "x";
			};
		};
		0.25.wait;
	} }.play(AppClock);
	~b36Win.onClose = { ~b36Rout.stop; ~spSynths.flat.do { |sy| sy !? { sy.free } }; ~b36Silent.free;
		~spBufs.flat.do { |b| b !? { b.free } } };
	("BREATH36_READY  (" ++ nv ++ " voices tiled " ++ performers.join("/") ++ "; speed levels " ++ levelNames.asString ++ ")").postln;
	};
};
)
