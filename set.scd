// set.scd -- open the metronome slider and the breath chorus together, on one server.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath_chorus.scd");
)
