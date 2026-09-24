// set.scd -- open the metronome slider and the 36 individual breaths together,
// on one server. Optional alongside: force_layer.scd (sensor modulation, after
// breath36), breath_swarm.scd, breath_pitched.scd, breath_morph.scd, breath_chorus.scd.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
Server.default.options.maxNodes = 8192;
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath36.scd");
)
