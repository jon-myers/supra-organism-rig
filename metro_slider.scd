/*
metro_slider.scd -- one slider, logarithmic tempo, live click.
Slider left = LO BPM (default 30), right = HI BPM (default 80), equal slider
distance = equal tempo RATIO (log map), so 30->40 feels like 60->80.
The tempo glides server-side (glide s), so moves are smooth, never stepped.
Readout shows the ACTUAL tempo the click is at, 4x a second. No animation.
Select all, evaluate.
*/
(
~msInDevice  = "MacBook Pro Microphone";   // nil = system default
~msOutDevice = "External Headphones";      // nil = system default
~msLo = 30; ~msHi = 80; ~msBpm = 30; ~msGlide = 0.5; ~msAmp = 0.5; ~msVoice = 0;
~msCycle = 10;      // beats per cycle; beat 1 of each cycle is the high click
~msAccent = 1.5;    // pitch ratio of beat 1 (1.5 = a fifth up)

s = Server.default;
~msInDevice  !? { s.options.inDevice  = ~msInDevice };
~msOutDevice !? { s.options.outDevice = ~msOutDevice };

s.waitForBoot {
	SynthDef(\msClick, { |bpm = 30, glide = 0.5, amp = 0.5, voice = 0, out = 0,
		cycle = 10, accent = 1.5|
		var tempo = Lag.kr(bpm, glide);
		// Impulse integrates its frequency, so tempo changes bend the pulse
		// smoothly instead of restarting it
		var trig = Impulse.ar(tempo / 60);
		// beat number since start (1, 2, 3 ...); beat 1 of each cycle is high
		var count = PulseCount.ar(trig);
		var isOne = ((count - 1) % cycle.max(1).round) < 0.5;
		var ratio = Latch.ar(Select.ar(isOne, [DC.ar(1), K2A.ar(accent)]), trig);
		// tock: pyramid-metronome style decaying partials + noise transient
		var tock = [1050, 1900, 3250].collect { |f, i|
			SinOsc.ar(f * ratio) * Decay2.ar(trig, 0.0005, [0.06, 0.04, 0.025][i]) * [1, 0.5, 0.3][i]
		}.sum + (BPF.ar(WhiteNoise.ar, 3000, 0.5) * Decay2.ar(trig, 0.0002, 0.004) * 2);
		// beep: Reaper-style 4.5 ms burst of 880 Hz
		var beep = SinOsc.ar(880 * ratio) * EnvGen.ar(Env.linen(0.0005, 0.0035, 0.0005), trig);
		var sig = Limiter.ar(Select.ar(voice, [tock * 0.6, beep]) * amp.lag(0.05), 0.95);
		SendReply.kr(Impulse.kr(4), '/msTempo', A2K.kr(tempo));
		SendReply.ar(trig, '/msBeat', count);
		Out.ar(out, sig ! 2);
	}).add;
	s.sync;

	~msToBpm  = { |v| ~msLo * ((~msHi / ~msLo) ** v.clip(0, 1)) };
	~msToPos  = { |b| ((b / ~msLo).log / (~msHi / ~msLo).log).clip(0, 1) };
	~msSet = { |b|
		~msBpm = b.clip(1, 400);
		~msSynth !? { ~msSynth.set(\bpm, ~msBpm, \glide, ~msGlide) };
		{ ~msTarget.string = "target " ++ ~msBpm.round(0.1) ++ " BPM" }.defer;
	};
	~msBeats = 0;
	~msStart = {
		~msSynth ?? {
			~msBeats = 0;
			~msSynth = Synth(\msClick, [\bpm, ~msBpm, \glide, 0, \amp, ~msAmp, \voice, ~msVoice,
				\cycle, ~msCycle, \accent, ~msAccent]);
		};
		{ ~msRunBtn.value = 1 }.defer;
	};
	~msStop = {
		~msSynth !? { ~msSynth.free; ~msSynth = nil };
		{ ~msRunBtn.value = 0; ~msNow.string = "stopped" }.defer;
	};

	OSCdef(\msTempo, { |msg|
		{ if (~msSynth.notNil) { ~msNow.string = msg[3].round(0.1).asString ++ " BPM" } }.defer;
	}, '/msTempo');
	OSCdef(\msBeat, { |msg|
		var n = msg[3].asInteger, c = ~msCycle.max(1);
		~msBeats = n;
		{ ~msBeatText.string = "beat " ++ (((n - 1) % c) + 1) ++ " of " ++ c
			++ "     cycle " ++ ((n - 1).div(c) + 1) ++ "     total " ++ n }.defer;
	}, '/msBeat');

	// ---------------- GUI ----------------
	~msWin !? { if (~msWin.isClosed.not) { ~msWin.close } };
	~msWin = Window("metronome slider", Rect(120, 200, 900, 330)).front;
	~msNow = StaticText().string_("30.0 BPM").font_(Font.default.size_(72).boldVariant)
		.align_(\center);
	~msTarget = StaticText().string_("target 30 BPM").align_(\center)
		.font_(Font.default.size_(16));
	~msBeatText = StaticText().string_("beat 0").align_(\center).font_(Font.default.size_(16));
	~msSlider = Slider().orientation_(\horizontal).fixedHeight_(60).step_(0.0005).value_(0)
		.action_({ |sl| ~msSet.(~msToBpm.(sl.value)) });
	~msLoBox = NumberBox().clipLo_(1).clipHi_(400).decimals_(0).value_(~msLo).fixedWidth_(56)
		.action_({ |nb| ~msLo = nb.value; ~msSlider.value = ~msToPos.(~msBpm) });
	~msHiBox = NumberBox().clipLo_(1).clipHi_(400).decimals_(0).value_(~msHi).fixedWidth_(56)
		.action_({ |nb| ~msHi = nb.value; ~msSlider.value = ~msToPos.(~msBpm) });
	~msGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~msGlide).fixedWidth_(56).action_({ |nb| ~msGlide = nb.value });
	~msAmpBox = NumberBox().clipLo_(0).clipHi_(1).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~msAmp).fixedWidth_(56)
		.action_({ |nb| ~msAmp = nb.value; ~msSynth !? { ~msSynth.set(\amp, ~msAmp) } });
	~msCycleBox = NumberBox().clipLo_(1).clipHi_(64).step_(1).scroll_step_(1).decimals_(0)
		.value_(~msCycle).fixedWidth_(50)
		.action_({ |nb| ~msCycle = nb.value.asInteger; ~msSynth !? { ~msSynth.set(\cycle, ~msCycle) } });
	~msVoiceMenu = PopUpMenu().items_(["tock", "beep"]).fixedWidth_(80)
		.action_({ |m| ~msVoice = m.value; ~msSynth !? { ~msSynth.set(\voice, ~msVoice) } });
	~msRunBtn = Button().states_([["▶ start", Color.black, Color.white],
		["■ stop", Color.white, Color.green(0.45)]]).fixedWidth_(90)
		.action_({ |b| if (b.value == 1) { ~msStart.value } { ~msStop.value } });
	~msWin.layout = VLayout(
		~msNow, ~msTarget, ~msBeatText,
		~msSlider,
		HLayout(~msRunBtn,
			Button().states_([["back to LO", Color.black, Color.white]]).fixedWidth_(90)
				.action_({ ~msSlider.value = 0; ~msSet.(~msLo) }),
			nil,
			StaticText().string_("beats/cycle"), ~msCycleBox,
			StaticText().string_("range"), ~msLoBox, StaticText().string_("to"), ~msHiBox,
			StaticText().string_("glide s"), ~msGlideBox,
			StaticText().string_("level"), ~msAmpBox, ~msVoiceMenu)
	);
	~msWin.onClose = { ~msStop.value; OSCdef(\msTempo).free; OSCdef(\msBeat).free };
	~msSlider.focus(true);   // arrow keys nudge the slider too
	~msStart.value;
	"METRO_SLIDER_READY".postln;
};
)
