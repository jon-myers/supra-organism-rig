/*
force_concat.scd -- FORCE CONCAT (dev tab 8, 2026-09-30). Two things, both driven by the FORCE tab's 14 signals (~fhBus /
~fhValues -- so whatever source that tab is on: the dancers' OSC, the simulator, the faders, a recording):

 1. SINES -- Marc-Andre's ForceSensorSimulator.maxpat sonification, six times: one sine per sensor,
      loudness = DC (force) x sensitivity,  frequency = base note + AC x amount (Hz)   [the Max patch: base kslider + 4000 x AC]
    Base notes D3 F3 A3 C4 D4 F4 (editable), amount default 1000 Hz (the hardware's AC is only ~+-0.1..0.4).
    Plays on the main server (outs 1-2), own on/off + dB volume, per-sensor mutes.
 2. LIVE CONCATENATOR -- The Concatenator rebuilds those same six sines, in real time, out of a CORPUS chosen in the menu.
    A Python process (concatenator-corpus/live_force_shim.py) computes the identical sines hop by hop from the force values
    this tab sends it (/fc/force, 30 Hz) and plays the result straight to the chosen output device. Changing the corpus
    restarts the process ("loading corpus ... s"): ~2 s for a 20-min corpus; memory ~10 GB per corpus-HOUR (mono), so
    the 1-3 hour sets (v10-everything, aug-*) take a long load and a lot of RAM -- the menu shows each set's size.
    Measured 2026-09-30 (offline): 6 ms per frame against a 23 ms budget (0.3x real time) on 20-min corpora.
    Knobs: wet (corpus vs the dry sine target), level (dB), temperature (how eagerly it jumps to match), grain time (s).
The display changes at most 4 times a second (Jon: vestibular migraine). Closing the tab/window stops the process.
Standalone: select all, evaluate (needs force_hub.scd loaded). In the dev launcher: tab 8.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~fcCC = here +/+ ".." +/+ ".." +/+ "concatenator-corpus";
~fcPy = ~fcCC +/+ ".venv" +/+ "bin" +/+ "python";
~fcLog = "/tmp/force_concat_" ++ NetAddr.langPort ++ ".log";
~fcOscPort = ~fcOscPort ? 57240;
~fcP = ~fcP ? (sinesOn: 1, sinesAmp: -18.dbamp, amount: 1000, gain: 1.3, wet: 1, level: -12.dbamp, temperature: 50, graintime: 0.5,
	corpus: "v9-aug28-all", outDev: nil);
~fcP[\sr] = ~fcP[\sr] ? 44100;   // the Python stream's rate (PreSonus / Scarlett run at 44.1 kHz)
~fcBase = ~fcBase ? [50, 53, 57, 60, 62, 65];
~fcMute = ~fcMute ? (false ! 6);
s = Server.default;
s.waitForBoot {
	// ---- tear down a previous evaluation (synchronously) ----
	~fcWin !? { if (~fcWin.isClosed.not) { ~fcWin.onClose = nil; ~fcWin.close } };
	~fcRout !? { ~fcRout.stop }; ~fcSendRout !? { ~fcSendRout.stop };
	~fcSines !? { ~fcSines.free }; ~fcSines = nil;
	~fcKill !? { ~fcKill.() };
	OSCdef(\fcStatus).free;

	// ---- display rate limit: shared ~uiLater (4 Hz) ----
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };

	// ---- 1. the sines (same formula as the Python target) ----
	SynthDef(\fcSines, { |in = 0, out = 0, on = 1, amp = 0.1, amount = 1000, gain = 1.3|
		var dc = In.kr(in, 6), ac = In.kr(in + 7, 6), base = \base.kr(50 ! 6).midicps, mutes = \mutes.kr(0 ! 6);
		var sig = 6.collect { |k|
			var lvl = (Lag.kr(dc[k], 0.03) * gain).clip(0, 1).squared * (1 - mutes[k]);
			var f = (base[k] + (Lag.kr(ac[k], 0.03) * amount)).clip(20, 18000);
			Pan2.ar(SinOsc.ar(f) * lvl, k.linlin(0, 5, -0.8, 0.8)) }.sum;
		Out.ar(out, Limiter.ar(sig * 0.25 * amp.lag(0.1) * on.lag(0.05), 0.9, 0.01));
	}).add;
	s.sync;
	if (~fhBus.isNil) { "force_concat: no FORCE tab buses (~fhBus) -- load force_hub.scd first; sines silent".warn } {
		~fcSines = Synth.tail(s, \fcSines, [\in, ~fhBus.index, \on, ~fcP[\sinesOn], \amp, ~fcP[\sinesAmp], \amount, ~fcP[\amount],
			\gain, ~fcP[\gain], \base, ~fcBase, \mutes, ~fcMute.collect(_.asInteger)]) };

	// ---- 2. the live concatenator process ----
	~fcAddr = NetAddr("127.0.0.1", ~fcOscPort);
	~fcPid = nil; ~fcState = "stopped"; ~fcStartT = nil; ~fcInfo = "";
	~fcCorpora = PathName(~fcCC +/+ "corpus").folders.collect(_.folderName).reject { |n| n.beginsWith("_") }.sort;
	// sizes once (MB), to label the menu -- one du call
	~fcSizes = IdentityDictionary.new;
	("cd " ++ (~fcCC +/+ "corpus").shellQuote ++ " && du -smL " ++ ~fcCorpora.collect(_.shellQuote).join(" ") ++ " 2>/dev/null").unixCmdGetStdOut
		.split($\n).do { |ln| var f = ln.split($\t); if (f.size == 2) { ~fcSizes[f[1].asSymbol] = f[0].asInteger } };
	~fcLabel = { |n| var mb = ~fcSizes[n.asSymbol]; n ++ (mb !? { "   (" ++ (mb / 1000).round(0.1) ++ " GB audio" ++ if (mb > 700) { ", SLOW/LARGE" } { "" } ++ ")" } ? "") };
	~fcSendParams = {
		~fcAddr.sendMsg('/fc/sine', *(~fcBase.collect(_.midicps) ++ [~fcP[\amount], ~fcP[\gain]]));
		~fcAddr.sendMsg('/fc/mute', *~fcMute.collect(_.asInteger));
		~fcAddr.sendMsg('/wet', ~fcP[\wet]); ~fcAddr.sendMsg('/level', ~fcP[\level]);
		~fcAddr.sendMsg('/temperature', ~fcP[\temperature]); ~fcAddr.sendMsg('/graintime', ~fcP[\graintime]) };
	~fcKill = { ~fcPid !? { |p| ~fcAddr.sendMsg('/quit'); ("sleep 0.5; kill " ++ p ++ " 2>/dev/null").unixCmd }; ~fcPid = nil; ~fcState = "stopped" };
	~fcStart = { var dev = ~fcP[\outDev] ? ~stOutDevice ? "Studio 1824c", cmd;
		~fcKill.();
		cmd = "cd " ++ ~fcCC.shellQuote ++ " && exec " ++ ~fcPy.shellQuote ++ " live_force_shim.py --corpus " ++ ("corpus/" ++ ~fcP[\corpus]).shellQuote
			++ " --osc-port " ++ ~fcOscPort ++ " --reply-port " ++ NetAddr.langPort ++ " --out-device " ++ dev.shellQuote
			++ " --sr " ++ ~fcP[\sr] ++ " --level " ++ ~fcP[\level] ++ " --wet " ++ ~fcP[\wet] ++ " --temperature " ++ ~fcP[\temperature]
			++ " > " ++ ~fcLog.shellQuote ++ " 2>&1";
		~fcPid = cmd.unixCmd({ |code| { if (~fcState != "stopped") { ~fcState = "exited (" ++ code ++ ") -- see " ++ ~fcLog } }.defer }, false);
		~fcState = "loading"; ~fcStartT = Main.elapsedTime; ~fcInfo = "" };
	OSCdef(\fcStatus, { |m| var st = m[1].asString;
		if (st == "ready") { ~fcSendParams.() };
		~fcState = if (st == "no-device") { "OUTPUT DEVICE NOT FOUND" } { st };
		~fcInfo = "frames " ++ m[2] ++ "  overruns " ++ m[3] ++ "  frame " ++ m[4].round(0.1) ++ " ms (budget 23.2)  corpus load " ++ m[5].round(0.1) ++ " s" }, '/fc/status');
	// force values -> the process, 30 Hz (only while it runs)
	~fcSendRout = Routine { loop { if (~fcPid.notNil and: { ~fhValues.notNil }) { ~fcAddr.sendMsg('/fc/force', *~fhValues) }; (1/30).wait } }.play(SystemClock);

	// ---- GUI ----
	~fcWin = if (~stHost.notNil and: { ~stNames.notNil } and: { ~stNames.includes(\fconcat) }) { ~stHost.(\fconcat) } { Window("force concat", Rect(100, 100, 900, 520)).front };
	~fcDbSpec = ControlSpec(-60, 6);
	~fcToAmp = { |v| if (v <= 0.001) { 0 } { ~fcDbSpec.map(v).dbamp } }; ~fcToPos = { |a| if (a <= 0.001) { 0 } { ~fcDbSpec.unmap(a.ampdb) } };
	~fcDbStr = { |a| if (a <= 0.001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } };
	~fcSet = { |key, v| ~fcP[key] = v;
		switch (key,
			\sinesOn, { ~fcSines !? { ~fcSines.set(\on, v) } }, \sinesAmp, { ~fcSines !? { ~fcSines.set(\amp, v) } },
			\amount, { ~fcSines !? { ~fcSines.set(\amount, v) }; ~fcSendParams.() }, \gain, { ~fcSines !? { ~fcSines.set(\gain, v) }; ~fcSendParams.() },
			{ ~fcAddr.sendMsg(("/" ++ key).asSymbol, v) }) };
	// sines row
	~fcSinesBtn = Button().states_([["sines OFF", Color.black, Color.grey(0.85)], ["sines ON", Color.white, Color.green(0.45)]]).fixedWidth_(90)
		.value_(~fcP[\sinesOn]).action_({ |b| ~fcSet.(\sinesOn, b.value) });
	~fcSinesDb = StaticText().string_(~fcDbStr.(~fcP[\sinesAmp])).fixedWidth_(64).font_(Font.default.size_(14).boldVariant);
	~fcSinesVol = Slider().orientation_(\horizontal).fixedHeight_(28).value_(~fcToPos.(~fcP[\sinesAmp]))
		.action_({ |sl| var a = ~fcToAmp.(sl.value); ~fcSet.(\sinesAmp, a); ~uiLater.(\fcSinesDb, { ~fcSinesDb.string = ~fcDbStr.(a) }) });
	~fcBaseBoxes = 6.collect { |k| NumberBox().value_(~fcBase[k]).clipLo_(24).clipHi_(96).step_(1).scroll_step_(1).decimals_(0).fixedWidth_(40)
		.action_({ |b| ~fcBase[k] = b.value; ~fcSines !? { ~fcSines.seti(\base, k, b.value) }; ~fcSendParams.() }) };
	~fcMuteBoxes = 6.collect { |k| CheckBox().string_("mute").value_(~fcMute[k])
		.action_({ |c| ~fcMute[k] = c.value; ~fcSines !? { ~fcSines.seti(\mutes, k, c.value.asInteger) }; ~fcSendParams.() }) };
	~fcAmountBox = NumberBox().value_(~fcP[\amount]).clipLo_(0).clipHi_(8000).step_(50).scroll_step_(50).decimals_(0).fixedWidth_(60).action_({ |b| ~fcSet.(\amount, b.value) });
	~fcGainBox = NumberBox().value_(~fcP[\gain]).clipLo_(0.1).clipHi_(10).step_(0.1).scroll_step_(0.1).decimals_(1).fixedWidth_(50).action_({ |b| ~fcSet.(\gain, b.value) });
	// concatenator row
	~fcCorpusMenu = PopUpMenu().items_(~fcCorpora.collect { |n| ~fcLabel.(n) }).minWidth_(360)
		.value_(~fcCorpora.detectIndex { |n| n == ~fcP[\corpus] } ? 0).action_({ |m| ~fcP[\corpus] = ~fcCorpora[m.value]; if (~fcPid.notNil) { ~fcStart.() } });
	~fcDevList = { ServerOptions.outDevices.reject(_.isEmpty) };
	~fcDevMenu = PopUpMenu().items_(~fcDevList.()).minWidth_(200)
		.value_(~fcDevList.().detectIndex { |d| d == (~fcP[\outDev] ? ~stOutDevice ? "Studio 1824c") } ? 0)
		.action_({ |m| ~fcP[\outDev] = m.item; if (~fcPid.notNil) { ~fcStart.() } });
	~fcRunBtn = Button().states_([["START concatenator", Color.black, Color.white], ["STOP concatenator", Color.white, Color.red(0.6)]]).fixedWidth_(160)
		.action_({ |b| if (b.value == 1) { ~fcP[\outDev] = ~fcDevMenu.item; ~fcStart.() } { ~fcKill.() } });
	~fcLevelDb = StaticText().string_(~fcDbStr.(~fcP[\level])).fixedWidth_(64).font_(Font.default.size_(14).boldVariant);
	~fcLevel = Slider().orientation_(\horizontal).fixedHeight_(28).value_(~fcToPos.(~fcP[\level]))
		.action_({ |sl| var a = ~fcToAmp.(sl.value); ~fcSet.(\level, a); ~uiLater.(\fcLevelDb, { ~fcLevelDb.string = ~fcDbStr.(a) }) });
	~fcWetBox = NumberBox().value_(~fcP[\wet]).clipLo_(0).clipHi_(1).step_(0.05).scroll_step_(0.05).decimals_(2).fixedWidth_(50).action_({ |b| ~fcSet.(\wet, b.value) });
	~fcTempBox = NumberBox().value_(~fcP[\temperature]).clipLo_(1).clipHi_(500).step_(5).scroll_step_(5).decimals_(0).fixedWidth_(50).action_({ |b| ~fcSet.(\temperature, b.value) });
	~fcGrainBox = NumberBox().value_(~fcP[\graintime]).clipLo_(0.02).clipHi_(10).step_(0.05).scroll_step_(0.05).decimals_(2).fixedWidth_(50).action_({ |b| ~fcSet.(\graintime, b.value) });
	~fcStatus = StaticText().string_("").fixedHeight_(18);
	~fcWin.layout = VLayout(
		StaticText().string_("1  SINES  (the Max patch x6: loudness = force, pitch = base + AC x amount)").font_(Font.default.size_(14).boldVariant),
		HLayout(~fcSinesBtn, StaticText().string_("VOLUME").font_(Font.default.boldVariant), ~fcSinesVol, ~fcSinesDb),
		HLayout(*(6.collect { |k| VLayout(StaticText().string_("sensor " ++ (k + 1)).align_(\center), ~fcBaseBoxes[k], ~fcMuteBoxes[k]) } ++ [nil])),
		HLayout(StaticText().string_("base notes are MIDI (50 = D3).   pitch amount Hz per unit AC"), ~fcAmountBox, StaticText().string_("  sensitivity x"), ~fcGainBox, nil),
		View().fixedHeight_(1).background_(Color.grey(0.6)),
		StaticText().string_("2  LIVE CONCATENATOR  (rebuilds those sines out of a corpus, in real time)").font_(Font.default.size_(14).boldVariant),
		HLayout(StaticText().string_("corpus"), ~fcCorpusMenu, StaticText().string_("output"), ~fcDevMenu, nil),
		HLayout(~fcRunBtn, StaticText().string_("LEVEL").font_(Font.default.boldVariant), ~fcLevel, ~fcLevelDb),
		HLayout(StaticText().string_("wet"), ~fcWetBox, StaticText().string_("  temperature"), ~fcTempBox, StaticText().string_("  grain time s"), ~fcGrainBox, nil),
		~fcStatus, nil);
	~fcRout = Routine { loop {
		~fcStatus.string = "concatenator: " ++ (if (~fcState == "loading") { "loading " ++ ~fcP[\corpus] ++ " ... " ++ (Main.elapsedTime - (~fcStartT ? Main.elapsedTime)).round(1) ++ " s" } { ~fcState })
			++ (if (~fcInfo.size > 0 and: { ~fcState != "stopped" }) { "   |   " ++ ~fcInfo } { "" })
			++ "   |   FORCE source: " ++ (~fhP !? { |p| p[\source] } ? "no FORCE tab");
		~fcRunBtn.value = (~fcPid.notNil and: { ~fcState != "stopped" } and: { ~fcState.beginsWith("exited").not }).asInteger;
		0.25.wait } }.play(AppClock);
	~fcWin.onClose = { ~fcRout.stop; ~fcSendRout.stop; ~fcKill.(); ~fcSines !? { ~fcSines.free }; ~fcSines = nil; OSCdef(\fcStatus).free };
	("FORCE_CONCAT_READY (" ++ ~fcCorpora.size ++ " corpora)").postln;
};
)
