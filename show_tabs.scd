/*
show_tabs.scd -- ONE window: a row of tabs along the top, each patch's controls underneath. Select all, evaluate.

  1 36 BREATHS   breath36.scd     2 PHANTOM PAIN SWEEP   sweep_live.scd
  3 WALL OF SOUND  wall_live.scd  4 METRONOME            metro.scd (own server, own output menu)
  5 RITE OF SPRING rite_live.scd  (eight concatenator renders looping together, one fader each)

Each patch builds its controls into this window's tab panel instead of its own window (the ~stHost hook
in each file; without it -- show.scd, or evaluating a patch on its own -- they make their own windows as
before). Hidden tabs keep running; only the view changes. The nanoKONTROL2 follows the selected tab.
Keys 1-5 switch tabs while this window is focused. Closing this window closes every patch (their normal
close/teardown runs). Patches load one after another, breath36 last (~15 s).
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
var files = (metro: "metro.scd", wall: "wall_live.scd", sweep: "sweep_live.scd", rite: "rite_live.scd", breath36: "breath36.scd");
var ready = (metro: "~msWin", wall: "~wlSliders", sweep: "~swSetMenu", rite: "~rtFaders", breath36: "~b36Players");
var loadOrder = [\metro, \wall, \sweep, \rite, \breath36];
~stNames = [\breath36, \sweep, \wall, \metro, \rite];                        // tab order
~stLabels = (breath36: "36 BREATHS", sweep: "PHANTOM PAIN SWEEP", wall: "WALL OF SOUND", metro: "METRONOME", rite: "RITE OF SPRING");
~stOwnerFor = (breath36: \breath36, sweep: \sweep, wall: \wall, metro: nil, rite: \rite);   // metro has no controller mapping

s = Server.default;
if (s.serverRunning.not) {
	s.options.numBuffers = 16384; s.options.maxNodes = 8192; s.options.memSize = 2.pow(19);
	s.options.numInputBusChannels = 0; s.options.inDevice = "MacBook Pro Microphone";
};

// ---- the window: tabs on top, one panel per patch in a stack ----
~stWin !? { if (~stWin.isClosed.not) { ~stWin.onClose = nil; ~stWin.close } };
~stWin = Window("Supra-Organism", Rect(40, 30, 1200, (Window.availableBounds.height - 60).min(1080))).front;
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
~stWin.view.keyDownAction = { |v, char| var i = "12345".indexOf(char); i !? { ~stShow.(~stNames[i]) } };
// a patch asks for its panel: give it a fresh child view in its tab (it closes the old one itself on reload)
~stHost = { |name| var v = View(); ~stPanels[~stNames.indexOf(name)].layout.add(v); v };
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
