/*
force_layer.scd -- six force sensors (simulated for now) + random walks + slow LFOs,
driving the morph of the 36 voices in breath36.scd. Open breath36.scd first.

Sensors: each one is the press process from ForceSensorSimulator.maxpat (a press of
random strength 0.1-0.9 held 0.5-2.5 s, then a 0.1-2.1 s pause), plus slow baseline
drift, a little noise and hand tremor. Each sensor has a temperament (holder, tapper,
...) and presses can be contagious (coupling: a press cuts the other sensors' pauses
short). "source: FORCE tab" swaps the simulation for the DC buses of force_hub.scd
(~fhBus.index + k, k 0-5), so the grid runs off whatever the hub is fed: its own
simulator, nanoKONTROL faders, live OSC from the hardware, or a recording.
This file listens to no OSC itself; the hub owns the /force OSC paths.

Grid mapping: voice i sits at row i div 6, column i mod 6 and follows
sensor[row] x sensor[col]. The six diagonal voices (1, 8, 15, 22, 29, 36) follow one
sensor each; the other 30 move only when both of their sensors are pressed. "geometric
mean" takes the square root of the product so a duet can reach full level; "raw
product" keeps it small unless both press hard.

Per voice:  morph = its slider (breath36) + sensAmt * grid term
                  + walkAmt * random walk (Ornstein-Uhlenbeck, time constant walkTau)
                  + lfoAmt * slow sine (period ~lfoPeriod, phase spread by pan position)
clipped 0..1. Walks and LFOs push both ways, so they only show above 0 if the voice's
own slider (or ALL) is raised off the bottom.

Everything runs on the server in a group ahead of the voices; the language only
schedules presses (~3 per second in total). Readouts are stepped numbers at 4 Hz.
Nothing moves the voices until you press "layer: bypassed" to engage it.
*/
(
s = Server.default;
if (~b36Synths.isNil) { "force_layer: open breath36.scd first (no ~b36Synths)".warn } {
~flWin !? { if (~flWin.isClosed.not) { ~flWin.close } };
~flGui = ~flGui ? true;

~flP = (floor: 0.1, sensAmt: 0.8, sensLag: 0.08, geo: 1,
	walkAmt: 0.08, walkTau: 8, lfoAmt: 0.1, lfoPeriod: 40, lfoSpread: 1,
	hold: 1, gap: 1, couple: 0.15);
~flMixKeys = [\floor, \sensAmt, \geo, \sensLag, \walkAmt, \walkTau, \lfoAmt, \lfoPeriod, \lfoSpread];
// hold / gap scale press length and pause; strength scales press force
~flTemper = [
	(name: "even",     hold: 1.0, gap: 1.0, strength: 1.0),
	(name: "holder",   hold: 2.5, gap: 1.6, strength: 0.9),
	(name: "tapper",   hold: 0.4, gap: 0.5, strength: 0.8),
	(name: "soft",     hold: 1.3, gap: 1.0, strength: 0.5),
	(name: "hesitant", hold: 1.0, gap: 3.0, strength: 1.1),
	(name: "even",     hold: 1.0, gap: 1.2, strength: 1.0)
];
// per-voice LFO rate factors 0.8-1.25, spread by the golden ratio (fixed, not random)
~flRates = 36.collect { |i| 0.8 * (1.5625 ** ((i * 0.618034) % 1)) };

fork {
	SynthDef(\flSensor, { |out, t_trig = 0, amp = 0.5, dur = 1, drift = 0.03, noise = 0.004,
		tremor = 0.04, useExt = 0, extBus, extLag = 0.05|
		// press shape from the Max patch: rise over ~28% of the press, decay over the rest
		var env = EnvGen.kr(Env([0, 0.862, 0], [0.28, 0.72], [-2, -1]), t_trig,
			levelScale: amp, timeScale: dur);
		var sim = env * (1 + (tremor * LFNoise2.kr(9))) + LFNoise2.kr(0.03).range(0, drift)
			+ (LFNoise1.kr(20) * noise);
		Out.kr(out, Select.kr(useExt, [sim, Lag.kr(In.kr(extBus), extLag)]).clip(0, 1));
	}).add;

	SynthDef(\flMix, { |sens, out, sensAmt = 0.8, geo = 1, sensLag = 0.08,
		walkAmt = 0.08, walkTau = 8, lfoAmt = 0.1, lfoPeriod = 40, lfoSpread = 1, floor = 0.1|
		// floor: force below it counts as "not pressed" (resting drift must not leak into pairs)
		var s6 = ((In.kr(sens, 6) - floor).max(0) / (1 - floor.min(0.9)));
		var pans = \pans.kr(0 ! 36);
		var a = exp(-1 / (walkTau.max(0.1) * ControlRate.ir));
		var norm = ((1 + a) / (1 - a)).sqrt * 3.sqrt;   // one-pole-filtered white noise -> unit sd
		Out.kr(out, 36.collect { |i|
			var p = s6[i.div(6)] * s6[i % 6];
			var term = Select.kr(geo, [p, p.max(0).sqrt]);
			var walk = (OnePole.kr(WhiteNoise.kr, a) * norm).clip(-3, 3);
			var lfo = SinOsc.kr(lfoPeriod.max(1).reciprocal * ~flRates[i], pans[i] * pi * lfoSpread);
			(Lag.kr(term, sensLag) * sensAmt) + (walk * walkAmt) + (lfo * lfoAmt)
		});
	}).add;
	s.sync;

	~flGrp = Group.head(s);   // ahead of the default group, where breath36's voices live
	~flSensBus = Bus.control(s, 6);
	~flSilent = Bus.control(s, 1).set(0);
	~flOutBus = Bus.control(s, 36);
	s.bind {
		~flSensors = 6.collect { |k| Synth(\flSensor, [\out, ~flSensBus.index + k,
			\extBus, ~flSilent.index], ~flGrp) };
		~flMix = Synth(\flMix, [\sens, ~flSensBus.index, \out, ~flOutBus.index,
			\pans, ~b36Pan] ++ ~flMixKeys.collect { |k| [k, ~flP[k]] }.flat,
			~flGrp, \addToTail);
	};
	s.sync;

	// ---------------- presses (language side) ----------------
	~flPresses = 0 ! 6; ~flGapLeft = 0 ! 6;
	~flPress = { |k|
		var t = ~flTemper[k];
		var amp = ((9.rand + 1) * 0.1 * t[\strength]).clip(0.05, 1);
		var dur = (0.5 + 2.0.rand) * t[\hold] * ~flP[\hold];
		s.bind { ~flSensors[k].set(\amp, amp, \dur, dur, \t_trig, 1) };
		~flPresses[k] = ~flPresses[k] + 1;
		6.do { |j| if ((j != k) and: { ~flP[\couple].coin }) { ~flGapLeft[j] = ~flGapLeft[j] * 0.3 } };
		dur
	};
	~flSimOn = false;
	~flStartSim = {
		~flRouts.do(_.stop);
		~flRouts = 6.collect { |k| Routine {
			(k * 0.37 + 0.3.rand).wait;
			loop {
				~flPress.(k).wait;
				~flGapLeft[k] = (0.1 + 2.0.rand) * ~flTemper[k][\gap] * ~flP[\gap];
				while { ~flGapLeft[k] > 0 } { 0.05.wait; ~flGapLeft[k] = ~flGapLeft[k] - 0.05 };
			}
		}.play(SystemClock) };
		~flSimOn = true;
	};
	~flStopSim = { ~flRouts.do(_.stop); ~flRouts = nil; ~flSimOn = false };

	// ---------------- external sensors: force_hub.scd's DC buses ----------------
	~flExt = false;
	~flSetExt = { |on|
		if (on and: { ~fhBus.isNil }) {
			"force_layer: open the FORCE tab (force_hub.scd) first -- no ~fhBus".warn; on = false };
		~flExt = on;
		if (on) { ~flStopSim.() };
		~flSensors.do { |sy, k| sy.set(\useExt, on.asInteger,
			\extBus, if (on) { ~fhBus.index + k } { ~flSilent.index }) };
		on
	};

	// ---------------- engage ----------------
	~flEngaged = false;
	~flEngage = { |on|
		~flEngaged = on;
		if (on) { 36.do { |i| ~b36SetMod.(i, ~flOutBus.index + i, 1) } } { ~b36ClearMod.() };
	};
	~flSet = { |key, v|
		~flP[key] = v;
		if (~flMixKeys.includes(key)) { ~flMix.set(key, v) };
	};
	~flCleanup = {
		~flStopSim.();
		if (~b36Synths.notNil and: { ~flEngaged }) { ~b36ClearMod.() };
		~flEngaged = false;
		~flGrp.free; ~flSensBus.free; ~flSilent.free; ~flOutBus.free;
		~flRout.stop;
	};
	~flSensVal = 0 ! 6; ~flOutVal = 0 ! 36;
	~flStartSim.();

	if (~flGui) { { ~flMakeGui.() }.defer } { "FORCE_LAYER_READY".postln };
};

// ---------------- GUI ----------------
~flMakeGui = {
	var box, btn, voices = ~b36Meta["voices"], bold = Font.default.boldVariant;
	var sensText, pressText, cellText, simBtn, extBtn, engBtn, geoBtn;
	box = { |key, lo, hi, step, dec|
		NumberBox().clipLo_(lo).clipHi_(hi).step_(step).scroll_step_(step).decimals_(dec)
			.value_(~flP[key]).fixedWidth_(56).action_({ |nb| ~flSet.(key, nb.value) })
	};
	btn = { |off, on, val, act|
		Button().states_([[off, Color.black, Color.white], [on, Color.white, Color.blue(0.5)]])
			.value_(val.asInteger).fixedWidth_(170).action_(act)
	};
	~flWin = Window("force layer: 6 sensors -> 36 breaths (grid)", Rect(1150, 60, 760, 820)).front;
	engBtn = btn.("layer: bypassed", "layer: ENGAGED", ~flEngaged, { |b| ~flEngage.(b.value == 1) });
	simBtn = btn.("simulation stopped", "simulation running", ~flSimOn,
		{ |b| if (b.value == 1) { ~flStartSim.() } { ~flStopSim.() } });
	extBtn = btn.("source: simulated", "source: FORCE tab", ~flExt, { |b|
		b.value = ~flSetExt.(b.value == 1).asInteger;
		if (b.value == 1) { simBtn.value = 0 } });
	geoBtn = btn.("mapping: raw product", "mapping: geometric mean", ~flP[\geo] == 1,
		{ |b| ~flSet.(\geo, b.value) });

	sensText = 6.collect { StaticText().string_("0").align_(\center).fixedWidth_(90)
		.font_(Font.default.size_(20).boldVariant) };
	pressText = 6.collect { StaticText().string_("0 presses").align_(\center).fixedWidth_(90) };
	cellText = 36.collect { |i|
		StaticText().align_(\center).fixedWidth_(90).fixedHeight_(58)
			.background_(if (i.div(6) == (i % 6)) { Color.gray(0.88) } { Color.clear })
	};

	~flWin.layout = VLayout(
		HLayout(engBtn, simBtn, extBtn, geoBtn, nil),
		HLayout(StaticText().string_("sensor amt"), box.(\sensAmt, -1, 2, 0.05, 2),
			StaticText().string_("smooth s"), box.(\sensLag, 0, 5, 0.02, 2),
			StaticText().string_("floor"), box.(\floor, 0, 0.5, 0.01, 2),
			StaticText().string_("press length x"), box.(\hold, 0.1, 10, 0.1, 1),
			StaticText().string_("pause x"), box.(\gap, 0.1, 20, 0.1, 1),
			StaticText().string_("coupling"), box.(\couple, 0, 1, 0.05, 2), nil),
		HLayout(StaticText().string_("walk amt"), box.(\walkAmt, 0, 0.5, 0.01, 2),
			StaticText().string_("walk time s"), box.(\walkTau, 0.5, 120, 1, 1),
			StaticText().string_("LFO amt"), box.(\lfoAmt, 0, 0.5, 0.01, 2),
			StaticText().string_("LFO period s"), box.(\lfoPeriod, 2, 600, 1, 0),
			StaticText().string_("LFO spread"), box.(\lfoSpread, 0, 4, 0.1, 1), nil),
		StaticText().string_("sensors (force %)").font_(bold),
		HLayout(StaticText().fixedWidth_(40), *(6.collect { |k|
			VLayout(StaticText().string_("S" ++ (k + 1) ++ " " ++ ~flTemper[k][\name])
				.align_(\center).fixedWidth_(90).font_(bold), sensText[k], pressText[k]).spacing_(2)
		} ++ [nil])),
		StaticText().string_("voices: row sensor x column sensor.  number = morph added (%)").font_(bold),
		HLayout(StaticText().fixedWidth_(40), *(6.collect { |c|
			StaticText().string_("S" ++ (c + 1)).align_(\center).fixedWidth_(90).font_(bold) } ++ [nil])),
		*(6.collect { |r|
			HLayout(StaticText().string_("S" ++ (r + 1)).fixedWidth_(40).font_(bold),
				*(6.collect { |c| cellText[r * 6 + c] } ++ [nil]))
		} ++ [nil])
	);

	~flRout = Routine { loop {
		~flSensBus.getn(6, { |v| ~flSensVal = v });
		~flOutBus.getn(36, { |v| ~flOutVal = v });
		6.do { |k|
			sensText[k].string = (~flSensVal[k] * 100).round.asInteger.asString;
			pressText[k].string = ~flPresses[k].asString ++ " presses";
		};
		36.do { |i|
			cellText[i].string = (i + 1).asString ++ "  " ++ voices[i]["note"] ++ "\n"
				++ voices[i]["performer"].keep(6) ++ "\n"
				++ if (i < ~b36N) { var v = (~flOutVal[i] * 100).round.asInteger;
					if (v > 0) { "+" ++ v } { v.asString } } { "off" };
		};
		0.25.wait;
	} }.play(AppClock);
	~flWin.onClose = { ~flCleanup.() };
};
};
)
