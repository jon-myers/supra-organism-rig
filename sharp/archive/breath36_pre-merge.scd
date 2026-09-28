/*
breath36.scd -- 36 individual breaths, each morphing breath -> its own harmonium pitch.

Every voice is a different ~21 s stretch of the July 23 breathing takes (anna,
grisha, raymond, sora; breathing_1 + breathing_2) -- no voice shares material --
looped from its own breath segments to its own length (120-160 s, none within
0.5 s of another), so the voices phase and never realign. Pitch targets: C Eb F Bb
(wall-of-sound dyads) x octaves 2-5, 9 per pitch class. Renders: breath36.py
(harmonium-v2 spn_hz LoRA on 7894).

Top: voice count (1-36). Two rows of per-voice morph sliders (bottom = breath,
top = harmonium), labelled with performer and note; ALL moves every voice.
Server-side modulation per voice: ~b36SetMod.(i, busIndex, amt) adds
In.kr(busIndex) * amt to that voice's morph (for sensor / LFO layers).
Stepped readouts only, no animation. Select all, evaluate (or set.scd).
*/
(
~b36OutDevice = "External Headphones";   // nil = system default
~b36Dir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "breath36_voices";
~b36N = 0; ~b36Fade = 3.0; ~b36Amp = 0.8; ~b36Comp = false; ~b36Spread = 0.9;
~b36Glide = 0.5;    // seconds for a morph slider move to settle

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
s.options.numBuffers = 2048;

s.waitForBoot {
	var jp = ~b36Dir +/+ "voices.json", meta, nv, ns, slots, chosen, names;
	if (File.exists(jp).not) { ("no " ++ jp ++ " -- run breath_morph.py assemble").postln } {
	meta = File.readAllString(jp).parseJSON;
	~b36Meta = meta;
	nv = meta["voices"].size;
	ns = meta["slots"].size;
	names = meta["voices"].collect { |v| v["performer"] };
	~b36Notes = meta["voices"].collect { |v| v["note"] };

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

	~b36Bufs = meta["voices"].collect { |v| v["files"].collect { |f| Buffer.read(s, ~b36Dir +/+ f) } };
	s.sync;

	~b36Silent = Bus.control(s, 1).set(0);
	~b36SetMod = { |i, busIndex, amt = 1| ~b36Synths[i].set(\modbus, busIndex ? ~b36Silent.index, \modamt, amt) };
	~b36ClearMod = { ~b36Synths.do(_.set(\modbus, ~b36Silent.index, \modamt, 0)) };
	~b36Morph = 0 ! nv;
	~b36CompFor = { |n| if (~b36Comp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~b36Synths = nv.collect { |i|
			Synth(\b36Voice, [\bufs, ~b36Bufs[i].collect(_.bufnum), \on, (i < ~b36N).asInteger,
				\modbus, ~b36Silent.index, \modamt, 0,
				\fade, 0, \pan, ~b36Pan[i], \amp, ~b36Amp, \comp, ~b36CompFor.(~b36N),
				\morph, 0, \glide, ~b36Glide]);
		};
	};
	~b36Set = { |n|
		~b36N = n.round.asInteger.clip(0, nv);
		~b36Synths.do { |sy, i| sy.set(\fade, ~b36Fade, \on, (i < ~b36N).asInteger,
			\comp, ~b36CompFor.(~b36N)) };
		~b36Dirty = true;
	};
	~b36SetMorph = { |i, v|
		~b36Morph[i] = v.clip(0, 1);
		~b36Synths[i].set(\glide, ~b36Glide, \morph, ~b36Morph[i]);
		~b36Dirty = true;
	};

	// ---------------- GUI ----------------
	~b36Win !? { if (~b36Win.isClosed.not) { ~b36Win.close } };
	~b36Win = Window("36 breaths -> pitched harmonium", Rect(60, 60, 1080, 900)).front;
	~b36Count = StaticText().string_("1 voice").align_(\center)
		.font_(Font.default.size_(48).boldVariant);
	~b36Slider = Slider().orientation_(\horizontal).fixedHeight_(48)
		.step_(1 / nv).value_(~b36N / nv)
		.action_({ |sl| ~b36Set.(sl.value * nv) });     // 0 .. nv voices
	~b36VText = Array.newClear(nv);
	~b36VSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(140).step_(0.005).value_(0)
			.action_({ |sl| ~b36SetMorph.(i, sl.value) });
	};
	~b36AllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(140).step_(0.005)
		.value_(0).action_({ |sl|
			nv.do { |i| ~b36SetMorph.(i, sl.value); ~b36VSliders[i].value = sl.value } });
	~b36Cols = nv.collect { |i|
		~b36VText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			StaticText().string_(~b36Notes[i]).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			HLayout(nil, ~b36VSliders[i], nil).margins_(0),
			~b36VText[i]
		).spacing_(2)
	};
	~b36FadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~b36Fade).fixedWidth_(56).action_({ |nb| ~b36Fade = nb.value });
	~b36GlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~b36Glide).fixedWidth_(56).action_({ |nb| ~b36Glide = nb.value });
	~b36AmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~b36Amp).fixedWidth_(56)
		.action_({ |nb| ~b36Amp = nb.value; ~b36Synths.do(_.set(\amp, ~b36Amp)) });
	// volume: slider in dB (-40 .. +6), linked to the level box
	~b36VolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~b36SetAmp = { |a|
		~b36Amp = a.clip(0, 2);
		~b36Synths.do(_.set(\amp, ~b36Amp));
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
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   ("
			++ ns ++ " FlowEdit steps)").fixedHeight_(18),
		HLayout(*(~b36Cols.keep(nv.div(2) + (nv % 2)) ++ [nil])),
		HLayout(*(~b36Cols.drop(nv.div(2) + (nv % 2)) ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "), StaticText().string_(" "),
				HLayout(nil, ~b36AllSlider, nil).margins_(0), StaticText().string_(" ")).spacing_(2),
			nil])),
		HLayout(StaticText().string_("fade s"), ~b36FadeBox,
			StaticText().string_("morph glide s"), ~b36GlideBox,
			StaticText().string_("level"), ~b36AmpBox, ~b36CompBtn, nil,
			StaticText().string_("loop " ++ meta["loop_s"] ++ " s, all voices in sync"))
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
			};
		};
		0.25.wait;
	} }.play(AppClock);
	~b36Win.onClose = { ~b36Rout.stop; ~b36Synths.do(_.free); ~b36Silent.free; ~b36Bufs.flat.do(_.free) };
	"BREATH36_READY".postln;
	};
};
)
