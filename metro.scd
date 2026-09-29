/*
metro.scd -- one slider, logarithmic tempo, live click -- ON ITS OWN SERVER.
Boots a second scsynth (~msServer, port 57131) bound to ~msOutDevice, so this patch can play out
of a different audio device than breath36 / rig.scd on the default server. Everything here
addresses ~msServer; the default server `s` is never touched. ~msServer.freeAll / .quit for reset.
(metro_slider.scd is the same patch on the default server.)
Slider left = LO BPM (default 20; starts at 30), right = HI BPM (default 80), equal slider
distance = equal tempo RATIO (log map), so 30->40 feels like 60->80.
The tempo glides server-side (glide s), so moves are smooth, never stepped.
Readout shows the ACTUAL tempo the click is at (~msReadHz); the target line
under it repaints at most once a second (~msTargetHz), however fast you slide. No animation.
Select all, evaluate.
*/
(
~msInDevice  = nil;   // no input: this patch only makes sound (avoids in/out sample-rate clashes)
~msOutDevice = ~msOutDevice ? "Scarlett 2i2 4th Gen";   // choose another in the window (e.g. "Multi-Output Device");      // nil = system default; the Multi-Output Device carries the click to several outputs at once
~msLo = 20; ~msHi = 80; ~msBpm = 30;   // slider spans 20-80, starts at 30
~msGlide = 0.5; ~msAmp = 0.5; ~msVoice = 0;
~msReadHz = 4;      // big tempo readout updates per second (capped 0.25-4)
~msTargetHz = 4;    // 'target' line updates per second while you slide
~msCycle = 10;      // beats per cycle; beat 1 of each cycle is the high click
~msAccent = 1.5;    // pitch ratio of beat 1 (1.5 = a fifth up)
~msAccentOn = true; // false = every beat sounds the same (toggle in the window)

~msPort = ~msPort ? 57131;   // NOT 57111: macOS sharingd sits on UDP 57111 (verified 2026-09-28); 57131 boots clean
~msServer = Server.named[\metro] ?? { Server(\metro, NetAddr("127.0.0.1", ~msPort)) };
~msInDevice  !? { ~msServer.options.inDevice  = ~msInDevice };
~msServer.options.numInputBusChannels = 0;
~msServer.options.numOutputBusChannels = ~msOutChannels ? 2;
// macOS default input may be an interface that is not running (Waves SoundGrid),
// and scsynth opens an input even with 0 channels -- so name a safe one
~msServer.options.inDevice = "MacBook Pro Microphone";
// false (default): if the named device is not connected (e.g. the Scarlett is at home), use the system
// output instead of retrying forever. true: hand the name to scsynth even if CoreAudio's list lacks it.
~msForceDevice = ~msForceDevice ? false;
~msPickDevice = { |want|   // returns the device to boot on: the wanted one if present (or forced), else system default (nil)
	if (want.notNil and: { ~msForceDevice or: { ServerOptions.outDevices.includesEqual(want) } }) { want } {
		want !? { ("OUTPUT DEVICE '" ++ want ++ "' NOT AVAILABLE -- using system default (is it built in Audio MIDI Setup, with a connected member?)").warn }; nil } };
~msActualDevice = ~msPickDevice.(~msOutDevice);
~msServer.options.outDevice = ~msActualDevice;
// scsynth exits silently when the input device and the output device end up at different
// sample rates (seen 2026-09-28: mic 48 k, Multi-Output 44.1 k -> "exited with exit code 0").
// So boot by trial: force both to 44.1 k, then 48 k, then whatever each device has.
// attempts: (sample rate, input device). scsynth needs in and out at one rate; if the mic cannot
// agree with a Bluetooth / Multi-Output device, try with no input device at all (numInputBusChannels is 0).
~msAttempts = [[nil, "MacBook Pro Microphone"], [44100, "MacBook Pro Microphone"], [48000, "MacBook Pro Microphone"], [nil, nil]];   // (rate, input): device rate first
~msExpectQuit = false; ~msWantRunning = true; ~msReconnects = 0;
// boot the named device. Wait for the real boot handshake (ServerBoot) instead of polling: the
// first version polled at 7 s, found the handshake not yet done, and killed a WORKING server.
// Only if the server process itself dies (ServerQuit) or 25 s pass do we try the next attempt.
~msTryBoot = { |i = 0|
	if (i >= ~msAttempts.size) {
		("metro: '" ++ (~msActualDevice ? "system default") ++ "' did not start on any attempt (CoreAudio 'AudioDeviceStart failed' = the device is not running). In Audio MIDI Setup give the Multi-Output Device a clock source that is present (e.g. MacBook Pro Speakers) and Drift Correction on the Bluetooth members; it will reconnect by itself.").warn;
		{ ~msDevText !? { ~msDevText.string = "output device '" ++ (~msActualDevice ? "system default") ++ "' is not running -- fix it in Audio MIDI Setup; retrying every 15 s" } }.defer;
		SystemClock.sched(15, { if (~msWantRunning and: { ~msServer.serverRunning.not }) { ~msTryBoot.(0) }; nil });
	} {
		var rate = ~msAttempts[i][0], inDev = ~msAttempts[i][1], booted = false, onBoot;
		~msServer.options.sampleRate = rate; ~msServer.options.inDevice = inDev;
		onBoot = { booted = true; ServerBoot.remove(onBoot, ~msServer); ~msReconnects = 0; { ~msBuild.value }.fork(AppClock) };
		ServerBoot.add(onBoot, ~msServer);
		~msExpectQuit = true; ~msServer.boot; { ~msExpectQuit = false }.defer(2);
		SystemClock.sched(8, { if (booted.not) { ServerBoot.remove(onBoot, ~msServer);
			if (~msServer.serverRunning.not) { ~msExpectQuit = true; ~msServer.quit; { ~msExpectQuit = false; ~msTryBoot.(i + 1) }.defer(2) } }; nil });
	};
};
ServerQuit.add({ if (~msWantRunning and: { ~msExpectQuit.not } and: { ~msReconnects < 200 }) {
	~msReconnects = ~msReconnects + 1;   // the device rebuilt (a headset joined or left) and took the server down: come back quietly
	{ ~msDevText !? { ~msDevText.string = "output device dropped (a headset joined or left?) -- reconnecting " ++ ~msReconnects ++ " ..." } }.defer;
	~msResume = ~msSynth.notNil; ~msSynth = nil; { ~msTryBoot.(0) }.defer(4);
} }, ~msServer);
~msBuild = {
	SynthDef(\msClick, { |bpm = 30, glide = 0.5, amp = 0.5, voice = 0, out = 0,
		cycle = 10, accent = 1.5, readhz = 1|
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
		SendReply.kr(Impulse.kr(readhz.clip(0.25, 4)), '/msTempo', A2K.kr(tempo));
		SendReply.ar(trig, '/msBeat', count);
		Out.ar(out, sig ! 2);
	}).send(~msServer);
	~msServer.sync;

	~msAccentRatio = { if (~msAccentOn) { ~msAccent } { 1 } };
	~msToBpm  = { |v| ~msLo * ((~msHi / ~msLo) ** v.clip(0, 1)) };
	~msToPos  = { |b| ((b / ~msLo).log / (~msHi / ~msLo).log).clip(0, 1) };
	~msSet = { |b|
		~msBpm = b.clip(1, 400);
		~msSynth !? { ~msSynth.set(\bpm, ~msBpm, \glide, ~msGlide) };
		~msTargetDirty = true;   // painted by the throttled routine below
	};
	~msBeats = 0;
	~msStart = {
		~msSynth ?? {
			~msBeats = 0;
			~msSynth = Synth(\msClick, [\bpm, ~msBpm, \glide, 0, \amp, ~msAmp, \voice, ~msVoice,
				\cycle, ~msCycle, \accent, ~msAccentRatio.value, \readhz, ~msReadHz, \out, ~msOutBus ? 0], ~msServer);
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
	~msWin !? { if (~msWin.isClosed.not) { ~msWin.onClose = nil; ~msWin.close } };   // a rebuild, not a user close: do not run the stop/teardown handler
	~msWin = if (~stHost.notNil) { ~stHost.(\metro) } { Window("metronome  [own server -> " ++ (~msActualDevice ? "system default") ++ "]", Rect(120, 200, 960, 360)).front };   // in a tab of show_tabs.scd, or its own window
	~msDevList = { ["system default"] ++ (ServerOptions.outDevices ++ [~msActualDevice].reject(_.isNil)).asSet.asArray.sort };
	~msDevMenu = PopUpMenu().items_(~msDevList.value).fixedWidth_(230)
		.value_(~msDevList.value.detectIndex { |d| d == (~msActualDevice ? "system default") } ? 0)
		.action_({ |m| ~msRebootTo.(if (m.value == 0) { nil } { m.item }) });
	~msRescanBtn = Button().states_([["rescan"]]).fixedWidth_(70)
		.action_({ ~msDevMenu.items = ~msDevList.value; ~msDevMenu.value = ~msDevList.value.detectIndex { |d| d == (~msActualDevice ? "system default") } ? 0 });
	~msDevText = StaticText().string_("output: " ++ (~msActualDevice ? "system default") ++ " @ " ++ ~msServer.sampleRate.asInteger ++ " Hz   (set ~msOutDevice at the top of metro.scd; headphones must be members of that device in Audio MIDI Setup)").fixedHeight_(16);
	~msNow = StaticText().string_("30.0 BPM").font_(Font.default.size_(72).boldVariant)
		.align_(\center);
	~msTarget = StaticText().string_("target 30 BPM").align_(\center)
		.font_(Font.default.size_(16));
	~msBeatText = StaticText().string_("beat 0").align_(\center).font_(Font.default.size_(16));
	~msSlider = Slider().orientation_(\horizontal).fixedHeight_(60).step_(0.0005).value_(((30 / ~msLo).log / (~msHi / ~msLo).log).clip(0, 1))
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
	~msAccentBtn = Button().states_([["downbeat: same", Color.black, Color.white],
		["downbeat: HIGH", Color.white, Color.blue(0.5)]]).fixedWidth_(120)
		.value_(~msAccentOn.asInteger)
		.action_({ |b| ~msAccentOn = (b.value == 1);
			~msSynth !? { ~msSynth.set(\accent, ~msAccentRatio.value) } });
	~msVoiceMenu = PopUpMenu().items_(["tock", "beep"]).fixedWidth_(80)
		.action_({ |m| ~msVoice = m.value; ~msSynth !? { ~msSynth.set(\voice, ~msVoice) } });
	~msRunBtn = Button().states_([["▶ start", Color.black, Color.white],
		["■ stop", Color.white, Color.green(0.45)]]).fixedWidth_(90)
		.action_({ |b| if (b.value == 1) { ~msStart.value } { ~msStop.value } });
	~msWin.layout = VLayout(
		HLayout(StaticText().string_("output"), ~msDevMenu, ~msRescanBtn, nil), ~msDevText,
		~msNow, ~msTarget, ~msBeatText,
		~msSlider,
		HLayout(~msRunBtn,
			Button().states_([["back to 30", Color.black, Color.white]]).fixedWidth_(90)
				.action_({ ~msSlider.value = ~msToPos.(30); ~msSet.(30) }),
			nil,
			StaticText().string_("beats/cycle"), ~msCycleBox, ~msAccentBtn,
			StaticText().string_("range"), ~msLoBox, StaticText().string_("to"), ~msHiBox,
			StaticText().string_("glide s"), ~msGlideBox,
			StaticText().string_("level"), ~msAmpBox, ~msVoiceMenu)
	);
	~msTargetDirty = false;
	~msTargetRout = Routine {
		loop {
			if (~msTargetDirty) {
				~msTargetDirty = false;
				~msTarget.string = "target " ++ ~msBpm.round(0.1) ++ " BPM";
			};
			(1 / ~msTargetHz.clip(0.25, 4)).wait;
		};
	}.play(AppClock);
	~msWin.onClose = { ~msWantRunning = false; ~msTargetRout.stop; ~msStop.value; OSCdef(\msTempo).free; OSCdef(\msBeat).free };
	~msSlider.focus(true);   // arrow keys nudge the slider too
	if (~msResume == true) { ~msStart.value };   // stopped by default; only resumes after a device switch / reconnect
	~msResume = false;
	("METRO_READY on " ++ (~msActualDevice ? "system default") ++ " @ " ++ ~msServer.sampleRate ++ " Hz (server " ++ ~msServer.name ++ ", port " ++ ~msPort ++ ")").postln;
};
// switch output device: quit this server, boot it on the new device, rebuild everything
~msRebootTo = { |dev|
	~msResume = ~msSynth.notNil; ~msStop.value; ~msTargetRout !? { ~msTargetRout.stop };
	~msExpectQuit = true; ~msServer.quit; ~msOutDevice = dev; ~msActualDevice = ~msPickDevice.(dev);   // a chosen switch, not a dropout
	~msServer.options.outDevice = ~msActualDevice;
	{ ~msExpectQuit = false; ~msTryBoot.(0) }.defer(1.5);
};
if (~msServer.serverRunning) { { ~msBuild.value }.fork(AppClock) } { ~msTryBoot.(0) };
)
