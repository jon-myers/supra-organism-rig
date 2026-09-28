/*
show_stack.scd -- the four patches as separate windows STACKED under a tab strip (superseded by show_tabs.scd). Select all, evaluate.

Loads metro / wall / sweep / breath36 exactly as show.scd does (their files are not modified), then puts
a tab strip across the top of the screen and stacks the four patch windows in one place under it.
Clicking a tab (or pressing 1-4 while the strip is focused) shows that patch's window and hides the
others. The nanoKONTROL2 follows the tab, because each patch takes the controller when its window comes
to the front. Hidden patches keep running (their sound is unaffected); only their window is hidden.
Closing the tab strip shows all windows again. show.scd (separate windows) keeps working unchanged.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~stNames = [\breath36, \sweep, \wall, \metro];                       // tab order
~stLabels = (breath36: "36 BREATHS", sweep: "PHANTOM PAIN SWEEP", wall: "WALL OF SOUND", metro: "METRONOME");
~stWinFor = { |name| switch (name, \breath36, { ~b36Win }, \sweep, { ~swWin }, \wall, { ~wlWin }, \metro, { ~msWin }) };
~stTop = 30; ~stStripH = 54;

fork {
	var t0 = Main.elapsedTime;
	thisProcess.interpreter.executeFile(here +/+ "show.scd");      // loads everything (and prints SHOW_READY)
	// wait until every enabled patch has a window
	while { (~stNames.every { |n| ~stWinFor.(n).notNil }).not and: { (Main.elapsedTime - t0) < 300 } } { 0.5.wait };
	2.wait;
	{
		var screen = Window.availableBounds, area = Rect(screen.left, screen.top + ~stTop + ~stStripH, screen.width.min(1180), screen.height - ~stTop - ~stStripH);
		~stWin !? { if (~stWin.isClosed.not) { ~stWin.onClose = nil; ~stWin.close } };
		~stWin = Window("Supra-Organism", Rect(screen.left, screen.top + ~stTop, area.width, ~stStripH), resizable: false).front;
		~stButtons = ~stNames.collect { |n, i|
			Button().states_([[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.black, Color.grey(0.85)],
				[(i + 1).asString ++ "  " ++ ~stLabels[n], Color.white, Color.blue(0.45)]])
				.fixedHeight_(38).action_({ ~stShow.(n) }) };
		~stWin.layout = HLayout(*~stButtons);
		~stWin.view.keyDownAction = { |v, char| var i = "1234".indexOf(char); i !? { ~stShow.(~stNames[i]) } };
		// stack every patch window in the same place under the strip
		~stNames.do { |n| ~stWinFor.(n) !? { |w| if (w.isClosed.not) { w.bounds = area } } };
		~stShow = { |name|
			~stNames.do { |n, i| var w = ~stWinFor.(n);
				~stButtons[i].value = (n == name).asInteger;
				w !? { if (w.isClosed.not) { if (n == name) { w.visible = true; w.front } { w.visible = false } } } };
			~stCurrent = name;
		};
		~stWin.onClose = { ~stNames.do { |n| ~stWinFor.(n) !? { |w| if (w.isClosed.not) { w.visible = true } } } };
		~stShow.(\breath36);
		"SHOW_TABS_READY".postln;
	}.defer;
};
)
