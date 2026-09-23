/*
breath_chorus.scd -- a looping chorus of breath, 1 to 20 voices on one slider.

Every voice is a breath collage: one performer's take (anna, grisha, raymond,
sora) cut at its breath gaps and replayed in its own shuffled order
(render_breath_voices.py, no GPU). All 20 loop together, sample-locked; the
slider sets how many are audible and voices fade in/out over "fade s".
Voice k always sits at the same place in the stereo field, and the entry order
fills the field evenly (farthest-point), so it stays balanced at any count.
Shares the default server, so it can run beside metro_slider.scd (see set.scd).
Readouts are stepped (a few Hz), no animation. Select all, evaluate.
*/
(
~bcOutDevice = "External Headphones";   // nil = system default
~bcDir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "breath_voices";
~bcN = 1;          // voices audible at start
~bcFade = 3.0;     // seconds for a voice to fade in or out
~bcAmp = 0.8;
~bcComp = false;   // true = scale by 1/sqrt(n) so the total stays level
~bcSpread = 0.9;   // stereo width, 0..1

// Shares the default server: if metro_slider.scd (or anything) already booted
// it, this just adds to it; otherwise it boots it with these options.
s = Server.default;
if (s.serverRunning.not) {
	~bcOutDevice !? {
		// fall back to the system output if the named device is missing or
		// broken (a Multi-Output whose headphones were unplugged reads as 0 Hz)
		if (ServerOptions.outDevices.includesEqual(~bcOutDevice)) {
			s.options.outDevice = ~bcOutDevice;
		} {
			("OUTPUT DEVICE '" ++ ~bcOutDevice ++ "' NOT AVAILABLE -- using system default").warn;
			s.options.outDevice = nil;
		};
	};
	s.options.numInputBusChannels = 0;
	s.options.inDevice = "MacBook Pro Microphone";   // see metro_slider.scd
};

s.waitForBoot {
	var files = PathName(~bcDir).files.select { |f| f.extension == "wav" }
		.sort { |a, b| a.fileName < b.fileName };
	var nv = files.size, slots, order, chosen;
	if (nv == 0) { ("no voices in " ++ ~bcDir ++ " -- run render_breath_voices.py").postln } {

	SynthDef(\bcVoice, { |buf, on = 0, fade = 3, pan = 0, amp = 0.8, comp = 1, out = 0|
		var g = VarLag.kr(on, fade, warp: \sin);
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), loop: 1);
		Out.ar(out, Pan2.ar(sig * g * amp.lag(0.1) * comp.lag(1), pan));
	}).add;

	// stereo places: evenly spread; entry order = farthest-point from those taken
	slots = Array.interpolation(nv, ~bcSpread.neg, ~bcSpread);
	chosen = [slots.minIndex { |x| x.abs }];
	(nv - 1).do {
		var rest = (0..(nv - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~bcPan = chosen.collect { |k| slots[k] };   // pan of voice i (i = entry order)

	~bcBufs = files.collect { |f| Buffer.read(s, f.fullPath) };
	s.sync;

	~bcCompFor = { |n| if (~bcComp) { n.max(1).sqrt.reciprocal * 2.sqrt } { 1 } };
	s.bind {
		~bcSynths = nv.collect { |i|
			Synth(\bcVoice, [\buf, ~bcBufs[i], \on, (i < ~bcN).asInteger, \fade, 0,
				\pan, ~bcPan[i], \amp, ~bcAmp, \comp, ~bcCompFor.(~bcN)]);
		};
	};
	~bcSet = { |n|
		~bcN = n.round.asInteger.clip(1, nv);
		~bcSynths.do { |sy, i| sy.set(\fade, ~bcFade, \on, (i < ~bcN).asInteger,
			\comp, ~bcCompFor.(~bcN)) };
		~bcDirty = true;
	};

	// ---------------- GUI ----------------
	~bcWin !? { if (~bcWin.isClosed.not) { ~bcWin.close } };
	~bcWin = Window("breath chorus", Rect(160, 560, 900, 280)).front;
	~bcCount = StaticText().string_(~bcN.asString ++ " voice").align_(\center)
		.font_(Font.default.size_(64).boldVariant);
	~bcWho = StaticText().string_("").align_(\center).font_(Font.default.size_(14));
	~bcSlider = Slider().orientation_(\horizontal).fixedHeight_(60)
		.step_(1 / (nv - 1)).value_((~bcN - 1) / (nv - 1))
		.action_({ |sl| ~bcSet.(1 + (sl.value * (nv - 1))) });
	~bcFadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~bcFade).fixedWidth_(56).action_({ |nb| ~bcFade = nb.value });
	~bcAmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~bcAmp).fixedWidth_(56)
		.action_({ |nb| ~bcAmp = nb.value; ~bcSynths.do(_.set(\amp, ~bcAmp)) });
	// volume: slider in dB (-40 .. +6), linked to the level box
	~bcVolText = StaticText().string_("").fixedWidth_(64).align_(\center);
	~bcSetAmp = { |a|
		~bcAmp = a.clip(0, 2);
		~bcSynths.do(_.set(\amp, ~bcAmp));
		{ ~bcAmpBox.value = ~bcAmp;
		   ~bcVolText.string = if (~bcAmp <= 0.01) { "-inf dB" } { ~bcAmp.ampdb.round(0.5).asString ++ " dB" } }.defer;
	};
	~bcVolSlider = Slider().orientation_(\vertical).fixedWidth_(44).minHeight_(160)
		.value_(\db.asSpec.copy.minval_(-40).maxval_(6).unmap(~bcAmp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value);
			~bcSetAmp.(if (sl.value <= 0.001) { 0 } { db.dbamp }) });
	~bcAmpBox.action_({ |nb| ~bcSetAmp.(nb.value);
		~bcVolSlider.value = ControlSpec(-40, 6).unmap(nb.value.max(0.0001).ampdb) });
	~bcCompBtn = Button().states_([["level comp off", Color.black, Color.white],
		["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.value_(~bcComp.asInteger)
		.action_({ |b| ~bcComp = (b.value == 1); ~bcSet.(~bcN) });
	~bcWin.layout = HLayout([VLayout(
		~bcCount, ~bcWho, ~bcSlider,
		HLayout(StaticText().string_("1"), nil, StaticText().string_(nv.asString)),
		HLayout(StaticText().string_("fade s"), ~bcFadeBox,
			StaticText().string_("level"), ~bcAmpBox, ~bcCompBtn, nil,
			StaticText().string_("loop " ++ ~bcBufs[0].duration.round(1) ++ " s, all voices in sync"))
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~bcVolSlider, nil).margins_(0), ~bcVolText).spacing_(4)
	);
	// readout repaints at most 4x a second, only when the count changed
	{ ~bcSetAmp.(~bcAmp) }.defer(0.5);   // after the s.bind voices exist
	~bcDirty = true;
	~bcRout = Routine { loop {
		if (~bcDirty) {
			var who = files.keep(~bcN).collect { |f| f.fileNameWithoutExtension.split($_).last };
			~bcDirty = false;
			~bcCount.string = ~bcN.asString ++ if (~bcN == 1) { " voice" } { " voices" };
			~bcWho.string = ["anna", "grisha", "raymond", "sora"]
				.collect { |p| p ++ " " ++ who.occurrencesOf(p) }.join("   ");
		};
		0.25.wait;
	} }.play(AppClock);
	~bcWin.onClose = { ~bcRout.stop; ~bcSynths.do(_.free); ~bcBufs.do(_.free) };
	~bcSlider.focus(true);
	"BREATH_CHORUS_READY".postln;
	};
};
)
