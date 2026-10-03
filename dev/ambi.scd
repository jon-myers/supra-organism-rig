/*
ambi.scd (rig/dev/, 2026-10-01) -- first-order AMBISONICS for the rig with the Ambisonic Toolkit (ATK v5.0.7 quark,
sc3-plugins 3.14.1 arm64, ATK matrices v1.0.3). One 4-channel B-format bus, decoded TWO ways at once:

  QUAD      FoaDecoderMatrix.newQuad (square, speakers at +-45 / +-135 deg) -> the interface's outs 3-6.
            ATK speaker order is FL, BL, BR, FR; the SPEAKER MAP says which physical output each one is
            (default = breath36's "circle order": 3 FL, 4 FR, 5 BR, 6 BL). "identify" plays a pink-noise burst
            from each speaker in turn, named, so the map can be checked by ear. Decoder type menu:
            energy (max-rE, default: good over a wide listening area), controlled (in-phase, safest for a
            spread-out audience: no antiphase), dual (psychoacoustic shelf, best for ONE central listener),
            velocity, single.
  BINAURAL  FoaDecoderKernel (HRTF convolution) -> Phones 1 on the Fireface UCX II = outs 7/8 (SC buses 6-7):
            the phones get the binaural mix directly, no TotalMix routing. HRTF menu: CIPIC subjects (21 =
            KEMAR large pinna), Listen subjects, spherical head. Checked 2026-10-01: a source hard left gives
            L-R +17.5 dB (2.5 kHz+ noise), hard right -18.7, front 0.6, back 1.3.
  TotalMix buttons: "phones = binaural only" takes the speaker feeds (playback 1-6) out of the Phones 1 mix (so the
  phones are not hearing quad feeds AND binaural); "phones = speaker feeds" puts 1/2, 3/4, 5/6 back. Uses `tmix`
  (claude-skills/totalmix) over OSC.

FOR OTHER PATCHES: write B-format to ~ambiBus (4 ch: W X Y Z). A mono source at azimuth az (radians, + = LEFT,
0 = front) and elevation el:   Out.ar(~ambiBus.index, FoaPanB.ar(sig, az, el))
The decoders run in ~ambiGrp at the TAIL of the server, after the default group, so any synth in the default
group can write to the bus.
BREATH36: tick "AMBI" in this tab and each new breath is encoded at its own position (breath36's quad azimuths x pi,
36 even steps round the circle) instead of the stereo/quad panner. Needs breath36 loaded first (it reads ~b36Meta).
Test source: pink-noise bursts circling the room (period s), to hear the decode without the rig.
DISPLAY: redraws at most 4 times a second (vestibular migraine).
*/
(
~ambiP = ~ambiP ? (quadOn: true, binOn: true, quadDb: 0, binDb: 0, quadType: 0, hrtf: 0, quadMap: [2, 5, 4, 3],   // ATK order FL BL BR FR -> outs 3 6 5 4 = circle order 3 FL, 4 FR, 5 BR, 6 BL (fixed 2026-10-01: was [2,3,4,5], which put BL on 4 and FR on 6)
	
	binOuts: [6, 7], testOn: false, testPeriod: 8, testDb: -18);
~ambiP[\posMode] = ~ambiP[\posMode] ? 1; ~ambiP[\posSeed] = ~ambiP[\posSeed] ? 2026; ~ambiP[\elSpread] = ~ambiP[\elSpread] ? 0;
// BREATH POSITIONS in the ambisonic field (azimuth radians, + = left; elevation radians, heard on the binaural only --
// the quad decoder is horizontal): 0 = breath36's even circle, 1 = random with even coverage (the 36 even slots shuffled,
// each jittered up to half a slot: random, never clumped), 2 = fully random. Re-roll = a new seed. New positions apply
// from each voice's next breath.
~ambiPos = { var n = 36, step = 2pi / n;
	thisThread.randSeed = ~ambiP[\posSeed];
	~ambiAz = switch (~ambiP[\posMode],
		0, { nil },
		1, { (0..(n - 1)).scramble.collect { |k| ((k + 0.5.rand2) * step).wrap(-pi, pi) } },
		2, { n.collect { pi.rand2 } });
	~ambiEl = if (~ambiP[\elSpread] > 0) { n.collect { ~ambiP[\elSpread].degrad.rand2 } } { nil };
	~ambiPosView !? { |v| { v.refresh }.defer } };
~ambiPos.();
if (~ambiP[\quadMap] == [2, 3, 4, 5]) { ~ambiP[\quadMap] = [2, 5, 4, 3] };   // a session still holding the pre-fix default
~ambiQuadTypes = ['energy', 'controlled', 'dual', 'velocity', 'single'];
~ambiHrtfs = [["CIPIC 21 (KEMAR, large pinna)", \cipic, 21], ["CIPIC 165 (KEMAR, small pinna)", \cipic, 165],
	["CIPIC 3", \cipic, 3], ["Listen 1002", \listen, 1002], ["Listen 1013", \listen, 1013], ["spherical head (subject 4)", \spherical, 4]];
~ambiSpkNames = ["front-left", "back-left", "back-right", "front-right"];   // ATK newQuad channel order
s = Server.default;
// display rate limit (Jon: nothing on screen may change faster than 4 times a second -- vestibular migraine): the
// same shared routine breath36 starts; started here too if ambi runs on its own
~uiPending = ~uiPending ? IdentityDictionary.new;
~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
// AMBI is the DEFAULT for the breaths and the wall once this tab loads (2026-10-01, Jon expected it on); untick to go back
// to their stereo / quad panning. Set ~ambiDefaultOn = false before loading to keep them off.
if (~ambiDefaultOn ? true) { ~b36Ambi = true; ~wlAmbi = true };
if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
	~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
		p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
s.waitForBoot {
	var outsMax = s.options.numOutputBusChannels - 1;
	// ---- tear down a previous evaluation (synchronously) ----
	~ambiWin !? { if (~ambiWin.isClosed.not) { ~ambiWin.onClose = nil; ~ambiWin.close } };
	~ambiRout !? { ~ambiRout.stop }; ~ambiIdRout !? { ~ambiIdRout.stop };
	~ambiGrp !? { ~ambiGrp.free }; ~ambiTestGrp !? { ~ambiTestGrp.free };
	~ambiBinDec !? { try { ~ambiBinDec.free } }; ~ambiBinDec = nil;
	~ambiBus = ~ambiBus ?? { Bus.audio(s, 4) };
	if (~ambiBus.server != s) { ~ambiBus = Bus.audio(s, 4) };
	// the Rite of Spring tab (dev/rite_live.scd) loads BEFORE this one: switch it to the field now that ~ambiBus exists
	if (~ambiDefaultOn ? true) { ~rtSetAmbi !? { ~rtSetAmbi.(true); { ~rtAmbiBox !? { ~rtAmbiBox.value = ~rtAmbi } }.defer } };
	if (outsMax < 7) { ("ambi: the server has only " ++ (outsMax + 1) ++ " outputs -- binaural on 7/8 needs 8 (the dev launcher opens 8)").warn };

	// ---- decoders: rebuilt when the HRTF or quad type changes (kernels are baked into the SynthDef) ----
	~ambiBuild = {
		var h = ~ambiHrtfs[~ambiP[\hrtf]], quad = FoaDecoderMatrix.newQuad(pi/4, ~ambiQuadTypes[~ambiP[\quadType]]);
		var old = ~ambiBinDec;
		~ambiBinDec = switch (h[1],
			\cipic, { FoaDecoderKernel.newCIPIC(h[2], s, s.sampleRate.asInteger) },
			\listen, { FoaDecoderKernel.newListen(h[2], s, s.sampleRate.asInteger) },
			\spherical, { FoaDecoderKernel.newSpherical(h[2], s, s.sampleRate.asInteger) });
		s.sync;
		SynthDef(\ambiQuad, { |in, quadAmp = 1, quadOn = 1|
			var q = FoaDecode.ar(In.ar(in, 4), quad) * (quadAmp * quadOn).lag(0.1);
			var map = \map.kr([2, 5, 4, 3]);
			4.do { |c| Out.ar(map[c], q[c]) };
		}).add;
		SynthDef(\ambiBin, { |in, binAmp = 1, binOn = 1|
			var b = FoaDecode.ar(In.ar(in, 4), ~ambiBinDec) * (binAmp * binOn).lag(0.1);
			Out.ar(\outs.kr([6, 7]), b);
		}).add;
		s.sync;
		~ambiGrp !? { ~ambiGrp.free };
		~ambiGrp = Group.tail(s);
		~ambiQuadSyn = Synth(\ambiQuad, [\in, ~ambiBus.index, \map, ~ambiP[\quadMap], \quadAmp, ~ambiP[\quadDb].dbamp, \quadOn, ~ambiP[\quadOn].asInteger], ~ambiGrp);
		~ambiBinSyn = Synth(\ambiBin, [\in, ~ambiBus.index, \outs, ~ambiP[\binOuts], \binAmp, ~ambiP[\binDb].dbamp, \binOn, ~ambiP[\binOn].asInteger], ~ambiGrp);
		old !? { { try { old.free } }.defer(1) };   // the old kernels' buffers, once nothing reads them
		("AMBI decoders: quad " ++ ~ambiQuadTypes[~ambiP[\quadType]] ++ " -> outs " ++ (~ambiP[\quadMap] + 1) ++ ", binaural " ++ h[0] ++ " -> outs " ++ (~ambiP[\binOuts] + 1)).postln;
	};

	// ---- test source: pink-noise bursts circling ----
	SynthDef(\ambiTest, { |out, period = 8, amp = 0.125|
		var az = LFSaw.kr(period.reciprocal).range(0, 2pi);
		var sig = PinkNoise.ar(amp) * Decay2.ar(Impulse.ar(4), 0.01, 0.2);
		Out.ar(out, FoaPanB.ar(sig, az, 0));
	}).add;
	// identify: one speaker at a time, straight to its output (bypasses the decoder)
	SynthDef(\ambiId, { |out, amp = 0.1| Out.ar(out, PinkNoise.ar(amp) * EnvGen.kr(Env.linen(0.05, 0.9, 0.05), doneAction: 2)) }).add;
	// breath36 in ambisonics: \b36Seg's body, encoded with FoaPanB instead of panned
	if (~b36Meta.notNil) {
		var ns = ~b36Meta["slots"].size;
		SynthDef(\b36SegA, { |hpf = 70, start = 0, dur = 1, fade = 0.04, morphBus, gainBus, az = 0, el = 0, amp = 0.8, comp = 1, out = 0, vol = 0.8|
			var bufs = \bufs.kr(0 ! ns);
			var m = In.kr(morphBus) * (ns - 1);
			var env = EnvGen.kr(Env.linen(fade, (dur - fade).max(0.001), fade, 1, \lin), doneAction: 2);
			var sig = ns.collect { |i|
				var w = (1 - (m - i).abs).clip(0, 1).sqrt;
				PlayBuf.ar(1, bufs[i], BufRateScale.kr(bufs[i]), 1, start, 0) * w
			}.sum;
			sig = BHiPass.ar(BHiPass.ar(sig, hpf.max(10)), hpf.max(10));   // low cut (breath mic rumble)
			Out.ar(out, FoaPanB.ar(sig * env * In.kr(gainBus) * amp.lag(0.1) * vol.lag(0.1) * comp.lag(1), az, el));
		}).add;
	} { "ambi: breath36 not loaded -- the AMBI breath mode is unavailable until it is (re-evaluate this after)".warn };
	s.sync;
	~ambiBuild.();
	~ambiTestGrp = Group.head(s);   // test source writes to the bus ahead of the decoders
	~ambiSetTest = { |on| ~ambiP[\testOn] = on; ~ambiTestSyn !? { ~ambiTestSyn.free }; ~ambiTestSyn = nil;
		if (on) { ~ambiTestSyn = Synth(\ambiTest, [\out, ~ambiBus.index, \period, ~ambiP[\testPeriod], \amp, ~ambiP[\testDb].dbamp], ~ambiTestGrp) } };
	~ambiIdentify = { ~ambiIdRout !? { ~ambiIdRout.stop };
		~ambiIdRout = Routine { 4.do { |c| var o = ~ambiP[\quadMap][c];
			{ ~ambiIdText !? { ~ambiIdText.string = "now: " ++ ~ambiSpkNames[c] ++ " = out " ++ (o + 1) } }.defer;
			s.bind { Synth(\ambiId, [\out, o], ~ambiTestGrp) }; 1.5.wait };
			{ ~ambiIdText !? { ~ambiIdText.string = "" } }.defer }.play(SystemClock) };
	~ambiTmix = { |mode| var t = "~/Documents/productivity/claude-skills/totalmix/tmix.py".standardizePath, db = if (mode == \binaural) { -70 } { 0 };
		[1, 3, 5].do { |ch| (t ++ " route play " ++ ch ++ " out 7 --db " ++ db).unixCmd { |code, pid| } };
		("ambi: TotalMix Phones 1 mix -> " ++ if (mode == \binaural) { "binaural only (playback 1-6 sends at -oo)" } { "speaker feeds 1-6 at 0 dB" }).postln };

	// ---------------- GUI ----------------
	~ambiWin = if (~stHost.notNil) { ~stHost.(\ambi) } { Window("ambisonics (ATK): quad + binaural", Rect(200, 120, 820, 420)).front };
	{
		var bold = Font.default.boldVariant, dbSl, mapMenus, onBox;
		dbSl = { |key, synthFn, param|
			var txt = StaticText().string_(~ambiP[key].round(0.5).asString ++ " dB").fixedWidth_(60);
			[Slider().orientation_(\horizontal).fixedHeight_(22).value_(ControlSpec(-40, 6).unmap(~ambiP[key]))
				.action_({ |sl| ~ambiP[key] = ControlSpec(-40, 6).map(sl.value).round(0.5);
					synthFn.value !? { |sy| sy.set(param, ~ambiP[key].dbamp) };
					~uiLater.(key, { txt.string = ~ambiP[key].asString ++ " dB" }) }), txt] };
		onBox = { |label, key, synthFn, param| CheckBox().string_(label).value_(~ambiP[key])
			.action_({ |c| ~ambiP[key] = c.value; synthFn.value !? { |sy| sy.set(param, c.value.asInteger) } }) };
		mapMenus = 4.collect { |c| PopUpMenu().items_((0..outsMax).collect { |o| "out " ++ (o + 1) }).value_(~ambiP[\quadMap][c]).fixedWidth_(80)
			.action_({ |m| ~ambiP[\quadMap][c] = m.value; ~ambiQuadSyn !? { ~ambiQuadSyn.set(\map, ~ambiP[\quadMap]) } }) };
		~ambiIdText = StaticText().string_("").fixedWidth_(220);
		// top view of the 36 breath positions (static: redrawn only when they change)
		~ambiPosView = UserView().fixedSize_(Size(150, 150)).background_(Color.grey(0.96)).drawFunc_({ |uv|
			var c = 75 @ 75, r = 60, az = ~ambiAz ?? { (~b36Azim ? (0 ! 36)) * pi };
			Pen.strokeColor = Color.grey(0.7); Pen.addOval(Rect(15, 15, 120, 120)); Pen.stroke;
			"front".drawAtPoint(62 @ 0, Font.default.size_(9), Color.grey(0.4));
			4.do { |k| var a = (k * 0.5pi) + 0.25pi; Pen.fillColor = Color.grey(0.5);   // speakers at +-45 / +-135
				Pen.fillRect(Rect(c.x - (sin(a) * r * 1.15) - 3, c.y - (cos(a) * r * 1.15) - 3, 6, 6)) };
			az.do { |a, i| var p = Point(c.x - (sin(a) * r), c.y - (cos(a) * r));   // + azimuth = left
				Pen.fillColor = Color(0.25, 0.45, 0.75); Pen.fillOval(Rect(p.x - 3, p.y - 3, 6, 6));
				(i + 1).asString.drawAtPoint((p.x + 3) @ (p.y - 6), Font.default.size_(7), Color.grey(0.3)) } });
		~ambiPosMenu = PopUpMenu().items_(["even circle (breath36 order)", "random, even coverage", "fully random"]).value_(~ambiP[\posMode]).fixedWidth_(190)
			.action_({ |m| ~ambiP[\posMode] = m.value; ~ambiPos.() });
		~ambiElBox = NumberBox().clipLo_(0).clipHi_(90).decimals_(0).step_(5).scroll_step_(5).value_(~ambiP[\elSpread]).fixedWidth_(46)
			.action_({ |b| ~ambiP[\elSpread] = b.value; ~ambiPos.() });
		~ambiWallBox = CheckBox().string_("WALL OF SOUND -> AMBI (new events; out-of-tune chords very wide)").value_(~wlAmbi == true)
			.action_({ |c| if (c.value and: { ~wlFire.isNil }) { "ambi: load wall_live first".warn; c.value = false } { ~wlAmbi = c.value } });
		~ambiRoomBoxes = ["dyads", "voices", "chords"].collect { |n, l| NumberBox().clipLo_(-60).clipHi_(0).decimals_(0).step_(1).scroll_step_(1).fixedWidth_(46)
			.value_(((~wlRoomDb ? [-inf, -inf, -20])[l]).max(-60)).action_({ |b| ~wlRoomDb = (~wlRoomDb ? [-inf, -inf, -20]); ~wlRoomDb[l] = b.value }) };
		~ambiB36Box = CheckBox().string_("36 BREATHS -> AMBI (instead of stereo / quad panning)").value_(~b36Ambi == true)
			.action_({ |c| if (c.value and: { ~b36Meta.isNil }) { "ambi: load breath36 first".warn; c.value = false } { ~b36Ambi = c.value } });
		~ambiWin.layout = VLayout(
			StaticText().string_("AMBISONICS (first order, ATK) -- one B-format bus, two decoders at once").font_(Font.default.size_(15).boldVariant),
			HLayout(onBox.("QUAD speakers", \quadOn, { ~ambiQuadSyn }, \quadOn), *(dbSl.(\quadDb, { ~ambiQuadSyn }, \quadAmp) ++ [
				StaticText().string_("decoder"), PopUpMenu().items_(~ambiQuadTypes.collect(_.asString)).value_(~ambiP[\quadType]).fixedWidth_(110)
					.action_({ |m| ~ambiP[\quadType] = m.value; fork { ~ambiBuild.() } })])),
			HLayout(*(4.collect { |c| VLayout(StaticText().string_(~ambiSpkNames[c]).font_(bold), mapMenus[c]) } ++ [
				Button().states_([["identify speakers"]]).action_({ ~ambiIdentify.() }), ~ambiIdText, nil])),
			HLayout(onBox.("BINAURAL -> phones (outs " ++ (~ambiP[\binOuts] + 1).join("/") ++ ")", \binOn, { ~ambiBinSyn }, \binOn),
				*(dbSl.(\binDb, { ~ambiBinSyn }, \binAmp) ++ [StaticText().string_("HRTF"),
				PopUpMenu().items_(~ambiHrtfs.collect(_[0])).value_(~ambiP[\hrtf]).fixedWidth_(230)
					.action_({ |m| ~ambiP[\hrtf] = m.value; fork { ~ambiBuild.() } })])),
			HLayout(StaticText().string_("TotalMix phones:"), Button().states_([["phones = binaural only"]]).action_({ ~ambiTmix.(\binaural) }),
				Button().states_([["phones = speaker feeds"]]).action_({ ~ambiTmix.(\feeds) }), nil),
			HLayout(onBox.("TEST: noise bursts circling", \testOn, nil, nil).action_({ |c| ~ambiSetTest.(c.value) }),
				StaticText().string_("period s"), NumberBox().value_(~ambiP[\testPeriod]).clipLo_(1).clipHi_(60).decimals_(0).fixedWidth_(46)
					.action_({ |b| ~ambiP[\testPeriod] = b.value; ~ambiTestSyn !? { ~ambiTestSyn.set(\period, b.value) } }),
				*(dbSl.(\testDb, { ~ambiTestSyn }, \amp) ++ [nil])),
			HLayout(~ambiWallBox, StaticText().string_("   room dB (-60 = none):  dyads"), ~ambiRoomBoxes[0],
				StaticText().string_("voices"), ~ambiRoomBoxes[1], StaticText().string_("chords"), ~ambiRoomBoxes[2], nil),
			HLayout(VLayout(~ambiB36Box,
				HLayout(StaticText().string_("breath positions"), ~ambiPosMenu,
					Button().states_([["re-roll"]]).action_({ ~ambiP[\posSeed] = Date.getDate.rawSeconds.asInteger; ~ambiPos.() }), nil),
				HLayout(StaticText().string_("random elevation +- deg (binaural only)"), ~ambiElBox, nil), nil), ~ambiPosView),
			StaticText().string_("Other patches: Out.ar(~ambiBus.index, FoaPanB.ar(sig, azimuth, elevation))   (azimuth radians, + = left, 0 = front)").font_(Font.default.size_(11)),
			nil);
	}.defer;
	~ambiWin.onClose = { ~ambiIdRout !? { ~ambiIdRout.stop }; ~ambiGrp !? { ~ambiGrp.free }; ~ambiGrp = nil;
		~ambiTestGrp !? { ~ambiTestGrp.free }; ~ambiTestGrp = nil; ~ambiTestSyn = nil; ~b36Ambi = false;
		~ambiBinDec !? { try { ~ambiBinDec.free } }; ~ambiBinDec = nil };
	"AMBI_READY".postln;
};
)
