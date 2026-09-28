/*
show.scd -- launch the Supra-Organism show patches in one go. Select all, evaluate.

  metro       metro.scd       own server (port 57131) -> ~msOutDevice (default "Multi-Output Device")
  wall        wall_live.scd   default server: live wall of sound (dyads / voices / chords densities)
  sweep       sweep_live.scd  default server: Phantom Pain LatentFT ladder sweep (two-plane crossfade)
  breath36    breath36.scd    default server: 36 breaths -> harmonium, speed, gap
Set any entry to false below to skip it. The default server's options are set once here, before the
first boot, so every patch gets enough buffers / nodes / memory. Patches load one after another (each
waits for the previous to report READY), because breath36 alone reads ~1440 buffers.
nanoKONTROL2: every patch registers as an owner; the LAST one loaded owns the surface first, and the
TRACK < > buttons pass it along (the owning window says so). Re-evaluating this file is safe: each patch
tears down its previous instance.
Memory: breath36 ~21 GB (all seven speed levels) + one sweep set ~4.5 GB + wall ~1.7 GB.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
var order = [
	\metro    -> true,
	\wall     -> true,
	\sweep    -> true,
	\breath36 -> true,     // loaded last: owns the nanoKONTROL2 at start
];
var files = (metro: "metro.scd", wall: "wall_live.scd", sweep: "sweep_live.scd", breath36: "breath36.scd");
var ready = (metro: "~msWin", wall: "~wlSliders", sweep: "~swSetMenu", breath36: "~b36Players");

~stHost = nil;   // separate windows (show_tabs.scd sets its own host)
s = Server.default;
if (s.serverRunning.not) {
	s.options.numBuffers = 16384; s.options.maxNodes = 8192; s.options.memSize = 2.pow(19);
	s.options.numInputBusChannels = 0; s.options.inDevice = "MacBook Pro Microphone";
	~b36OutDevice !? { if (ServerOptions.outDevices.includesEqual(~b36OutDevice)) { s.options.outDevice = ~b36OutDevice } };
};
fork {
	order.do { |a|
		var name = a.key, t0 = Main.elapsedTime, probe, before;
		if (a.value) {
			("show: loading " ++ name ++ " ...").postln;
			before = ready[name].interpret;   // an instance from an earlier load: wait for a NEW one
			{ thisProcess.interpreter.executeFile(here +/+ files[name]) }.defer;
			probe = { var now = ready[name].interpret; now.notNil and: { now !== before } };
			// wait for the patch to come up (metro may wait on its device; move on after 60 s)
			while { probe.value.not and: { (Main.elapsedTime - t0) < (if (name == \breath36) { 180 } { 60 }) } } { 0.5.wait };
			(if (probe.value) { "show: " ++ name ++ " ready in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s" }
				{ "show: " ++ name ++ " NOT ready after " ++ (Main.elapsedTime - t0).round ++ " s -- check its window / post window" }).postln;
			2.wait;
		} { ("show: skipping " ++ name).postln };
	};
	"SHOW_READY".postln;
};
)
