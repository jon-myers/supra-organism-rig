// set.scd -- open the metronome slider and the pitched breath -> harmonium chorus
// together, on one server. The other patches (breath_chorus.scd = plain breath,
// breath_morph.scd = unpitched harmonium) can be opened alongside: evaluate them too.
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(here +/+ "metro_slider.scd");
thisProcess.interpreter.executeFile(here +/+ "breath_pitched.scd");
)
