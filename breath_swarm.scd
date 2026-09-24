/*
breath_swarm.scd -- live breath collage, 1 to 216 voices (6^3), each morphing
breath -> pitched harmonium.

Unlike breath_pitched.scd (20 pre-baked 120 s loops), the collage happens HERE:
each FlowEdit render (one 35 s breath chunk x 8 morph steps, prepare_swarm.py)
is held once, and every voice plays breath segments of one render in its own
endlessly reshuffled order. No loops -> nothing realigns; memory does not grow
with the voice count. Voice v uses render v mod nr, so 216 voices share the renders.

Morph per voice = ALL + its pitch-class offset + its octave offset (clipped 0..1).
Each segment ("grain") latches the pair of morph steps it sits between at its
onset and crossfades between them live, so a slider move lands within a breath.

OSC in (to sclang, port 57120) for sensor / automation layers:
  /swarm/count n        /swarm/all v        /swarm/voice i v   (per-voice override, v<0 clears)
  /swarm/pc  k v  (k 0-3 = C Eb F Bb)      /swarm/oct k v  (k 0-3 = octaves 2-5)
  /swarm/mod i busIndex amt   voice i's morph += In.kr(busIndex) * amt, on the server
In-language: ~bsSetMod.(v, busIndex, amt), ~bsClearMod.(); ~bsMBus / ~bsGBus hold
each voice's live morph / gain (bus index + v) for anything that wants to read them.
Stepped readouts only (<= 4 Hz), no animation. Select all, evaluate (or set.scd).
*/
(
~bsOutDevice = "External Headphones";   // falls back to system default if absent
~bsDir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ "swarm_renders";
~bsMax = 216;        // 6^3
~bsN = 1;
~bsFade = 3.0;       // voice fade in/out, s
~bsGlide = 0.5;      // morph glide, s
~bsXf = 0.06;        // segment crossfade, s
~bsAmp = 0.8;
~bsComp = true;      // 1/sqrt(n) level compensation (on: 216 voices are loud)
~bsSpread = 0.95;

s = Server.default;
if (s.serverRunning.not) {
	~bsOutDevice !? {
		if (ServerOptions.outDevices.includesEqual(~bsOutDevice)) {
			s.options.outDevice = ~bsOutDevice } {
			("OUTPUT DEVICE '" ++ ~bsOutDevice ++ "' NOT AVAILABLE -- using system default").warn;
			s.options.outDevice = nil };
	};
	s.options.numInputBusChannels = 0;
	s.options.inDevice = "MacBook Pro Microphone";
	s.options.maxNodes = 8192;
};

s.waitForBoot {
	var jp = ~bsDir +/+ "swarm.json", meta, nr, ns, slots, chosen;
	if (File.exists(jp).not) { ("no " ++ jp ++ " -- run prepare_swarm.py").postln } {
	meta = File.readAllString(jp).parseJSON;
	nr = meta["renders"].size;
	ns = meta["slots"].asInteger;
	~bsNs = ns;
	~bsRenders = meta["renders"].collect { |r|
		(performer: r["performer"], note: r["note"],
			segs: r["segments"].collect { |p| p.collect(_.asFloat) },
			pc: ["C", "Eb", "F", "Bb"].indexOf(r["note"].drop(-1)) ? 0,
			oct: (r["note"].last.digit - 2).clip(0, 3))
	};
	~bsBufs = meta["renders"].collect { |r| r["files"].collect { |f| Buffer.read(s, ~bsDir +/+ f) } };

	// per-voice control: morph (glided) and gain (faded) on control buses
	// modbus/modamt: a server-side modulation input (sensor / LFO / random-walk
	// layers write buses, each voice reads one) -- no per-voice .set traffic.
	SynthDef(\bsCtl, { |mbus, gbus, morph = 0, glide = 0.5, on = 0, fade = 3, modbus, modamt = 0|
		Out.kr(mbus, (VarLag.kr(morph, glide) + (In.kr(modbus) * modamt)).clip(0, 1));
		Out.kr(gbus, VarLag.kr(on, fade, warp: \sin));
	}).add;
	// one breath segment: two neighbouring morph steps, crossfaded by the live morph
	SynthDef(\bsGrain, { |bufA, bufB, lo = 0, start = 0, dur = 1, xf = 0.06, pan = 0,
		mbus, gbus, out = 0|
		var m = In.kr(mbus) * (ns - 1);
		var w = (m - lo).clip(0, 1);
		var env = EnvGen.ar(Env([0, 1, 1, 0], [xf, (dur - xf).max(0.001), xf], \sin), doneAction: 2);
		var a = PlayBuf.ar(1, bufA, BufRateScale.kr(bufA), startPos: start * BufSampleRate.kr(bufA));
		var b = PlayBuf.ar(1, bufB, BufRateScale.kr(bufB), startPos: start * BufSampleRate.kr(bufB));
		var sig = (a * (1 - w).sqrt) + (b * w.sqrt);
		Out.ar(out, Pan2.ar(sig * env * In.kr(gbus), pan));
	}).add;
	// master: level, compensation, safety limiter
	SynthDef(\bsMaster, { |in, amp = 0.8, comp = 1, out = 0|
		var sig = In.ar(in, 2) * amp.lag(0.1) * comp.lag(1);
		Out.ar(out, Limiter.ar(sig, 0.95));
	}).add;

	// stereo places, filled farthest-point so any count is balanced
	slots = Array.interpolation(~bsMax, ~bsSpread.neg, ~bsSpread);
	chosen = [slots.minIndex { |x| x.abs }];
	(~bsMax - 1).do {
		var rest = (0..(~bsMax - 1)).reject { |k| chosen.includes(k) };
		chosen = chosen.add(rest.maxItem { |k| chosen.collect { |c| (slots[k] - slots[c]).abs }.minItem });
	};
	~bsPan = chosen.collect { |k| slots[k] };
	s.sync;

	~bsBus = Bus.audio(s, 2);
	~bsGrp = Group(s);
	~bsMasterSyn = Synth.after(~bsGrp, \bsMaster, [\in, ~bsBus, \amp, ~bsAmp, \comp, 1]);
	~bsMBus = Bus.control(s, ~bsMax);
	~bsGBus = Bus.control(s, ~bsMax);
	~bsSilent = Bus.control(s, 1).set(0);   // default modulation source
	~bsCtls = ~bsMax.collect { |v|
		Synth.head(~bsGrp, \bsCtl, [\mbus, ~bsMBus.index + v, \gbus, ~bsGBus.index + v,
			\modbus, ~bsSilent.index, \modamt, 0,
			\on, (v < ~bsN).asInteger, \fade, 0, \glide, ~bsGlide]);
	};
	s.sync;

	// ---- morph model: ALL + pitch-class offset + octave offset, or a per-voice override
	~bsAll = 0; ~bsPcOff = 0 ! 4; ~bsOctOff = 0 ! 4; ~bsOverride = nil ! ~bsMax;
	~bsMorphOf = { |v|
		var r = ~bsRenders[v % nr];
		~bsOverride[v] ?? { (~bsAll + ~bsPcOff[r.pc] + ~bsOctOff[r.oct]).clip(0, 1) };
	};
	~bsMorphNow = 0 ! ~bsMax;
	~bsPushMorph = {
		~bsMax.do { |v|
			var m = ~bsMorphOf.(v);
			if (m != ~bsMorphNow[v]) {
				~bsMorphNow[v] = m;
				~bsCtls[v].set(\glide, ~bsGlide, \morph, m);
			};
		};
		~bsDirty = true;
	};
	~bsCompFor = { |n| if (~bsComp) { n.max(1).sqrt.reciprocal } { 1 } };
	~bsSetN = { |n|
		~bsN = n.round.asInteger.clip(1, ~bsMax);
		~bsCtls.do { |c, v| c.set(\fade, ~bsFade, \on, (v < ~bsN).asInteger) };
		~bsMasterSyn.set(\comp, ~bsCompFor.(~bsN));
		~bsDirty = true;
	};

	// ---- the live collage: one routine per voice, grains only while audible
	~bsRouts = ~bsMax.collect { |v|
		var r = ~bsRenders[v % nr], bufs = ~bsBufs[v % nr];
		var rng = Pseed(v * 7919 + 21, Pwhite(0.0, 1.0)).asStream;   // per-voice stream
		Routine {
			(rng.next * 4).wait;       // desynchronise the start
			loop {
				var order = r.segs.scramble;
				order.do { |seg|
					var dur = seg[1] - seg[0];
					if (v < ~bsN or: { ~bsFadingOut.notNil and: { v < ~bsFadingOut } }) {
						var mf = ~bsMorphNow[v] * (ns - 1);
						var lo = mf.floor.clip(0, ns - 2).asInteger;
						s.bind {
							Synth.tail(~bsGrp, \bsGrain, [\bufA, bufs[lo], \bufB, bufs[lo + 1],
								\lo, lo, \start, seg[0], \dur, dur + ~bsXf, \xf, ~bsXf,
								\pan, ~bsPan[v], \mbus, ~bsMBus.index + v,
								\gbus, ~bsGBus.index + v, \out, ~bsBus]);
						};
					};
					dur.wait;
				};
			};
		}.play(SystemClock);
	};
	// voices that were just turned off keep playing grains until their fade ends
	~bsFadingOut = nil;
	~bsSetNFade = { |n|
		var old = ~bsN;
		~bsSetN.(n);
		if (~bsN < old) {
			~bsFadingOut = old;
			~bsFadeTask !? { ~bsFadeTask.stop };
			~bsFadeTask = { (~bsFade + 0.5).wait; ~bsFadingOut = nil }.fork(SystemClock);
		};
	};

	// ---- modulation routing: voice v's morph += In.kr(busIndex) * amt (server-side)
	~bsSetMod = { |v, busIndex, amt = 1|
		~bsCtls[v].set(\modbus, busIndex ? ~bsSilent.index, \modamt, amt) };
	~bsClearMod = { ~bsCtls.do(_.set(\modbus, ~bsSilent.index, \modamt, 0)) };

	// ---- OSC in (sensor / automation layers)
	OSCdef(\bsCount, { |msg| ~bsSetNFade.(msg[1]); ~bsGuiDirty = true }, '/swarm/count');
	OSCdef(\bsAllIn, { |msg| ~bsAll = msg[1].asFloat.clip(0, 1); ~bsPushMorph.value; ~bsGuiDirty = true }, '/swarm/all');
	OSCdef(\bsVoiceIn, { |msg| var i = msg[1].asInteger, x = msg[2].asFloat;
		if (i >= 0 and: { i < ~bsMax }) { ~bsOverride[i] = if (x < 0) { nil } { x.clip(0, 1) }; ~bsPushMorph.value } }, '/swarm/voice');
	OSCdef(\bsPcIn, { |msg| ~bsPcOff[msg[1].asInteger.clip(0, 3)] = msg[2].asFloat.clip(-1, 1); ~bsPushMorph.value; ~bsGuiDirty = true }, '/swarm/pc');
	OSCdef(\bsModIn, { |msg| var v = msg[1].asInteger;
		if (v >= 0 and: { v < ~bsMax }) { ~bsSetMod.(v, msg[2].asInteger, msg[3] ? 1) } }, '/swarm/mod');
	OSCdef(\bsOctIn, { |msg| ~bsOctOff[msg[1].asInteger.clip(0, 3)] = msg[2].asFloat.clip(-1, 1); ~bsPushMorph.value; ~bsGuiDirty = true }, '/swarm/oct');

	// ---------------- GUI ----------------
	~bsWin !? { if (~bsWin.isClosed.not) { ~bsWin.close } };
	~bsWin = Window("breath swarm (live collage)", Rect(80, 100, 1100, 560)).front;
	~bsCount = StaticText().align_(\center).font_(Font.default.size_(48).boldVariant);
	~bsInfo = StaticText().align_(\center).font_(Font.default.size_(13));
	~bsCountSlider = Slider().orientation_(\horizontal).fixedHeight_(48).step_(1 / (~bsMax - 1)).value_(0)
		.action_({ |sl| ~bsSetNFade.(1 + (sl.value * (~bsMax - 1))) });
	~bsMk = { |label, init, lo, act|
		var t = StaticText().string_("").align_(\center).fixedWidth_(56);
		var sl = Slider().orientation_(\vertical).fixedWidth_(34).minHeight_(180).step_(0.005)
			.value_(ControlSpec(lo, 1).unmap(init))
			.action_({ |x| var v = ControlSpec(lo, 1).map(x.value); act.(v); t.string = v.round(0.01).asString });
		t.string = init.round(0.01).asString;
		(view: VLayout(StaticText().string_(label).align_(\center).fixedWidth_(56)
			.font_(Font.default.boldVariant), HLayout(nil, sl, nil).margins_(0), t).spacing_(2),
		slider: sl, text: t, lo: lo);
	};
	~bsAllCtl = ~bsMk.("ALL", 0, 0, { |v| ~bsAll = v; ~bsPushMorph.value });
	~bsPcCtls = ["C", "Eb", "F", "Bb"].collect { |n, k|
		~bsMk.(n, 0, -1, { |v| ~bsPcOff[k] = v; ~bsPushMorph.value }) };
	~bsOctCtls = (2..5).collect { |o, k|
		~bsMk.("oct " ++ o, 0, -1, { |v| ~bsOctOff[k] = v; ~bsPushMorph.value }) };
	~bsVolT = StaticText().align_(\center).fixedWidth_(64);
	~bsVol = Slider().orientation_(\vertical).fixedWidth_(44).minHeight_(180)
		.value_(ControlSpec(-40, 6).unmap(~bsAmp.ampdb))
		.action_({ |sl| var db = ControlSpec(-40, 6).map(sl.value);
			~bsAmp = if (sl.value <= 0.001) { 0 } { db.dbamp }; ~bsMasterSyn.set(\amp, ~bsAmp);
			~bsVolT.string = if (~bsAmp == 0) { "-inf dB" } { db.round(0.5).asString ++ " dB" } });
	~bsVolT.string = ~bsAmp.ampdb.round(0.5).asString ++ " dB";
	~bsFadeBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~bsFade).fixedWidth_(56).action_({ |nb| ~bsFade = nb.value });
	~bsGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~bsGlide).fixedWidth_(56).action_({ |nb| ~bsGlide = nb.value });
	~bsCompBtn = Button().states_([["level comp off", Color.black, Color.white],
		["level comp ON", Color.white, Color.blue(0.5)]]).fixedWidth_(120).value_(~bsComp.asInteger)
		.action_({ |b| ~bsComp = (b.value == 1); ~bsMasterSyn.set(\comp, ~bsCompFor.(~bsN)) });
	~bsWin.layout = HLayout([VLayout(
		~bsCount, ~bsInfo, ~bsCountSlider,
		HLayout(StaticText().string_("1"), nil, StaticText().string_(~bsMax.asString ++ " voices (6^3)")),
		StaticText().string_("morph: bottom = breath, top = harmonium.  voice morph = ALL + pitch offset + octave offset")
			.fixedHeight_(18),
		HLayout(~bsAllCtl.view, [nil, stretch: 0], StaticText().string_("  |  ").fixedWidth_(20),
			*(~bsPcCtls.collect(_.view) ++ [StaticText().string_("  |  ").fixedWidth_(20)]
				++ ~bsOctCtls.collect(_.view) ++ [nil])),
		HLayout(StaticText().string_("fade s"), ~bsFadeBox, StaticText().string_("morph glide s"), ~bsGlideBox,
			~bsCompBtn, nil, StaticText().string_(nr.asString ++ " renders, live collage, OSC /swarm/* on "
				++ NetAddr.langPort))
	), stretch: 1],
		VLayout(StaticText().string_("volume").align_(\center).font_(Font.default.boldVariant),
			HLayout(nil, ~bsVol, nil).margins_(0), ~bsVolT).spacing_(4));

	~bsDirty = true; ~bsGuiDirty = false;
	~bsRout = Routine { loop {
		if (~bsGuiDirty) {   // OSC moved something: mirror it onto the sliders
			~bsGuiDirty = false;
			~bsCountSlider.value = (~bsN - 1) / (~bsMax - 1);
			~bsAllCtl.slider.value = ~bsAll; ~bsAllCtl.text.string = ~bsAll.round(0.01).asString;
			4.do { |k|
				~bsPcCtls[k].slider.value = ControlSpec(-1, 1).unmap(~bsPcOff[k]);
				~bsPcCtls[k].text.string = ~bsPcOff[k].round(0.01).asString;
				~bsOctCtls[k].slider.value = ControlSpec(-1, 1).unmap(~bsOctOff[k]);
				~bsOctCtls[k].text.string = ~bsOctOff[k].round(0.01).asString;
			};
		};
		if (~bsDirty) {
			var act = (0..(~bsN - 1)), mean = act.collect { |v| ~bsMorphNow[v] }.mean;
			~bsDirty = false;
			~bsCount.string = ~bsN.asString ++ if (~bsN == 1) { " voice" } { " voices" };
			~bsInfo.string = "mean morph " ++ (mean * 100).round.asInteger ++ "%    "
				++ ["C", "Eb", "F", "Bb"].collect { |n, k|
					n ++ " " ++ act.count { |v| ~bsRenders[v % nr].pc == k } }.join("  ");
		};
		0.25.wait;
	} }.play(AppClock);
	~bsPushMorph.value;
	~bsWin.onClose = {
		~bsRout.stop; ~bsRouts.do(_.stop); ~bsGrp.free; ~bsMasterSyn.free;
		~bsBufs.flat.do(_.free); ~bsSilent.free; ~bsMBus.free; ~bsGBus.free; ~bsBus.free;
		[\bsCount, \bsAllIn, \bsVoiceIn, \bsPcIn, \bsOctIn, \bsModIn].do { |k| OSCdef(k).free };
	};
	"BREATH_SWARM_READY".postln;
	};
};
)
