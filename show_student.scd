/*
show_student.scd -- the Supra-Organism rig for a STUDENT LAPTOP. Open this file in SuperCollider, select all (Cmd-A),
evaluate (Cmd-Return). Put headphones on: the mix is BINAURAL on the laptop's normal stereo output (outs 1/2).

What is different from the show rig (rig/dev/show_tabs_dev.scd):
  - one stereo output (the Mac's default output, or ~studentOutDevice), no interface, no second device for the metronome
  - the room's quad speakers are replaced by the binaural decode of the same ambisonic field (AMBI tab)
  - the force sensors are SIMULATED (FORCE tab, "simulate"), so everything that follows the dancers moves on its own
  - no metronome, no Rite, no concatenator tabs; no TotalMix, no audiorate / Bluetooth helpers
  - sized to this laptop's memory (below)

TABS (keys 1-6 while the window is focused)
  1 36 BREATHS   2 PHANTOM PAIN SWEEP (LatentFT planes)   3 WALL OF SOUND   4 TORNADO (the ending)   5 FORCE (simulated)   6 AMBI

MEMORY. SuperCollider holds every sound it plays in RAM (as 32-bit float, so a FLAC on disk costs 2-3 x its size).
At launch this file asks macOS how much memory the laptop has and how much is free right now, sets a BUDGET
(60 % of total, and at most 90 % of what is free now), prices everything from the sound files' headers, and picks the
richest step that fits:
      36 breath voices + every sweep plane  ->  36 + 41 planes  ->  36 + 21  ->  30 + 21  ->  24 + 21  ->  24 + 11  ->  18 + 11  ->  12 + 11
Breath voices are kept in the tiled order (anna, grisha, raymond, sora, ...), so every performer stays in. Fewer sweep
planes = the same ladder, evenly spaced, in coarser steps (the scrub still crossfades neighbours). The plan is posted
and shown at the top of the window. Quit other big apps (browsers!) before launching to get a richer step.
To force a step, set any of these BEFORE evaluating:
      ~studentVoices = 24;  ~studentPlanes = 41;  ~studentBudgetGB = 10;  ~studentOutDevice = "External Headphones";
Then Server.killAll; and evaluate this file again.

Needs: SuperCollider 3.13+, sc3-plugins, the ATK quark with its kernels and matrices (see README.md), and the
student sound pack unpacked so that this folder (rig/) sits next to song_deconstruct/, wall_of_sound/ and concatenator-corpus/.
*/
(
var here = PathName(thisProcess.nowExecutingPath ?? { Error("open show_student.scd from disk (File > Open), then select all and evaluate").throw }).pathOnly;
var dev = here +/+ "dev";
var files = (wall: dev +/+ "wall_live.scd", sweep: dev +/+ "sweep_sync.scd", force: here +/+ "force_hub.scd",
	breath36: dev +/+ "breath36.scd", ambi: dev +/+ "ambi.scd", tornado: dev +/+ "tornado_engine.scd");
var ready = (wall: "~wlSliders", sweep: "~swSetMenu", force: "~fhMeters", breath36: "~b36Players", ambi: "~ambiBinSyn", tornado: "~tnStartBtn");
var loadOrder = [\force, \wall, \sweep, \breath36, \ambi, \tornado];   // FORCE first (everyone reads ~fhBus); ambi after breath36 (reads ~b36Meta)
var root = here +/+ "..";
var gb = { |bytes| (bytes / 1e9).round(0.1) };
var ramOf = { |path| var sf = SoundFile.openRead(path), b = 0.0; sf !? { b = sf.numFrames.asFloat * sf.numChannels * 4; sf.close }; b };   // Float: 32-bit Integers overflow past 2 GB
var missing = List.new, need, total, avail, budget, fixed, voiceCost, planeCost, maxPlanes, steps, plan, cost, wallJson, tnJson, voicesJson;

// ---------------- 0. is everything installed / unpacked? ----------------
if (\FoaPanB.asClass.isNil or: { \FoaDecoderKernel.asClass.isNil }) {
	"\n*** STUDENT RIG: the Ambisonic Toolkit is missing. Install sc3-plugins and the ATK quark (README.md, step 2), recompile, run again. ***\n".error;
	Error("student rig: not started (see above)").throw };
if (PathName(Atk.userKernelDir).folders.isEmpty) {
	"\n*** STUDENT RIG: the ATK kernels are not downloaded. Run   Atk.downloadKernels; Atk.downloadMatrices;   wait for 'done', run again. ***\n".error;
	Error("student rig: not started (see above)").throw };
need = [
	["36 BREATHS voices", here +/+ "breath36_voices" +/+ "voices.json"],
	["36 BREATHS onsets", here +/+ "sharp" +/+ "onsets.json"],
	["sweep planes", root +/+ "song_deconstruct" +/+ "sweeps"],
	["Phantom Pain", root +/+ "song_deconstruct" +/+ "in" +/+ "phantom_pain.wav"],
	["wall of sound", root +/+ "wall_of_sound" +/+ "analysis" +/+ "live_assets.json"],
	["TORNADO sounds", here +/+ "sharp" +/+ "accents" +/+ "live" +/+ "live.json"]];
need.do { |n| if (File.exists(n[1]).not) { missing.add(n) } };
if (missing.notEmpty) {
	("\n*** STUDENT RIG: the sound pack is missing or in the wrong place. Not found:\n" ++ missing.collect { |n| "    " ++ n[0] ++ ":  " ++ n[1] }.join("\n")
		++ "\nUnpack the pack so that rig/ sits next to song_deconstruct/, wall_of_sound/, concatenator-corpus/ (README.md, step 1). ***\n").error;
	Error("student rig: not started (see above)").throw };

~studentReady = nil;

// ---------------- 1. memory: what this laptop has, what the show costs ----------------
total = "sysctl -n hw.memsize".unixCmdGetStdOut.asFloat;
avail = "vm_stat | awk '/page size of/{ps=$8} /Pages free/{f=$3} /Pages inactive/{i=$3} /Pages speculative/{s=$3} /Pages purgeable/{p=$3} END{printf \"%.0f\", (f+i+s+p)*ps}'".unixCmdGetStdOut.asFloat;
budget = ~studentBudgetGB !? { |g| g * 1e9 } ?? { (total * 0.6).min(avail * 0.9) };
// fixed: wall + TORNADO + Phantom Pain (twice: the sweep's original and TORNADO's row) + the server and sclang themselves
wallJson = File.readAllString(root +/+ "wall_of_sound" +/+ "analysis" +/+ "live_assets.json").parseJSON;
tnJson = File.readAllString(here +/+ "sharp" +/+ "accents" +/+ "live" +/+ "live.json").parseJSON;
fixed = 1.0e9;
fixed = fixed + (wallJson["dyads"].collect(_["file"]) ++ wallJson["voices"].values.collect(_["file"]) ++ wallJson["chords"].values.collect(_["file"]))
	.collect { |f| ramOf.(if (f.beginsWith("/")) { f } { root +/+ "wall_of_sound" +/+ f }) }.sum;
fixed = fixed + { var acc = 0.0, walk; walk = { |x| case
	{ x.isString } { if (x.endsWith(".wav")) { acc = acc + ramOf.(here +/+ "sharp" +/+ "accents" +/+ x) } }
	{ x.isKindOf(Dictionary) } { x.values.do(walk) }
	{ x.isArray } { x.do(walk) } }; walk.(tnJson); acc }.value;
fixed = fixed + (2 * ramOf.(root +/+ "song_deconstruct" +/+ "in" +/+ "phantom_pain.wav"));
voicesJson = File.readAllString(here +/+ "breath36_voices" +/+ "voices.json").parseJSON;
voiceCost = voicesJson["voices"].collect { |v| v["files"].collect { |f| ramOf.(here +/+ "breath36_voices" +/+ f) }.sum }.maxItem;
// the sweep loads ONE set at a time (the menu); price the biggest set present, one variant
maxPlanes = 0; planeCost = 0;
PathName(root +/+ "song_deconstruct" +/+ "sweeps").folders.do { |setDir| setDir.folders.do { |g|
	var fs = (g.fullPath +/+ "plane_*_lr.*").pathMatch;
	if (g.folderName.beginsWith("full") and: { fs.notEmpty }) { maxPlanes = maxPlanes.max(fs.size); planeCost = planeCost.max(ramOf.(fs[0])) } } };
steps = [[36, inf], [36, 41], [36, 21], [30, 21], [24, 21], [24, 11], [18, 11], [12, 11]];   // breaths first (Jon: the most important tab)
if (~studentVoices.notNil) { steps = steps.collect { |st| [~studentVoices, st[1]] } };
if (~studentPlanes.notNil) { steps = steps.collect { |st| [st[0], ~studentPlanes] } };
cost = { |st| fixed + (st[0] * voiceCost) + (st[1].min(maxPlanes) * planeCost) };
plan = steps.detect { |st| cost.(st) <= budget } ?? { steps.last };
~studentPlan = (voices: plan[0], planes: if (plan[1].min(maxPlanes) >= maxPlanes) { nil } { plan[1] }, cost: cost.(plan), budget: budget, total: total, avail: avail);
~studentPlanText = "this laptop: " ++ gb.(total) ++ " GB RAM, " ++ gb.(avail) ++ " GB free now  ->  budget " ++ gb.(budget) ++ " GB"
	++ (if (~studentBudgetGB.notNil) { " (set by ~studentBudgetGB)" } { "" })
	++ "\nloading: " ++ plan[0] ++ " breath voices, sweep " ++ (if (~studentPlan[\planes].isNil) { "every plane (" ++ maxPlanes ++ ")" } { plan[1].asString ++ " of " ++ maxPlanes ++ " planes" })
	++ "  ~ " ++ gb.(cost.(plan)) ++ " GB once a sweep set is chosen"
	++ (if (cost.(plan) > budget) { "   -- OVER BUDGET even at the smallest step: quit other apps, expect glitches" } { "" });
("\nSTUDENT RIG\n" ++ ~studentPlanText ++ "\nprices: fixed (wall, TORNADO, Phantom Pain, server + sclang) " ++ gb.(fixed) ++ " GB, one breath voice "
	++ gb.(voiceCost) ++ " GB, one sweep plane " ++ gb.(planeCost) ++ " GB (" ++ maxPlanes ++ " in the biggest set)\n").postln;

// ---------------- 2. settings the patches read when they load ----------------
~studentMode = true;
~b36MaxVoices = plan[0]; ~b36SpeedLevels = []; ~b36QuadDefault = false; ~b36OutDevice = nil;
~b36Pulse = ~b36Pulse ? (on: false, src: 1, every: 1, bpm: 60, gate: 0.8, jitter: 0, offset: 0);   // own tempo (no metronome tab)
~swPlaneCap = ~studentPlan[\planes];
~ssP = ~ssP ? (on: false, dest: 0, amp: 0.8, offset: 0, lead: 0);   // the original on the main output only
~fhP = ~fhP ? (source: \simulate, rate: 30, strength: 1, hold: 1, gap: 1, drift: 1, noise: 1, couple: 0.15,
	central: \mean, acHere: false, sendOut: false, outHost: "127.0.0.1", outPort: 57121);
~fhLogOn = false;
~ambiStereoOnly = true; ~ambiDefaultOn = true;
~ambiP = ~ambiP ? (quadOn: false, binOn: true, quadDb: 0, binDb: 0, quadType: 0, hrtf: 0, quadMap: [2, 5, 4, 3],
	binOuts: [0, 1], testOn: false, testPeriod: 8, testDb: -18);
~ambiP[\binOuts] = [0, 1]; ~ambiP[\quadOn] = false;

// ---------------- 3. the server: the laptop's stereo output ----------------
s = Server.default;
if (s.serverRunning.not) {
	s.options.numBuffers = 16384; s.options.maxNodes = 8192; s.options.memSize = 2.pow(19);
	s.options.numInputBusChannels = 0; s.options.numOutputBusChannels = 2;
	s.options.outDevice = ~studentOutDevice; s.options.inDevice = ~studentOutDevice;   // nil = the Mac's default output
	s.options.sampleRate = nil;   // the device's own rate (44.1 or 48 k; every patch rate-corrects its files)
};

// ---------------- 4. the window: tabs on top, one panel per patch ----------------
~stNames = [\breath36, \sweep, \wall, \tornado, \force, \ambi];
~stLabels = (breath36: "36 BREATHS", sweep: "PHANTOM PAIN SWEEP", wall: "WALL OF SOUND", tornado: "TORNADO (ending)", force: "FORCE (simulated)", ambi: "AMBI (binaural)");
~stOwnerFor = (breath36: \breath36, sweep: \sweep, wall: \wall, tornado: \tornado, force: \force, ambi: \breath36);
~stWin !? { if (~stWin.isClosed.not) { ~stWin.onClose = nil; ~stWin.close } };
~stWin = Window("Supra-Organism (student)", Rect(40, 30, 1200, (Window.availableBounds.height - 60).min(1080))).front;
~stPanels = ~stNames.collect { View().layout_(VLayout().margins_(0).spacing_(0)) };
~stStack = StackLayout(*~stPanels);
~stButtons = ~stNames.collect { |n, i|
	Button().states_([[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.black, Color.grey(0.85)],
		[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.white, Color.blue(0.45)]])
		.fixedHeight_(34).action_({ ~stShow.(n) }) };
~stPlanView = StaticText().string_(~studentPlanText ++ "\nloading ...").font_(Font.monospace(11)).background_(Color.grey(0.93));
~stWin.layout = VLayout(~stPlanView, HLayout(*~stButtons).margins_(2), ~stStack).margins_(4).spacing_(4);
~stShow = { |name| var i = ~stNames.indexOf(name);
	~stStack.index = i; ~stButtons.do { |b, j| b.value = (j == i).asInteger };
	~stOwnerFor[name] !? { |o| ~mkOwners = (~mkOwners ? []).add(o).asSet.asArray; ~mkOwner = o };
	~stCurrent = name };
~stWin.view.keyDownAction = { |v, char| var i = "123456".indexOf(char); i !? { ~stShow.(~stNames[i]) } };
~stScrolls = ~stScrolls ? IdentityDictionary.new;
~stHost = { |name| var v = View(), sv = ScrollView().hasHorizontalScroller_(false).hasBorder_(false);
	~stScrolls[name] !? { |o| if (o.isClosed.not) { o.remove } };
	sv.canvas = v; ~stScrolls[name] = sv; ~stPanels[~stNames.indexOf(name)].layout.add(sv); v };
~stWin.onClose = { ~stHost = nil };
~stShow.(\breath36);

// ---------------- 5. boot, then load the patches one after another ----------------
s.waitForBoot({
	fork {
		var failed = List.new;
		("student rig: server up at " ++ s.sampleRate.asInteger ++ " Hz on " ++ (s.options.outDevice ? "the default output")).postln;
		loadOrder.do { |name|
			var t0 = Main.elapsedTime, before = ready[name].interpret, probe;
			("tabs: loading " ++ name ++ " ...").postln;
			{ ~stPlanView.string = ~studentPlanText ++ "\nloading " ++ ~stLabels[name] ++ " ..." }.defer;
			{ thisProcess.interpreter.executeFile(files[name]) }.defer;
			probe = { var now = ready[name].interpret; now.notNil and: { now !== before } };
			while { probe.value.not and: { (Main.elapsedTime - t0) < (if (name == \breath36) { 300 } { 90 }) } } { 0.5.wait };
			if (probe.value) { ("tabs: " ++ name ++ " ready in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s").postln }
				{ failed.add(name); ("tabs: " ++ name ++ " NOT ready -- see the post window").warn };
			1.wait;
		};
		{ ~stShow.(~stCurrent ? \breath36);
			~stPlanView.string = ~studentPlanText ++ "\n" ++ (if (failed.isEmpty) { "ready. Headphones on. Pick a sweep set in tab 2 to load it." }
				{ "NOT READY: " ++ failed.collect { |n| ~stLabels[n] }.join(", ") ++ " -- see the post window" }) }.defer;
		~studentReady = failed.isEmpty; ~studentFailed = failed;
		"SHOW_STUDENT_READY".postln;
	};
}, 100, { "\n*** STUDENT RIG: the audio server did not start. Usually the Mac's input and output run at different sample rates: in Audio MIDI Setup set both to 48000 Hz (or choose the output with ~studentOutDevice = \"...\"; ServerOptions.outDevices lists them), then Server.killAll; and run again. ***\n".error });
)
