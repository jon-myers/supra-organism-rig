/*
breath_morph.scd -- breath chorus (1-20 voices) where every voice can be
morphed breath -> harmonium on its own slider.

Top slider = how many voices breathe (as breath_chorus.scd). Below it, one
vertical slider per voice: 0 = the breath, 1 = full harmonium. Each voice is a
breath collage (one performer, own shuffled order, 120 s loop) rendered at
every FlowEdit morph step with identical cuts, so the crossfade between steps
is sample-locked. Steps are loudness-matched: the slider changes timbre, not
level. "all" moves every voice's morph at once.
Voices come from breath_morph.py (GPU renders via FlowEdit, then assembled
locally). Shares the default server. Stepped readouts only, no animation.
*/
(
~bmOutDevice = "External Headphones";   // nil = system default
~bmDir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "breath_morph_voices";
~bmN = 1; ~bmFade = 3.0; ~bmAmp = 0.8; ~bmComp = false; ~bmSpread = 0.9;
~bmGlide = 0.5;    // seconds for a morph slider move to settle

s = Server.default;
if (s.serverRunning.not) {
	~bmOutDevice !? {
		if (ServerOptions.outDevices.includesEqual(~bmOutDevice)) {
			s.options.outDevice = ~bmOutDevice;
		} {
			("OUTPUT DEVICE '" ++ ~bmOutDevice ++ "' NOT AVAILABLE -- using system default").warn;
			s.options.outDevice = nil;
		};
	};
	s.options.numInputBusChannels = 0;
	s.options.inDevice = "MacBook Pro Microphone";   // see metro_slider.scd
};
s.options.numBuffers = 2048;

s.waitForBoot {
	var jp = ~bmDir +/+ "voices.json", meta, nv, ns, slots, chosen, names;
	if (File.exists(jp).not) { ("no " ++ jp ++ " -- run breath_morph.py assemble").postln } {
	meta = File.readAllString(jp).parseJSON;
	~bmMeta = meta;
	nv = meta["voices"].size;
	ns = meta["slots"].size;
	names = meta["voices"].collect { |v| v["performer"] };

	SynthDef(\bmVoice, { |on = 0, fade = 3, pan = 0, amp = 0.8, comp = 1, out = 0,
		morph = 0, glide = 0.5|
		var bufs = \bufs.kr(0 ! ns);
		var m = VarLag.kr(morph.clip(0, 1), glide) * (ns - 1);   // 0 .. ns-1
		var g = VarLag.kr(on, fade, warp: \sin);
		var sig = ns.collect { |i|
			// equal-power triangle window around step i
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;
			PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), loop: 1) * w
		}.sum;
		Out.ar(out, Pan2.ar(sig * g * amp.lag(0.1) * comp.lag(1), pan));
	}).add;

	slots = Array.interpolation(nv, ~bmSpread.neg, ~bmSpread);
	chosen = [slots.minIndex { |x| x.abs }];
	(nv - 1).do {
		var rest = (0..(nv - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~bmPan = chosen.collect { |k| slots[k] };

	~bmBufs = meta["voices"].collect { |v| v["files"].collect { |f| Buffer.read(s, ~bmDir +/+ f) } };
	s.sync;

	~bmMorph = 0 ! nv;
	~bmCompFor = { |n| if (~bmComp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~bmSynths = nv.collect { |i|
			Synth(\bmVoice, [\bufs, ~bmBufs[i].collect(_.bufnum), \on, (i < ~bmN).asInteger,
				\fade, 0, \pan, ~bmPan[i], \amp, ~bmAmp, \comp, ~bmCompFor.(~bmN),
				\morph, 0, \glide, ~bmGlide]);
		};
	};
	~bmSet = { |n|
		~bmN = n.round.asInteger.clip(1, nv);
		~bmSynths.do { |sy, i| sy.set(\fade, ~bmFade, \on, (i < ~bmN).asInteger,
			\comp, ~bmCompFor.(~bmN)) };
		~bmDirty = true;
	};
	~bmSetMorph = { |i, v|
		~bmMorph[i] = v.clip(0, 1);
		~bmSynths[i].set(\glide, ~bmGlide, \morph, ~bmMorph[i]);
		~bmDirty = true;
	};

	// ---------------- GUI ----------------
	~bmWin !? { if (~bmWin.isClosed.not) { ~bmWin.close } };
	~bmWin = Window("breath -> harmonium chorus", Rect(100, 120, 1240, 620)).front;
	~bmCount = StaticText().string_("1 voice").align_(\center)
		.font_(Font.default.size_(48).boldVariant);
	~bmSlider = Slider().orientation_(\horizontal).fixedHeight_(48)
		.step_(1 / (nv - 1)).value_(0)
		.action_({ |sl| ~bmSet.(1 + (sl.value * (nv - 1))) });
	~bmVText = Array.newClear(nv);
	~bmVSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(200).step_(0.005).value_(0)
			.action_({ |sl| ~bmSetMorph.(i, sl.value) });
	};
	~bmAllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(200).step_(0.005)
		.value_(0).action_({ |sl|
			nv.do { |i| ~bmSetMorph.(i, sl.value); ~bmVSliders[i].value = sl.value } });
	~bmCols = nv.collect { |i|
		~bmVText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			HLayout(nil, ~bmVSliders[i], nil).margins_(0),
			~bmVText[i]
		).spacing_(2)
	};
	~bmFadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~bmFade).fixedWidth_(56).action_({ |nb| ~bmFade = nb.value });
	~bmGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~bmGlide).fixedWidth_(56).action_({ |nb| ~bmGlide = nb.value });
	~bmAmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~bmAmp).fixedWidth_(56)
		.action_({ |nb| ~bmAmp = nb.value; ~bmSynths.do(_.set(\amp, ~bmAmp)) });
	// volume: slider in dB (-40 .. +6), linked to the level box
	~bmVolText = StaticText().string_("").fixedWidth_(70);
	~bmSetAmp = { |a|
		~bmAmp = a.clip(0, 2);
		~bmSynths.do(_.set(\amp, ~bmAmp));
		{ ~bmAmpBox.value = ~bmAmp;
		   ~bmVolText.string = if (~bmAmp <= 0.01) { "-inf dB" } { ~bmAmp.ampdb.round(0.5).asString ++ " dB" } }.defer;
	};
	~bmVolSlider = Slider().orientation_(\horizontal).fixedHeight_(30)
		.value_(\db.asSpec.copy.minval_(-40).maxval_(6).unmap(~bmAmp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value);
			~bmSetAmp.(if (sl.value <= 0.001) { 0 } { db.dbamp }) });
	~bmAmpBox.action_({ |nb| ~bmSetAmp.(nb.value);
		~bmVolSlider.value = ControlSpec(-40, 6).unmap(nb.value.max(0.0001).ampdb) });
	~bmCompBtn = Button().states_([["level comp off", Color.black, Color.white],
		["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.action_({ |b| ~bmComp = (b.value == 1); ~bmSet.(~bmN) });
	~bmWin.layout = VLayout(
		~bmCount, ~bmSlider,
		HLayout(StaticText().string_("volume").font_(Font.default.boldVariant), [~bmVolSlider, stretch: 1], ~bmVolText),
		HLayout(StaticText().string_("1"), nil, StaticText().string_(nv.asString ++ " voices")),
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   ("
			++ ns ++ " FlowEdit steps)").fixedHeight_(18),
		HLayout(*(~bmCols ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "),
				HLayout(nil, ~bmAllSlider, nil).margins_(0), StaticText().string_(" ")).spacing_(2)
		])),
		HLayout(StaticText().string_("fade s"), ~bmFadeBox,
			StaticText().string_("morph glide s"), ~bmGlideBox,
			StaticText().string_("level"), ~bmAmpBox, ~bmCompBtn, nil,
			StaticText().string_("loop " ++ meta["loop_s"] ++ " s, all voices in sync"))
	);
	{ ~bmSetAmp.(~bmAmp) }.defer(0.5);   // after the s.bind voices exist
	~bmDirty = true;
	~bmRout = Routine { loop {
		if (~bmDirty) {
			~bmDirty = false;
			~bmCount.string = ~bmN.asString ++ if (~bmN == 1) { " voice" } { " voices" };
			nv.do { |i|
				~bmVText[i].string = if (i < ~bmN) { (~bmMorph[i] * 100).round.asInteger.asString ++ "%" } { "off" };
			};
		};
		0.25.wait;
	} }.play(AppClock);
	~bmWin.onClose = { ~bmRout.stop; ~bmSynths.do(_.free); ~bmBufs.flat.do(_.free) };
	"BREATH_MORPH_READY".postln;
	};
};
)
