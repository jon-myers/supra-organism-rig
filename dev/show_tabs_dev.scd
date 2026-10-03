/*
show_tabs_dev.scd (rig/dev/) -- the DEV launcher. Rehearsal-safe: it only ADDS files in rig/dev/; rig/show_tabs.scd is
the stable one and nothing it loads was changed. Use the stable one when in doubt.
Same window and tabs as show_tabs.scd, with three dev variants swapped in (see dev/README.md):
  PHANTOM PAIN SWEEP  dev/sweep_sync.scd   the original locked to the sweep; main output and/or the metronome's
                                           headphone device
  METRONOME           dev/metro_dual.scd   + a toggleable click on the interface (main server), dB volume per path
  7 BREATH FORCE      dev/force_breath.scd force perturbs the 36 breath voices around their centres
  9 CONCAT            dev/concat_live.scd  The Concatenator live: corpus menu x target menu (Phantom Pain, ocean, ...), to a device
  8 AMBI              dev/ambi.scd         first-order ambisonics (ATK): quad decode to outs 3-6 + binaural to Phones 1 (7/8)
Unchanged, loaded from rig/: force_hub.scd. Dev copy since 2026-10-01: rite_live.scd (ambisonic + GO / SWIRL triggers). Dev copies: wall_live.scd (live master + trims), breath36.scd (QUAD on outs 3-6).
To try it: Server.killAll; then select all here, evaluate.

show_tabs.scd -- ONE window: a row of tabs along the top, each patch's controls underneath. Select all, evaluate.

  1 36 BREATHS   breath36.scd     2 PHANTOM PAIN SWEEP   sweep_live.scd
  3 WALL OF SOUND  wall_live.scd  4 METRONOME            metro.scd (own server, own output menu)
  5 RITE OF SPRING rite_live.scd  (eight concatenator renders looping together, one fader each)
  6 FORCE          force_hub.scd  (14 force signals -> buses: simulate / faders / hardware OSC / playback)

Each patch builds its controls into this window's tab panel instead of its own window (the ~stHost hook
in each file; without it -- show.scd, or evaluating a patch on its own -- they make their own windows as
before). Hidden tabs keep running; only the view changes. The nanoKONTROL2 follows the selected tab.
Keys 1-6 switch tabs while this window is focused. Closing this window closes every patch (their normal
close/teardown runs). Patches load one after another, breath36 last (~15 s).
*/
(
// nowExecutingPath is nil when this is run from an unsaved / untitled document (2026-10-01): fall back to the known location
var here = PathName(thisProcess.nowExecutingPath ? "~/Documents/2026/MIT/projects/supra-organism/rig/dev/show_tabs_dev.scd".standardizePath).pathOnly;
var files = (metro: "metro_dual.scd", wall: "wall_live.scd", sweep: "sweep_sync.scd", rite: "rite_live.scd", force: "../force_hub.scd", breath36: "breath36.scd", fbreath: "force_breath.scd", ambi: "ambi.scd", concat: "concat_live.scd", solo: "stems_live.scd", follow: "tornado_live.scd", tornado: "tornado_engine.scd");
var ready = (metro: "~msWin", wall: "~wlSliders", sweep: "~swSetMenu", rite: "~rtFaders", force: "~fhMeters", breath36: "~b36Players", fbreath: "~fbGrid", ambi: "~ambiQuadSyn", concat: "~clRunBtn", solo: "~soPlayBtn", follow: "~fwPlayBtn", tornado: "~tnStartBtn");
var loadOrder = [\metro, \wall, \sweep, \rite, \force, \breath36, \fbreath, \ambi, \concat, \solo, \follow, \tornado];   // ambi after breath36 (reads ~b36Meta)
~stNames = [\breath36, \sweep, \wall, \metro, \rite, \force, \fbreath, \ambi, \concat, \solo, \follow, \tornado];                        // tab order (10th = key 0, 11th = key -, 12th = key =)
~stLabels = (breath36: "36 BREATHS", sweep: "PHANTOM PAIN SWEEP", wall: "WALL OF SOUND", metro: "METRONOME", rite: "RITE OF SPRING", force: "FORCE", fbreath: "BREATH FORCE", ambi: "AMBI", concat: "CONCAT", solo: "SOLO (particles)", follow: "FOLLOW (tornado files)", tornado: "TORNADO (live ending)");
~stOwnerFor = (breath36: \breath36, sweep: \sweep, wall: \wall, metro: nil, rite: \rite, force: \force, fbreath: \breath36, ambi: \breath36, concat: \breath36, solo: \breath36, follow: \breath36, tornado: \tornado);   // BREATH FORCE: the Korg keeps playing the breaths (the centres)   // metro has no controller mapping

s = Server.default;
// sample rates (2026-10-02): before anything boots, put the default INPUT back on the MacBook mic (a headset that is the default
// input drops into call mode at 16-32 kHz) and the Fireface + Multi-Output Device (+ members) at 48 kHz. rig/tools/audiorate.swift.
~stRate = 44100;   // THE rig's sample rate (fallback; replaced below by the rate audiorate picks) (2026-10-02: 44.1 k, not 48 k -- Bluetooth in-ears in call mode still offer 44.1 k,
                            // so the Fireface, the Multi-Output in-ears and the lav can share one rate; the renders are 44.1 k too)
// ...chosen AT LAUNCH (2026-10-02): `audiorate rig` (no rate) picks the best rate the in-ears AND the Fireface offer right now
// (48 k, else 44.1 k) and prints "RIG RATE n"; everything boots at that. Set ~stRate before running this to force one.
// the BTD 700 keepalive (2026-10-02 night): -70 dBFS pink noise to the dongle from OUTSIDE SC, so the Auracast broadcast (and the
// headphones joined to it) survives every SC reboot. Starts it if it is not already running; harmless if it is.
if (File.exists("~/.local/bin/btd_keepalive".standardizePath)) { ("tabs: " ++ ("~/.local/bin/btd_keepalive start".standardizePath).unixCmdGetStdOut).postln };
if (File.exists("~/.local/bin/audiorate".standardizePath)) { var out = ("~/.local/bin/audiorate rig " ++ (~stRateForce ? "")).standardizePath.unixCmdGetStdOut, r;
	("tabs: audio rates\n" ++ out).postln;
	r = out.findRegexp("RIG RATE ([0-9]+)"); if (r.size > 1) { ~stRate = r[1][1].asInteger } };
("tabs: rig sample rate = " ++ ~stRate).postln;
if (s.serverRunning.not) {
	s.options.numBuffers = 16384; s.options.maxNodes = 8192; s.options.memSize = 2.pow(19);
	s.options.numInputBusChannels = 0; s.options.inDevice = "MacBook Pro Microphone";
	s.options.numOutputBusChannels = 8;   // quad breath36 on outs 3-6 (buses 2-5); stereo patches stay on 1-2
	// main output named explicitly (Jon, 2026-09-29): a Bluetooth device that connects (someone's AirPods) can take
	// the Mac's default output and the main server then fails with "could not initialize audio". Change for the Fireface.
	// Preference list: the first one connected wins (2026-10-01: RME Fireface UCX II first, then the PreSonus Studio 1824c).
	// Matched by name PREFIX: CoreAudio appends the serial ("Fireface UCX II (24312654)").
	~stOutPrefs = ~stOutPrefs ? ["Fireface UCX II", "Studio 1824c", "Scarlett 2i2 4th Gen"];
	~stOutDevice = ~stOutPrefs.collect { |p| ServerOptions.outDevices.detect { |d| d.beginsWith(p) } }.reject(_.isNil).first;
	if (~stOutDevice.isNil) { ("NONE OF " ++ ~stOutPrefs ++ " IS CONNECTED -- main output = the Mac's default").warn };
	s.options.outDevice = ~stOutDevice;
	// input = the Fireface too (2026-10-02): the main server opens an input device even with 0 input channels, and the MacBook
	// mic at 44.1 k against the Fireface at 48 k made scsynth exit silently ("exit code 0"). One device = one clock.
	~stOutDevice !? { s.options.inDevice = ~stOutDevice };
	s.options.sampleRate = ~stRate;   // pinned (2026-10-02): never inherit a rate a headset dragged the Fireface to (32 kHz broke AMBI's HRTFs)
	("show_tabs_dev: main output = " ++ (~stOutDevice ? "system default")).postln;
};

// ---- the window: tabs on top, one panel per patch in a stack ----
~stWin !? { if (~stWin.isClosed.not) { ~stWin.onClose = nil; ~stWin.close } };
~stWin = Window("Supra-Organism (DEV)", Rect(40, 30, 1200, (Window.availableBounds.height - 60).min(1080))).front;
~stPanels = ~stNames.collect { View().layout_(VLayout().margins_(0).spacing_(0)) };
~stStack = StackLayout(*~stPanels);
~stButtons = ~stNames.collect { |n, i|
	Button().states_([[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.black, Color.grey(0.85)],
		[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.white, Color.blue(0.45)]])
		.fixedHeight_(34).action_({ ~stShow.(n) }) };
~stWin.layout = VLayout(HLayout(*~stButtons).margins_(2), ~stStack).margins_(4).spacing_(4);
~stShow = { |name| var i = ~stNames.indexOf(name);
	~stStack.index = i; ~stButtons.do { |b, j| b.value = (j == i).asInteger };
	~stOwnerFor[name] !? { |o| ~mkOwners = (~mkOwners ? []).add(o).asSet.asArray; ~mkOwner = o };
	~stCurrent = name };
~stWin.view.keyDownAction = { |v, char| var i = "1234567890-=".indexOf(char); i !? { ~stShow.(~stNames[i]) } };
// a patch asks for its panel: give it a fresh child view in its tab (it closes the old one itself on reload)
// (2026-10-02) inside a vertical ScrollView, so a tall patch (breath36) can be scrolled instead of running off the screen; a reload
// removes the tab's previous scroller.
~stScrolls = ~stScrolls ? IdentityDictionary.new;
~stHost = { |name| var v = View(), sv = ScrollView().hasHorizontalScroller_(false).hasBorder_(false);
	~stScrolls[name] !? { |o| if (o.isClosed.not) { o.remove } };
	sv.canvas = v; ~stScrolls[name] = sv; ~stPanels[~stNames.indexOf(name)].layout.add(sv); v };
~stWin.onClose = { ~stHost = nil };
~stShow.(\breath36);

fork {
	loadOrder.do { |name|
		var t0 = Main.elapsedTime, before = ready[name].interpret, probe;
		("tabs: loading " ++ name ++ " ...").postln;
		{ thisProcess.interpreter.executeFile(here +/+ files[name]) }.defer;
		probe = { var now = ready[name].interpret; now.notNil and: { now !== before } };
		while { probe.value.not and: { (Main.elapsedTime - t0) < (if (name == \breath36) { 180 } { 60 }) } } { 0.5.wait };
		(if (probe.value) { "tabs: " ++ name ++ " ready in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s" }
			{ "tabs: " ++ name ++ " NOT ready -- see the post window" }).postln;
		1.wait;
	};
	{ ~stShow.(~stCurrent ? \breath36) }.defer;   // re-assert the selected tab's controller ownership after all loads
	"SHOW_TABS_READY".postln;
};
)
