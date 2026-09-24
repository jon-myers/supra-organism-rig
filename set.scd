// set.scd -- open the metronome slider and the 36 individual breaths together,
// on one server. Optional alongside: force_layer.scd (sensor modulation, after
// breath36), breath_swarm.scd, breath_pitched.scd, breath_morph.scd, breath_chorus.scd.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
Server.default.options.maxNodes = 8192;
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath36.scd");
// once loaded, put every window on the current screen, in front
fork { var t = 0;
	while { ~b36Win.isNil and: { t < 240 } } { 1.wait; t = t + 1 };
	{ var sb = Window.screenBounds;
		~msWin !? { ~msWin.bounds = Rect(40, sb.height - 380, 900, 330); ~msWin.front };
		~b36Win !? { ~b36Win.bounds = Rect(40, 40, 1080, 880).sect(sb); ~b36Win.front };
		"WINDOWS_FRONT".postln }.defer;
};
)
