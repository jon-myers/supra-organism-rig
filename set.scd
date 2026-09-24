// set.scd -- open the metronome slider and the breath swarm (live collage,
// 1-216 voices) together, on one server. Other patches can be opened alongside:
// breath_pitched.scd (20 baked pitched voices), breath_morph.scd, breath_chorus.scd.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
Server.default.options.maxNodes = 8192;   // the swarm runs hundreds of grains
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath_swarm.scd");
)
