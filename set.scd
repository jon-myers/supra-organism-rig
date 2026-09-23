// set.scd -- open the metronome slider, the breath chorus, and the
// breath -> harmonium chorus together, on one server.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath_chorus.scd");
thisProcess.interpreter.executeFile(here +/+ "breath_morph.scd");
)
