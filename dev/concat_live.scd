/*
concat_live.scd (rig/dev/, tab 9 CONCAT, 2026-10-01) -- The Concatenator LIVE: pick a CORPUS and a TARGET from menus, and the
target is rebuilt out of the corpus in real time. A Python process (concatenator-corpus/live_shim.py, the headless OSC
wrapper of The Concatenator's particle filter) streams the target file through the filter and plays the result straight to
the chosen output device (stereo on that device's outputs 1-2; it is NOT in SuperCollider, so not in the AMBI field).
  corpus   every folder in concatenator-corpus/corpus, labelled with its size; > 0.7 GB marked SLOW/LARGE (RAM ~10 GB per
           corpus-hour). Changing it restarts the process ("loading ... s").
  target   every audio file in concatenator-corpus/targets (and its subfolders, e.g. ocean215/ beams): Phantom Pain (full,
           first 60 s, 145-175 s), ocean waves, rainforest, 2020, the Rite, nCVI noise ... Changing it restarts the stream.
  loop     the shim plays a target once; ticked, the tab starts it again when it ends.
  level (dB), wet (corpus 1 .. dry target 0), temperature (how eagerly it jumps to match), grain time (s), pan.
Status line: state, frames, overruns (frames that missed the real-time budget). Display at most 4 x a second (vestibular).
Log: /tmp/concat_live_<langPort>.log. Closing the tab stops the process.
*/
(
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/concat_live.scd".standardizePath).pathOnly;
~clCC = here +/+ ".." +/+ ".." +/+ "concatenator-corpus";
~clPy = ~clCC +/+ ".venv" +/+ "bin" +/+ "python";
~clLog = "/tmp/concat_live_" ++ NetAddr.langPort ++ ".log";
~clOscPort = ~clOscPort ? 57250; ~clLane = 9;
~clP = ~clP ? (corpus: "v3a-breath-all", target: "Bill Converse 2 - Phantom Pain.wav", outDev: nil, level: -12.dbamp, wet: 1,
	temperature: 50, graintime: 0.5, pan: 0, loop: true, sr: 44100);
s = Server.default;
s.waitForBoot {
	~clWin !? { if (~clWin.isClosed.not) { ~clWin.onClose = nil; ~clWin.close } };
	~clRout !? { ~clRout.stop }; ~clKill !? { ~clKill.() }; OSCdef(\clStatus).free;
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = ~uiLater ? { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new; p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };

	// ---- menus: corpora (with sizes) and targets ----
	~clCorpora = PathName(~clCC +/+ "corpus").folders.collect(_.folderName).reject { |n| n.beginsWith("_") }.sort;
	~clSizes = IdentityDictionary.new;
	("cd " ++ (~clCC +/+ "corpus").shellQuote ++ " && du -smL " ++ ~clCorpora.collect(_.shellQuote).join(" ") ++ " 2>/dev/null").unixCmdGetStdOut
		.split($\n).do { |ln| var f = ln.split($\t); if (f.size == 2) { ~clSizes[f[1].asSymbol] = f[0].asInteger } };
	~clLabel = { |n| var mb = ~clSizes[n.asSymbol]; n ++ (mb !? { "   (" ++ (mb / 1000).round(0.1) ++ " GB" ++ if (mb > 700) { ", SLOW/LARGE" } { "" } ++ ")" } ? "") };
	// listed BY NAME (pathMatch), one level of subfolders: PathName.filesDo resolves symlinks to their real location, which
	// turned the linked targets (the full Phantom Pain, 2020.mp3) into empty menu entries
	~clTargets = { var root = ~clCC +/+ "targets", exts = ["wav", "WAV", "aif", "aiff", "flac", "mp3"];
		((root +/+ "*").pathMatch ++ (root +/+ "*/*").pathMatch).select { |f| exts.includesEqual(PathName(f).extension) }
			.collect { |f| f.drop(root.size + 1) }.asSet.asArray.sort };
	~clTargetList = ~clTargets.();

	// ---- the process ----
	~clAddr = NetAddr("127.0.0.1", ~clOscPort);
	~clPid = nil; ~clState = "stopped"; ~clStartT = nil; ~clInfo = "";
	~clTargetPath = { ~clCC +/+ "targets" +/+ ~clP[\target] };
	~clSendParams = { [\wet, \level, \temperature, \graintime, \pan].do { |k| ~clAddr.sendMsg(("/" ++ k).asSymbol, ~clP[k]) } };
	~clKill = { ~clPid !? { |p| ~clAddr.sendMsg('/quit'); ("sleep 0.5; kill " ++ p ++ " 2>/dev/null").unixCmd }; ~clPid = nil; ~clState = "stopped" };
	~clStart = { var dev = ~clP[\outDev] ? ~stOutDevice ? "Fireface", cmd;
		~clKill.();
		dev = dev.split($().first.stripWhiteSpace;   // the shim matches a SUBSTRING; drop CoreAudio's " (serial)"
		cmd = "cd " ++ (~clCC +/+ "tool" +/+ "TheConcatenator").shellQuote ++ " && exec " ++ ~clPy.shellQuote ++ " " ++ (~clCC +/+ "live_shim.py").shellQuote
			++ " --corpus " ++ (~clCC +/+ "corpus" +/+ ~clP[\corpus]).shellQuote ++ " --target " ++ ~clTargetPath.().shellQuote
			++ " --lane " ++ ~clLane ++ " --osc-port " ++ ~clOscPort ++ " --reply-port " ++ NetAddr.langPort ++ " --out-device " ++ dev.shellQuote
			++ " --sr " ++ ~clP[\sr] ++ " --level " ++ ~clP[\level] ++ " --wet " ++ ~clP[\wet] ++ " --temperature " ++ ~clP[\temperature]
			++ " --pan " ++ ~clP[\pan] ++ " > " ++ ~clLog.shellQuote ++ " 2>&1";
		~clPid = cmd.unixCmd({ |code| { if (~clState != "stopped") { ~clState = "exited (" ++ code ++ ") -- see " ++ ~clLog } }.defer }, false);
		~clState = "loading"; ~clStartT = Main.elapsedTime; ~clInfo = "" };
	~clPlayTarget = { ~clAddr.sendMsg('/start', ~clTargetPath.()) };
	OSCdef(\clStatus, { |m| var st;
		if (m[1].asInteger == ~clLane) { st = m[2].asString;
			case
				{ st == "ready" } { ~clSendParams.(); ~clPlayTarget.() }
				{ st == "done" } { if (~clP[\loop]) { ~clPlayTarget.() } };
			~clState = st;
			~clInfo = "frames " ++ m[3] ++ "  overruns " ++ m[4] ++ "  (" ++ m[5].round(1) ++ " s streamed)" } }, '/concat/status');

	// ---- GUI ----
	~clWin = if (~stHost.notNil and: { ~stNames.notNil } and: { ~stNames.includes(\concat) }) { ~stHost.(\concat) } { Window("concatenator live", Rect(100, 100, 900, 360)).front };
	~clDbSpec = ControlSpec(-60, 6);
	~clToAmp = { |v| if (v <= 0.001) { 0 } { ~clDbSpec.map(v).dbamp } }; ~clToPos = { |a| if (a <= 0.001) { 0 } { ~clDbSpec.unmap(a.ampdb) } };
	~clDbStr = { |a| if (a <= 0.001) { "off" } { a.ampdb.round(0.5).asString ++ " dB" } };
	~clSet = { |key, v| ~clP[key] = v; ~clPid !? { ~clAddr.sendMsg(("/" ++ key).asSymbol, v) } };
	~clCorpusMenu = PopUpMenu().items_(~clCorpora.collect { |n| ~clLabel.(n) }).minWidth_(380)
		.value_(~clCorpora.detectIndex { |n| n == ~clP[\corpus] } ? 0).action_({ |m| ~clP[\corpus] = ~clCorpora[m.value]; if (~clPid.notNil) { ~clStart.() } });
	~clTargetMenu = PopUpMenu().items_(~clTargetList).minWidth_(380)
		.value_(~clTargetList.detectIndex { |n| n == ~clP[\target] } ? 0).action_({ |m| ~clP[\target] = ~clTargetList[m.value]; if (~clPid.notNil) { ~clPlayTarget.() } });
	~clDevList = { ServerOptions.outDevices.reject(_.isEmpty) };
	~clDevMenu = PopUpMenu().items_(~clDevList.()).minWidth_(220)
		.value_(~clDevList.().detectIndex { |d| d == (~clP[\outDev] ? ~stOutDevice) } ? 0)
		.action_({ |m| ~clP[\outDev] = m.item; if (~clPid.notNil) { ~clStart.() } });
	~clRunBtn = Button().states_([["START", Color.black, Color.white], ["STOP", Color.white, Color.red(0.6)]]).fixedWidth_(110)
		.action_({ |b| if (b.value == 1) { ~clP[\outDev] = ~clDevMenu.item; ~clP[\target] = ~clTargetList[~clTargetMenu.value]; ~clStart.() } { ~clKill.() } });
	~clLevelDb = StaticText().string_(~clDbStr.(~clP[\level])).fixedWidth_(64).font_(Font.default.size_(14).boldVariant);
	~clLevel = Slider().orientation_(\horizontal).fixedHeight_(28).value_(~clToPos.(~clP[\level]))
		.action_({ |sl| var a = ~clToAmp.(sl.value); ~clSet.(\level, a); ~uiLater.(\clLevelDb, { ~clLevelDb.string = ~clDbStr.(a) }) });
	~clNb = { |key, lo, hi, step, dec| NumberBox().value_(~clP[key]).clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec).fixedWidth_(54)
		.action_({ |b| ~clSet.(key, b.value) }) };
	~clLoopBox = CheckBox().string_("loop the target").value_(~clP[\loop]).action_({ |c| ~clP[\loop] = c.value });
	~clStatus = StaticText().string_("").fixedHeight_(18);
	~clWin.layout = VLayout(
		StaticText().string_("CONCATENATOR LIVE -- the TARGET rebuilt out of the CORPUS, in real time").font_(Font.default.size_(15).boldVariant),
		HLayout(StaticText().string_("corpus").fixedWidth_(50), ~clCorpusMenu, nil),
		HLayout(StaticText().string_("target").fixedWidth_(50), ~clTargetMenu, ~clLoopBox, nil),
		HLayout(StaticText().string_("output").fixedWidth_(50), ~clDevMenu, StaticText().string_("(stereo on that device's outputs 1-2)"), nil),
		HLayout(~clRunBtn, StaticText().string_("LEVEL").font_(Font.default.boldVariant), ~clLevel, ~clLevelDb),
		HLayout(StaticText().string_("wet"), ~clNb.(\wet, 0, 1, 0.05, 2), StaticText().string_("  temperature"), ~clNb.(\temperature, 1, 500, 5, 0),
			StaticText().string_("  grain time s"), ~clNb.(\graintime, 0.02, 10, 0.05, 2), StaticText().string_("  pan"), ~clNb.(\pan, -1, 1, 0.1, 1), nil),
		~clStatus, nil);
	~clRout = Routine { loop {
		~clStatus.string = "concatenator: " ++ (if (~clState == "loading") { "loading " ++ ~clP[\corpus] ++ " ... " ++ (Main.elapsedTime - (~clStartT ? Main.elapsedTime)).round(1) ++ " s" } { ~clState })
			++ (if ((~clInfo.size > 0) and: { ~clState != "stopped" }) { "   |   " ++ ~clInfo } { "" });
		~clRunBtn.value = (~clPid.notNil and: { ~clState != "stopped" } and: { ~clState.beginsWith("exited").not }).asInteger;
		0.25.wait } }.play(AppClock);
	~clWin.onClose = { ~clRout.stop; ~clKill.(); OSCdef(\clStatus).free };
	("CONCAT_LIVE_READY (" ++ ~clCorpora.size ++ " corpora, " ++ ~clTargetList.size ++ " targets)").postln;
};
)
