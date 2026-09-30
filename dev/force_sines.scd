/*
force_sines.scd -- the simplest possible sonification of the force signals: one sine wave per sensor (2026-09-30).
Reads the FORCE tab's buses (force_hub.scd must be loaded), so it plays whatever source that tab is on (the dancers'
hardware, the simulator, the faders, a recording). Its own window; touches nothing else. Select all, evaluate.

  default mapping   DC (force) -> loudness: silent at rest, louder the harder the press
                    AC (change) -> pitch bend: a press bends up, a release bends down (+-"bend" semitones at AC = +-1)
  swap              DC -> pitch (rest = the sensor's note, full press = up "bend" semitones), AC -> loudness (|AC|)
  pitches           six notes of a D-minor-ish pentatonic spread over two octaves (sensor 1 lowest), panned L..R
  central           optional low drone on sensor 7 (the average), off by default
  master            dB, bottom = off. A limiter follows.
The display only changes 4 times a second at most (Jon: vestibular migraine).
*/
(
~fsP = ~fsP ? (on: 1, amp: -18.dbamp, bend: 2, swap: 0, gain: 1.3, central: 0, smooth: 0.03);
~fsMute = ~fsMute ? (false ! 6);
~fsNotes = [50, 53, 57, 60, 62, 65];   // D3 F3 A3 C4 D4 F4 (MIDI)
s = Server.default;
s.waitForBoot {
	// ---- tear down a previous evaluation ----
	~fsWin !? { if (~fsWin.isClosed.not) { ~fsWin.onClose = nil; ~fsWin.close } };
	~fsRout !? { ~fsRout.stop }; ~fsSynth !? { ~fsSynth.free }; ~fsSynth = nil;
	if (~fhBus.isNil) { "force_sines: no FORCE tab buses (~fhBus) -- load force_hub.scd (or the dev launcher) first".warn } {
	SynthDef(\fsSines, { |in = 0, out = 0, on = 1, amp = 0.1, bend = 2, swap = 0, gain = 1.3, central = 0, smooth = 0.03|
		var dc = In.kr(in, 7), ac = In.kr(in + 7, 7), mutes = \mutes.kr(0 ! 6);
		var sig = 6.collect { |k|
			var d = Lag.kr(dc[k], smooth), a = Lag.kr(ac[k], smooth);
			var lvl = Select.kr(swap, [(d * gain).clip(0, 1), (a.abs * gain * 4).clip(0, 1)]);
			var semis = Select.kr(swap, [a.clip(-1, 1) * bend, d.clip(0, 1) * bend]);
			var freq = (~fsNotes[k] + semis).midicps;
			Pan2.ar(SinOsc.ar(freq) * lvl.squared * (1 - mutes[k]), k.linlin(0, 5, -0.8, 0.8))
		}.sum;
		var drone = SinOsc.ar((38 + (Lag.kr(ac[6], smooth).clip(-1, 1) * bend)).midicps) * (Lag.kr(dc[6], smooth) * gain).clip(0, 1).squared * central * 0.7;
		Out.ar(out, Limiter.ar((sig + drone) * amp.lag(0.1) * on.lag(0.05), 0.9, 0.01));
	}).add;
	s.sync;
	~fsSynth = Synth.tail(s, \fsSines, [\in, ~fhBus.index, \on, ~fsP[\on], \amp, ~fsP[\amp], \bend, ~fsP[\bend], \swap, ~fsP[\swap],
		\gain, ~fsP[\gain], \central, ~fsP[\central], \smooth, ~fsP[\smooth], \mutes, ~fsMute.collect(_.asInteger)]);
	~fsSet = { |key, v| ~fsP[key] = v; ~fsSynth !? { ~fsSynth.set(key, v) } };

	// ---- GUI (static except one 4 Hz readout) ----
	~fsWin = Window("force -> sine waves", Rect(140, 140, 640, 260)).front;
	~fsDbSpec = ControlSpec(-60, 6);
	~fsDbStr = { |a| if (a <= 0.001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } };
	~fsOnBtn = Button().states_([["OFF", Color.black, Color.grey(0.85)], ["ON", Color.white, Color.green(0.45)]]).fixedWidth_(70).value_(~fsP[\on])
		.action_({ |b| ~fsSet.(\on, b.value) });
	~fsVolTxt = StaticText().string_(~fsDbStr.(~fsP[\amp])).fixedWidth_(70).font_(Font.default.size_(15).boldVariant);
	~fsVol = Slider().orientation_(\horizontal).fixedHeight_(30).value_(~fsDbSpec.unmap(~fsP[\amp].ampdb))
		.action_({ |sl| var a = if (sl.value <= 0.001) { 0 } { ~fsDbSpec.map(sl.value).dbamp }; ~fsSet.(\amp, a);
			~uiLater !? { ~uiLater.(\fsVol, { ~fsVolTxt.string = ~fsDbStr.(a) }) } ?? { ~fsVolTxt.string = ~fsDbStr.(a) } });
	~fsSwap = PopUpMenu().items_(["DC -> loudness, AC -> pitch bend", "DC -> pitch, AC -> loudness"]).value_(~fsP[\swap]).fixedWidth_(260)
		.action_({ |m| ~fsSet.(\swap, m.value) });
	~fsBend = NumberBox().value_(~fsP[\bend]).clipLo_(0).clipHi_(24).step_(0.5).scroll_step_(0.5).decimals_(1).fixedWidth_(50).action_({ |b| ~fsSet.(\bend, b.value) });
	~fsGain = NumberBox().value_(~fsP[\gain]).clipLo_(0.1).clipHi_(10).step_(0.1).scroll_step_(0.1).decimals_(1).fixedWidth_(50).action_({ |b| ~fsSet.(\gain, b.value) });
	~fsCentral = CheckBox().string_("central (7) as a low drone").value_(~fsP[\central] == 1).action_({ |c| ~fsSet.(\central, c.value.asInteger) });
	~fsMuteBoxes = 6.collect { |k| CheckBox().string_("mute " ++ (k + 1)).value_(~fsMute[k])
		.action_({ |c| ~fsMute[k] = c.value; ~fsSynth !? { ~fsSynth.seti(\mutes, k, c.value.asInteger) } }) };
	~fsStatus = StaticText().string_("").fixedHeight_(18);
	~fsWin.layout = VLayout(
		HLayout(~fsOnBtn, StaticText().string_("VOLUME").font_(Font.default.boldVariant), ~fsVol, ~fsVolTxt),
		HLayout(StaticText().string_("mapping"), ~fsSwap, nil, StaticText().string_("bend (semitones)"), ~fsBend, StaticText().string_("sensitivity x"), ~fsGain),
		HLayout(*(~fsMuteBoxes ++ [nil])), HLayout(~fsCentral, nil),
		StaticText().string_("notes: 1 D3  2 F3  3 A3  4 C4  5 D4  6 F4, panned left to right").font_(Font.default.size_(11)).stringColor_(Color.grey(0.35)),
		~fsStatus, nil);
	~fsRout = Routine { loop {
		~fsStatus.string = "FORCE source: " ++ (~fhP !? { |p| p[\source] } ? "?") ++ "   |   DC now " ++ ((~fhValues ? (0 ! 14)).keep(6).collect { |x| x.round(0.01) });
		0.25.wait } }.play(AppClock);
	~fsWin.onClose = { ~fsRout.stop; ~fsSynth !? { ~fsSynth.free }; ~fsSynth = nil };
	"FORCE_SINES_READY".postln;
	};
};
)
