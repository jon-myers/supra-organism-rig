/*
breath_pitched.scd -- as breath_morph.scd, but every voice morphs toward its OWN
harmonium pitch (C, Eb, F, Bb across octaves 2-5, from the wall-of-sound dyads;
breath_pitched.py). Each slider is labelled with its voice's target note.

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
~bpOutDevice = "External Headphones";   // nil = system default
~bpDir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "breath_pitched_voices";
~bpN = 1; ~bpFade = 3.0; ~bpAmp = 0.8; ~bpComp = false; ~bpSpread = 0.9;
~bpGlide = 0.5;    // seconds for a morph slider move to settle

s = Server.default;
if (s.serverRunning.not) {
	~bpOutDevice !? {
		if (ServerOptions.outDevices.includesEqual(~bpOutDevice)) {
			s.options.outDevice = ~bpOutDevice;
		} {
			("OUTPUT DEVICE '" ++ ~bpOutDevice ++ "' NOT AVAILABLE -- using system default").warn;
			s.options.outDevice = nil;
		};
	};
	s.options.numInputBusChannels = 0;
	s.options.inDevice = "MacBook Pro Microphone";   // see metro_slider.scd
};
s.options.numBuffers = 2048;

s.waitForBoot {
	var jp = ~bpDir +/+ "voices.json", meta, nv, ns, slots, chosen, names;
	if (File.exists(jp).not) { ("no " ++ jp ++ " -- run breath_morph.py assemble").postln } {
	meta = File.readAllString(jp).parseJSON;
	~bpMeta = meta;
	nv = meta["voices"].size;
	ns = meta["slots"].size;
	names = meta["voices"].collect { |v| v["performer"] };
	~bpNotes = meta["voices"].collect { |v| v["note"] };

	SynthDef(\bpVoice, { |on = 0, fade = 3, pan = 0, amp = 0.8, comp = 1, out = 0,
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

	slots = Array.interpolation(nv, ~bpSpread.neg, ~bpSpread);
	chosen = [slots.minIndex { |x| x.abs }];
	(nv - 1).do {
		var rest = (0..(nv - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~bpPan = chosen.collect { |k| slots[k] };

	~bpBufs = meta["voices"].collect { |v| v["files"].collect { |f| Buffer.read(s, ~bpDir +/+ f) } };
	s.sync;

	~bpMorph = 0 ! nv;
	~bpCompFor = { |n| if (~bpComp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~bpSynths = nv.collect { |i|
			Synth(\bpVoice, [\bufs, ~bpBufs[i].collect(_.bufnum), \on, (i < ~bpN).asInteger,
				\fade, 0, \pan, ~bpPan[i], \amp, ~bpAmp, \comp, ~bpCompFor.(~bpN),
				\morph, 0, \glide, ~bpGlide]);
		};
	};
	~bpSet = { |n|
		~bpN = n.round.asInteger.clip(1, nv);
		~bpSynths.do { |sy, i| sy.set(\fade, ~bpFade, \on, (i < ~bpN).asInteger,
			\comp, ~bpCompFor.(~bpN)) };
		~bpDirty = true;
	};
	~bpSetMorph = { |i, v|
		~bpMorph[i] = v.clip(0, 1);
		~bpSynths[i].set(\glide, ~bpGlide, \morph, ~bpMorph[i]);
		~bpDirty = true;
	};

	// ---------------- GUI ----------------
	~bpWin !? { if (~bpWin.isClosed.not) { ~bpWin.close } };
	~bpWin = Window("breath -> pitched harmonium chorus", Rect(100, 120, 1240, 620)).front;
	~bpCount = StaticText().string_("1 voice").align_(\center)
		.font_(Font.default.size_(48).boldVariant);
	~bpSlider = Slider().orientation_(\horizontal).fixedHeight_(48)
		.step_(1 / (nv - 1)).value_(0)
		.action_({ |sl| ~bpSet.(1 + (sl.value * (nv - 1))) });
	~bpVText = Array.newClear(nv);
	~bpVSliders = nv.collect { |i|
		Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(200).step_(0.005).value_(0)
			.action_({ |sl| ~bpSetMorph.(i, sl.value) });
	};
	~bpAllSlider = Slider().orientation_(\vertical).fixedWidth_(40).minHeight_(200).step_(0.005)
		.value_(0).action_({ |sl|
			nv.do { |i| ~bpSetMorph.(i, sl.value); ~bpVSliders[i].value = sl.value } });
	~bpCols = nv.collect { |i|
		~bpVText[i] = StaticText().string_("0").align_(\center).fixedWidth_(46);
		VLayout(
			StaticText().string_((i + 1).asString).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			StaticText().string_(names[i].keep(4)).align_(\center).fixedWidth_(46),
			StaticText().string_(~bpNotes[i]).align_(\center).fixedWidth_(46)
				.font_(Font.default.boldVariant),
			HLayout(nil, ~bpVSliders[i], nil).margins_(0),
			~bpVText[i]
		).spacing_(2)
	};
	~bpFadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~bpFade).fixedWidth_(56).action_({ |nb| ~bpFade = nb.value });
	~bpGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~bpGlide).fixedWidth_(56).action_({ |nb| ~bpGlide = nb.value });
	~bpAmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~bpAmp).fixedWidth_(56)
		.action_({ |nb| ~bpAmp = nb.value; ~bpSynths.do(_.set(\amp, ~bpAmp)) });
	// volume: slider in dB (-40 .. +6), linked to the level box
	~bpVolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~bpSetAmp = { |a|
		~bpAmp = a.clip(0, 2);
		~bpSynths.do(_.set(\amp, ~bpAmp));
		{ ~bpAmpBox.value = ~bpAmp;
		   ~bpVolText.string = if (~bpAmp <= 0.01) { "-inf dB" } { ~bpAmp.ampdb.round(0.5).asString ++ " dB" } }.defer;
	};
	~bpVolSlider = Slider().orientation_(\vertical).fixedWidth_(44).minHeight_(160)
		.value_(\db.asSpec.copy.minval_(-40).maxval_(6).unmap(~bpAmp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value);
			~bpSetAmp.(if (sl.value <= 0.001) { 0 } { db.dbamp }) });
	~bpAmpBox.action_({ |nb| ~bpSetAmp.(nb.value);
		~bpVolSlider.value = ControlSpec(-40, 6).unmap(nb.value.max(0.0001).ampdb) });
	~bpCompBtn = Button().states_([["level comp off", Color.black, Color.white],
		["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.action_({ |b| ~bpComp = (b.value == 1); ~bpSet.(~bpN) });
	~bpWin.layout = HLayout([VLayout(
		~bpCount, ~bpSlider,
		HLayout(StaticText().string_("1"), nil, StaticText().string_(nv.asString ++ " voices")),
		StaticText().string_("morph per voice:  bottom = breath,  top = harmonium   ("
			++ ns ++ " FlowEdit steps)").fixedHeight_(18),
		HLayout(*(~bpCols ++ [
			VLayout(StaticText().string_("ALL").align_(\center).font_(Font.default.boldVariant),
				StaticText().string_(" "),
				HLayout(nil, ~bpAllSlider, nil).margins_(0), StaticText().string_(" ")).spacing_(2)
		])),
		HLayout(StaticText().string_("fade s"), ~bpFadeBox,
			StaticText().string_("morph glide s"), ~bpGlideBox,
			StaticText().string_("level"), ~bpAmpBox, ~bpCompBtn, nil,
			StaticText().string_("loop " ++ meta["loop_s"] ++ " s, all voices in sync"))
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~bpVolSlider, nil).margins_(0), ~bpVolText).spacing_(4)
	);
	{ ~bpSetAmp.(~bpAmp) }.defer(0.5);   // after the s.bind voices exist
	~bpDirty = true;
	~bpRout = Routine { loop {
		if (~bpDirty) {
			~bpDirty = false;
			~bpCount.string = ~bpN.asString ++ if (~bpN == 1) { " voice" } { " voices" };
			nv.do { |i|
				~bpVText[i].string = if (i < ~bpN) { (~bpMorph[i] * 100).round.asInteger.asString ++ "%" } { "off" };
			};
		};
		0.25.wait;
	} }.play(AppClock);
	~bpWin.onClose = { ~bpRout.stop; ~bpSynths.do(_.free); ~bpBufs.flat.do(_.free) };
	"BREATH_PITCHED_READY".postln;
	};
};
)
