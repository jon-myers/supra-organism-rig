/*
metro_dual.scd (rig/dev/, 2026-09-29) -- metro.scd PLUS a second, toggleable click on the INTERFACE (the main
server's output: Scarlett now, Fireface later). DEV COPY: metro.scd is the stable one and is unchanged.
  headphones [x]  the metro server as before (its Multi-Output device); unticking mutes it (amp 0, no reboot).
  interface  [ ]  default OFF. Every /msBeat the metro server sends plays the same click (tock/beep, beat 1 of the
                  cycle high if the accent is on, same level x its own level) on Server.default, on the chosen
                  output pair, delayed by 0-500 ms (timestamped bundle) so it can be pushed later to meet late
                  (Bluetooth) headphones. Sync is per beat, so the two can never drift apart; the interface click
                  lands a few ms after the headphone one plus the delay. Pairs offered = the main server's
                  numOutputBusChannels (set it > 2 before booting for a Fireface).
VOLUME: two big sliders in dB, -60..+6 dB (all the way down = off), one per path, each with its own dB readout
(redrawn at most 4x/s). Headphones = ~msAmp (the old "level" box stays and follows it), interface = ~mdIfAmp
(independent of the headphone level).
New names: ~mdIf... / ~mdHp..., SynthDef \mdIfClick (main server), OSCdef \mdIfBeat.

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
~mdHpOn = ~mdHpOn ? true;            // headphone (metro server) click on
~mdIfOn = ~mdIfOn ? false;           // interface (main server) click off by default
~mdIfAmp = ~mdIfAmp ? 0.5; ~mdIfPair = ~mdIfPair ? 0; ~mdIfDelay = ~mdIfDelay ? 0;   // level x, output pair index, delay s
// IN-EAR TRACKS: audio files in supra-organism/in_ears/ (wav / aif / flac; mono or stereo) played on THIS server,
// i.e. to the in-ear headphones, with their own volume; independent of the click. Add files, press rescan.
~mdTrackDir = PathName(thisProcess.nowExecutingPath).pathOnly +/+ ".." +/+ ".." +/+ "in_ears";
~mdTrackAmp = ~mdTrackAmp ? 0.5; ~mdTrackLoop = ~mdTrackLoop ? false; ~mdTrackIdx = ~mdTrackIdx ? 0;
// display rate limit (Jon: nothing on screen faster than 4x/s -- vestibular migraine): shared ~uiLater queue
~uiPending = ~uiPending ? IdentityDictionary.new;
~uiLater = { |key, fn| ~uiPending[key] = fn };
if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
	~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
		p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
// the interface click: one-shot, same sound as \msClick's, on the MAIN server (added to every server that boots)
SynthDef(\mdIfClick, { |ratio = 1, voice = 0, amp = 0.5, out = 0|
	var trig = Trig.ar(1, SampleDur.ir);   // one sample at the start (Impulse.ar(0) does not fire here)
	var tock = [1050, 1900, 3250].collect { |f, i|
		SinOsc.ar(f * ratio) * Decay2.ar(trig, 0.0005, [0.06, 0.04, 0.025][i]) * [1, 0.5, 0.3][i]
	}.sum + (BPF.ar(WhiteNoise.ar, 3000, 0.5) * Decay2.ar(trig, 0.0002, 0.004) * 2);
	var beep = SinOsc.ar(880 * ratio) * EnvGen.ar(Env.linen(0.0005, 0.0035, 0.0005), trig);
	var sig = Limiter.ar(Select.ar(voice, [tock * 0.6, beep]) * amp, 0.95);
	Line.kr(0, 0, 0.3, doneAction: 2);
	Out.ar(out, sig ! 2);
}).add;
~mdIfClickNow = { |n| var c = ~msCycle.max(1), one = ((n - 1) % c) == 0, sv = Server.default;
	if (~mdIfOn and: { sv.serverRunning }) {
		sv.makeBundle(if (~mdIfDelay > 0) { ~mdIfDelay } { nil }, {
			Synth(\mdIfClick, [\ratio, if (one) { ~msAccentRatio.value } { 1 }, \voice, ~msVoice,
				\amp, ~mdIfAmp, \out, ~mdIfPair * 2], sv.defaultGroup, \addToTail) });   // default group: before root-tail limiters
		~mdIfCount = (~mdIfCount ? 0) + 1 } };
OSCdef(\mdIfBeat, { |msg, time, addr| if (addr.port == ~msServer.addr.port) { ~mdIfClickNow.(msg[3].asInteger) } }, '/msBeat');

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
	// in-ear track player: reads from `start` s, loops or frees itself at the end; position reported 4x/s
	SynthDef(\mdTrack, { |buf = 0, amp = 0.5, start = 0, loop = 0, gate = 1, out = 0|
		var frames = BufFrames.kr(buf), ph = (start * BufSampleRate.kr(buf)) + Sweep.ar(0, BufSampleRate.kr(buf));
		var env = EnvGen.kr(Env.asr(0.01, 1, 0.08), gate, doneAction: 2);
		var sig = BufRd.ar(2, buf, ph % frames, 1, 4);
		var ended = A2K.kr(ph >= frames) * (1 - loop);
		SendReply.kr(Impulse.kr(4), '/mdTrackPos', A2K.kr(ph % frames) / BufSampleRate.kr(buf));
		SendReply.kr(ended, '/mdTrackEnd', 1); FreeSelf.kr(ended);
		Out.ar(out, sig * env * amp.lag(0.05));
	}).send(~msServer);
	~msServer.sync;
	~mdTrackSynth = nil; ~mdTrackBuf = nil; ~mdTrackPlaying = false; ~mdTrackPos = 0;   // a (re)boot loses buffers and nodes

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
			~msSynth = Synth(\msClick, [\bpm, ~msBpm, \glide, 0, \amp, ~msAmp * ~mdHpOn.asInteger, \voice, ~msVoice,
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
		~uiLater.(\msBeat, { ~msBeatText.string = "beat " ++ (((n - 1) % c) + 1) ++ " of " ++ c
			++ "     cycle " ++ ((n - 1).div(c) + 1) ++ "     total " ++ n });
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
	// ---- volume in dB: slider 0..1 = -60..+6 dB, 0 = off ----
	~mdDbSpec = ControlSpec(-60, 6);
	~mdToAmp = { |v| if (v <= 0.001) { 0 } { ~mdDbSpec.map(v).dbamp } };
	~mdToPos = { |a| if (a <= 0.001) { 0 } { ~mdDbSpec.unmap(a.ampdb) } };
	~mdDbStr = { |a| if (a <= 0.001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } };
	~mdSetHpAmp = { |a| ~msAmp = a.clip(0, 2); ~msSynth !? { ~msSynth.set(\amp, ~msAmp * ~mdHpOn.asInteger) };
		~uiLater.(\mdHpDb, { ~mdHpDbText.string = ~mdDbStr.(~msAmp); ~msAmpBox.value = ~msAmp }) };
	~mdSetIfAmp = { |a| ~mdIfAmp = a.clip(0, 2); ~uiLater.(\mdIfDb, { ~mdIfDbText.string = ~mdDbStr.(~mdIfAmp) }) };
	~mdHpVol = Slider().orientation_(\horizontal).fixedHeight_(34).value_(~mdToPos.(~msAmp)).action_({ |sl| ~mdSetHpAmp.(~mdToAmp.(sl.value)) });
	~mdIfVol = Slider().orientation_(\horizontal).fixedHeight_(34).value_(~mdToPos.(~mdIfAmp)).action_({ |sl| ~mdSetIfAmp.(~mdToAmp.(sl.value)) });
	~mdHpDbText = StaticText().string_(~mdDbStr.(~msAmp)).fixedWidth_(70).font_(Font.default.size_(15).boldVariant);
	~mdIfDbText = StaticText().string_(~mdDbStr.(~mdIfAmp)).fixedWidth_(70).font_(Font.default.size_(15).boldVariant);
	~msAmpBox = NumberBox().clipLo_(0).clipHi_(2).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~msAmp).fixedWidth_(56)
		.action_({ |nb| ~mdSetHpAmp.(nb.value); ~uiLater.(\mdHpVol, { ~mdHpVol.value = ~mdToPos.(~msAmp) }) });
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
	~mdHpBox = CheckBox().fixedWidth_(240).string_("headphones (this server's output)").value_(~mdHpOn)
		.action_({ |c| ~mdHpOn = c.value; ~msSynth !? { ~msSynth.set(\amp, ~msAmp * ~mdHpOn.asInteger) } });
	~mdIfBox = CheckBox().fixedWidth_(240).string_("interface (main server)").value_(~mdIfOn).action_({ |c| ~mdIfOn = c.value });
	~mdIfPairs = { (Server.default.options.numOutputBusChannels.max(2) div: 2).collect { |i| "out " ++ ((i * 2) + 1) ++ "-" ++ ((i * 2) + 2) } };
	~mdIfPairMenu = PopUpMenu().items_(~mdIfPairs.value).value_(~mdIfPair).fixedWidth_(90).action_({ |m| ~mdIfPair = m.value });
	~mdIfDelayBox = NumberBox().clipLo_(0).clipHi_(500).step_(5).scroll_step_(5).decimals_(0).value_(~mdIfDelay * 1000).fixedWidth_(56)
		.action_({ |nb| ~mdIfDelay = nb.value / 1000 });
	// ---- IN-EAR TRACKS ----
	~mdTrackFiles = { (["wav", "WAV", "aif", "aiff", "flac"].collect { |e| (~mdTrackDir +/+ "*." ++ e).pathMatch }.flatten).asSet.asArray.sort };
	~mdTrackList = ~mdTrackFiles.();
	~mdTrackLoad = { |path, then| var nch = SoundFile.openRead(path) !? { |f| var n = f.numChannels; f.close; n } ? 2;
		~mdTrackBuf !? { ~mdTrackBuf.free }; ~mdTrackBuf = nil; ~mdTrackDur = 0;
		Buffer.readChannel(~msServer, path, channels: if (nch == 1) { [0, 0] } { [0, 1] }, action: { |b|
			~mdTrackBuf = b; ~mdTrackDur = b.numFrames / b.sampleRate; ~mdTrackPath = path; then !? { then.value } }) };
	~mdTrackStart = { var go = {
			~mdTrackSynth !? { ~mdTrackSynth.set(\gate, 0) };
			if (~mdTrackPos >= (~mdTrackDur - 0.3)) { ~mdTrackPos = 0 };
			~mdTrackSynth = Synth(\mdTrack, [\buf, ~mdTrackBuf, \amp, ~mdTrackAmp, \start, ~mdTrackPos, \loop, ~mdTrackLoop.asInteger,
				\out, ~msOutBus ? 0], ~msServer);
			~mdTrackPlaying = true; ~uiLater.(\mdTrackBtn, { ~mdTrackBtn.value = 1 }) };
		if (~mdTrackList.isEmpty) { "in-ear: no audio files in in_ears/".warn } {
			if (~mdTrackBuf.notNil and: { ~mdTrackPath == ~mdTrackList[~mdTrackIdx] }) { go.() } { ~mdTrackLoad.(~mdTrackList[~mdTrackIdx], go) } } };
	~mdTrackStop = { ~mdTrackSynth !? { ~mdTrackSynth.set(\gate, 0) }; ~mdTrackSynth = nil; ~mdTrackPlaying = false;
		~uiLater.(\mdTrackBtn, { ~mdTrackBtn.value = 0 }) };
	OSCdef(\mdTrackPos, { |m| if (~mdTrackSynth.notNil and: { m[1] == ~mdTrackSynth.nodeID }) { ~mdTrackPos = m[3] } }, '/mdTrackPos', ~msServer.addr);
	OSCdef(\mdTrackEnd, { |m| if (~mdTrackSynth.notNil and: { m[1] == ~mdTrackSynth.nodeID }) { ~mdTrackSynth = nil; ~mdTrackPlaying = false; ~mdTrackPos = 0;
		~uiLater.(\mdTrackBtn, { ~mdTrackBtn.value = 0 }) } }, '/mdTrackEnd', ~msServer.addr);
	~mdTrackMenu = PopUpMenu().items_(if (~mdTrackList.isEmpty) { ["(no files in in_ears/)"] } { ~mdTrackList.collect { |p| PathName(p).fileNameWithoutExtension } })
		.value_(~mdTrackIdx.clip(0, (~mdTrackList.size - 1).max(0))).minWidth_(300)
		.action_({ |m| ~mdTrackIdx = m.value; ~mdTrackStop.(); ~mdTrackPos = 0 });
	~mdTrackRescan = Button().states_([["rescan"]]).fixedWidth_(70).action_({ ~mdTrackList = ~mdTrackFiles.();
		~mdTrackMenu.items = if (~mdTrackList.isEmpty) { ["(no files in in_ears/)"] } { ~mdTrackList.collect { |p| PathName(p).fileNameWithoutExtension } } });
	~mdTrackBtn = Button().states_([["▶ play track", Color.black, Color.white], ["■ stop track", Color.white, Color.green(0.45)]]).fixedWidth_(110)
		.action_({ |b| if (b.value == 1) { ~mdTrackStart.() } { ~mdTrackStop.() } });
	~mdTrackPosSl = Slider().orientation_(\horizontal).fixedHeight_(24).action_({ |sl|
		~mdTrackPos = sl.value * (~mdTrackDur ? 0); if (~mdTrackPlaying) { ~mdTrackStart.() } });
	~mdTrackTime = StaticText().string_("0:00").fixedWidth_(90);
	~mdTrackLoopBox = CheckBox().string_("loop").value_(~mdTrackLoop).action_({ |c| ~mdTrackLoop = c.value; ~mdTrackSynth !? { ~mdTrackSynth.set(\loop, c.value.asInteger) } });
	~mdTrackVol = Slider().orientation_(\horizontal).fixedHeight_(34).value_(~mdToPos.(~mdTrackAmp))
		.action_({ |sl| ~mdTrackAmp = ~mdToAmp.(sl.value); ~mdTrackSynth !? { ~mdTrackSynth.set(\amp, ~mdTrackAmp) };
			~uiLater.(\mdTrackDb, { ~mdTrackDbText.string = ~mdDbStr.(~mdTrackAmp) }) });
	~mdTrackDbText = StaticText().string_(~mdDbStr.(~mdTrackAmp)).fixedWidth_(70).font_(Font.default.size_(15).boldVariant);
	~mdTrackRout !? { ~mdTrackRout.stop };
	~mdTrackRout = Routine { var n = 0; loop {   // 4 Hz text, position bar once a second
		var p = ~mdTrackPos ? 0, fmt = { |t| (t / 60).floor.asInteger.asString ++ ":" ++ (t % 60).floor.asInteger.asString.padLeft(2, "0") };
		~mdTrackTime.string = fmt.(p) ++ " / " ++ fmt.(~mdTrackDur ? 0);
		if (~mdTrackPlaying and: { n % 4 == 0 }) { ~mdTrackPosSl.value = p / (~mdTrackDur ? 1).max(1) };
		n = n + 1; 0.25.wait } }.play(AppClock);
	~msWin.layout = VLayout(
		HLayout(StaticText().string_("output"), ~msDevMenu, ~msRescanBtn, nil), ~msDevText,
		HLayout(~mdHpBox, StaticText().string_("VOLUME").font_(Font.default.boldVariant), ~mdHpVol, ~mdHpDbText),
		HLayout(~mdIfBox, StaticText().string_("VOLUME").font_(Font.default.boldVariant), ~mdIfVol, ~mdIfDbText,
			~mdIfPairMenu, StaticText().string_("delay ms"), ~mdIfDelayBox),
		~msNow, ~msTarget, ~msBeatText,
		~msSlider,
		HLayout(~msRunBtn,
			Button().states_([["back to 30", Color.black, Color.white]]).fixedWidth_(90)
				.action_({ ~msSlider.value = ~msToPos.(30); ~msSet.(30) }),
			nil,
			StaticText().string_("beats/cycle"), ~msCycleBox, ~msAccentBtn,
			StaticText().string_("range"), ~msLoBox, StaticText().string_("to"), ~msHiBox,
			StaticText().string_("glide s"), ~msGlideBox,
			StaticText().string_("level"), ~msAmpBox, ~msVoiceMenu),
		View().fixedHeight_(1).background_(Color.grey(0.6)),
		HLayout(StaticText().string_("IN-EAR TRACK").font_(Font.default.boldVariant), ~mdTrackMenu, ~mdTrackRescan, ~mdTrackBtn, ~mdTrackLoopBox, nil),
		HLayout(~mdTrackPosSl, ~mdTrackTime, StaticText().string_("VOLUME").font_(Font.default.boldVariant), ~mdTrackVol, ~mdTrackDbText)
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
	~msWin.onClose = { ~msWantRunning = false; ~msTargetRout.stop; ~msStop.value; ~mdTrackStop.(); ~mdTrackRout !? { ~mdTrackRout.stop }; OSCdef(\mdTrackPos).free; OSCdef(\mdTrackEnd).free; OSCdef(\msTempo).free; OSCdef(\msBeat).free; OSCdef(\mdIfBeat).free };
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
