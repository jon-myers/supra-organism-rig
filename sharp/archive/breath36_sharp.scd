/*
breath36_sharp.scd -- a "sharpness" knob for the 36 breaths. Open breath36.scd FIRST (this
reuses its buffers, pans, and morph state), then select all + evaluate here. Re-evaluating is safe.

ONE signal, ONE process (v2, after Jon rejected the loop/grain crossfade): each voice's loop
plays exactly as in breath36; sharpness shapes it with a time-varying amplitude window that is
retriggered at the voice's own breath onsets (sharp/onsets.json, detected as loudness swells).
  sharp 0        window is long and shallow: nothing changes (identity).
  0 -> 0.6       the dips between breaths deepen to silence and the window shortens, so each real
                 breath is cut to a shorter and shorter burst of itself, in the performer's timing.
  0.4 -> 1       an nCVI clock (per-voice sequence from sharp/iois.json, Jon's
                 rhythmic_sequence_maker) adds onsets between the natural ones, mean spacing
                 2.5 s -> "mean IOI"; the window falls to "min len" with a 3 ms attack.
  pos rand       0 = the window always cuts the loop where it is; > 0 = at each onset the read
                 position may jump elsewhere in the voice's material (fresh attacks).
  spread         per-voice random offset added to the knob.
  nCVI menu      0 = even clock, higher = more irregular; rewrites the IOI buffers live.
Sensor/LFO input per voice: ~b36SetSharpMod.(i, busIndex, amt), like breath36's ~b36SetMod.
Voice 1 posts its onset count every 2 s while the debug flag is on. Closing the window restores
the plain voices.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
if (~b36Synths.isNil or: { ~b36Bufs.isNil }) { "breath36_sharp: open breath36.scd first".warn } {
var nv = ~b36Bufs.size, ns = ~b36Bufs[0].size, ioiData, onData, grid = 100;
~shWin !? { if (~shWin.isClosed.not) { ~shWin.close } };   // restores the plain voices first
~shP = (sharp: 0, ncviIdx: 4, meanIoi: 0.3, minLen: 0.07, posRand: 0.0, spread: 0.0, glide: 2.0, makeup: 1.5);
if (File.exists(here +/+ "sharp/iois.json").not or: { File.exists(here +/+ "sharp/onsets.json").not }) {
	"breath36_sharp: run sharp/make_sharp_assets.py and sharp/make_onsets.py first".warn } {
ioiData = File.readAllString(here +/+ "sharp/iois.json").parseJSON;
onData = File.readAllString(here +/+ "sharp/onsets.json").parseJSON;
~shLevels = ioiData["ncvi_levels"].collect(_.asFloat);
~shSeqs = ioiData["voices"].collect { |per| per.collect { |seq| seq.collect(_.asFloat) } };
~shOnsets = onData["voices"].collect { |v| v.collect(_.asFloat) };

s.waitForBoot {
	~shIoiBufs = nv.collect { |i| Buffer.loadCollection(s, ~shSeqs[i][~shP.ncviIdx]) };
	// onset grids: 100 Hz, 1.0 for 3 samples at each detected breath onset
	~shOnsetBufs = nv.collect { |i|
		var b = ~b36Bufs[i][0], n = (b.numFrames / b.sampleRate * grid).ceil.asInteger + 3, arr = 0.0 ! n;
		~shOnsets[i].do { |t| var k = (t * grid).round.asInteger; 3.do { |d| if (k + d < n) { arr[k + d] = 1.0 } } };
		Buffer.loadCollection(s, arr);
	};
	~shSharp = 0 ! nv; ~shOffset = 0 ! nv;
	s.sync;

	SynthDef(\b36VoiceSharp, { |on = 0, fade = 3, pan = 0, amp = 0.8, comp = 1, out = 0,
		morph = 0, glide = 0.5, modbus, modamt = 0,
		sharp = 0, sglide = 2, sharpbus, sharpamt = 0, onsetBuf, ioiBuf,
		meanIoi = 0.3, minLen = 0.07, posRand = 0, makeup = 1.5, debug = 0|
		var bufs = \bufs.kr(0 ! ns);
		var m = (VarLag.kr(morph, glide) + (In.kr(modbus) * modamt)).clip(0, 1) * (ns - 1);
		var sh = (VarLag.kr(sharp, sglide) + (In.kr(sharpbus) * sharpamt)).clip(0, 1);
		var g = VarLag.kr(on, fade, warp: \sin);
		var frames = BufFrames.kr(bufs[0]);
		var ph = Phasor.ar(0, BufRateScale.kr(bufs[0]), 0, frames);
		var phk = A2K.kr(ph);
		// natural breath onsets, read off the 100 Hz grid at the loop's position
		var natTrig = Trig1.kr(BufRd.kr(1, onsetBuf, phk / frames * BufFrames.kr(onsetBuf), 1, 1) > 0.5, 0.1);
		// nCVI clock: thinned in from sharp 0.4, spacing 2.5 s -> meanIoi at full
		var clockOn = sh.linlin(0.4, 1, 0, 1);
		var ioiScale = sh.linexp(0.4, 1, 2.5, meanIoi);
		var fb = LocalIn.kr(1);
		var nextIoi = Demand.kr(fb + Impulse.kr(0), 0, Dbufrd(ioiBuf, Dseries(0, 1, inf), 1));
		var elapsed = Sweep.kr(fb, ioiScale.reciprocal);
		var clockTrig = Trig1.kr(elapsed >= nextIoi, ControlDur.ir);
		var clockPass = clockTrig * (TRand.kr(0, 1, clockTrig) < clockOn);
		var trig = (natTrig + clockPass) > 0;
		// the window: attack 0.3 s -> 3 ms, hold+decay 6 s -> minLen; retrigger restarts from the current level
		var wlen = sh.linexp(0, 1, 6.0, minLen);
		var watt = sh.linexp(0, 1, 0.3, 0.003);
		var env = EnvGen.kr(Env([0, 1, 1, 0], [watt, wlen * 0.4, wlen * 0.6], [3, 0, -4]), trig);
		// depth: at 0 the window is ignored (identity); by 0.6 the gaps go all the way to silence
		var depth = sh.linlin(0, 0.6, 0, 1);
		var gain = (env + ((1 - env) * (1 - depth))) * (1 + (sh * (makeup - 1)));
		// optional read-position jump at an onset, only when the window is near silent (no click)
		var jumpTrig = trig * (Delay1.kr(env) < 0.08) * (posRand > 0);
		var off = Latch.kr(TRand.kr(0, frames, jumpTrig) * posRand, jumpTrig);
		var rd = (ph + off).wrap(0, frames);
		var sig = 0;
		LocalOut.kr(trig);
		ns.do { |i|
			var w = (1 - (m - i).abs).clip(0, 1).sqrt;      // equal-power triangle around morph step i
			sig = sig + (BufRd.ar(1, bufs[i], rd, 1, 2) * w);
		};
		Poll.kr(Impulse.kr(0.5) * debug, PulseCount.kr(trig), "voice 1 onsets so far");
		Out.ar(out, Pan2.ar(sig * gain * g * amp.lag(0.1) * comp.lag(1), pan));
	}).add;
	s.sync;

	~shPlain = ~b36Synths;                     // the originals, restored on close
	~shPlain.do(_.set(\fade, 0.5, \on, 0));
	s.bind {
		~b36Synths = nv.collect { |i|
			Synth(\b36VoiceSharp, [\bufs, ~b36Bufs[i].collect(_.bufnum), \on, (i < ~b36N).asInteger,
				\modbus, ~b36Silent.index, \modamt, 0, \sharpbus, ~b36Silent.index, \sharpamt, 0,
				\onsetBuf, ~shOnsetBufs[i].bufnum, \ioiBuf, ~shIoiBufs[i].bufnum,
				\fade, 0, \pan, ~b36Pan[i], \amp, ~b36Amp, \comp, ~b36CompFor.(~b36N),
				\morph, ~b36Morph[i], \glide, ~b36Glide, \sharp, 0, \sglide, ~shP.glide,
				\meanIoi, ~shP.meanIoi, \minLen, ~shP.minLen, \posRand, ~shP.posRand, \makeup, ~shP.makeup,
				\debug, (i == 0).asInteger]);
		};
	};
	~b36SetSharpMod = { |i, busIndex, amt = 1| ~b36Synths[i].set(\sharpbus, busIndex ? ~b36Silent.index, \sharpamt, amt) };
	~shApply = {
		nv.do { |i| ~shSharp[i] = (~shP.sharp + ~shOffset[i]).clip(0, 1);
			~b36Synths[i].set(\sharp, ~shSharp[i], \sglide, ~shP.glide,
				\meanIoi, ~shP.meanIoi, \minLen, ~shP.minLen, \posRand, ~shP.posRand, \makeup, ~shP.makeup) };
	};
	~shSetNcvi = { |idx| ~shP.ncviIdx = idx; nv.do { |i| ~shIoiBufs[i].loadCollection(~shSeqs[i][idx]) } };
	~shSetSpread = { |sp| ~shP.spread = sp; ~shOffset = nv.collect { |i| thisThread.randSeed = 77 + i; sp.rand2 }; ~shApply.() };

	// ---------------- GUI ----------------
	~shWin = Window("breath sharpness", Rect(1160, 60, 540, 340)).front;
	~shText = StaticText().string_("0 %").align_(\center).font_(Font.default.size_(40).boldVariant);
	~shSlider = Slider().orientation_(\horizontal).fixedHeight_(48).step_(0.002).value_(0)
		.action_({ |sl| ~shP.sharp = sl.value; ~shApply.(); ~shText.string = (sl.value * 100).round.asInteger.asString ++ " %" });
	~shNcvi = PopUpMenu().items_(~shLevels.collect { |l| "nCVI " ++ l.round.asInteger.asString })
		.value_(~shP.ncviIdx).action_({ |pm| ~shSetNcvi.(pm.value) });
	~shIoiBox = NumberBox().clipLo_(0.05).clipHi_(2.5).step_(0.05).scroll_step_(0.05).decimals_(2)
		.value_(~shP.meanIoi).fixedWidth_(60).action_({ |nb| ~shP.meanIoi = nb.value; ~shApply.() });
	~shLenBox = NumberBox().clipLo_(0.02).clipHi_(2).step_(0.01).scroll_step_(0.01).decimals_(2)
		.value_(~shP.minLen).fixedWidth_(60).action_({ |nb| ~shP.minLen = nb.value; ~shApply.() });
	~shGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5).decimals_(1)
		.value_(~shP.glide).fixedWidth_(60).action_({ |nb| ~shP.glide = nb.value; ~shApply.() });
	~shGainBox = NumberBox().clipLo_(0.5).clipHi_(4).step_(0.1).scroll_step_(0.1).decimals_(1)
		.value_(~shP.makeup).fixedWidth_(60).action_({ |nb| ~shP.makeup = nb.value; ~shApply.() });
	~shPosSlider = Slider().orientation_(\horizontal).fixedHeight_(22).value_(~shP.posRand)
		.action_({ |sl| ~shP.posRand = sl.value; ~shApply.() });
	~shSpreadSlider = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0)
		.action_({ |sl| ~shSetSpread.(sl.value * 0.5) });
	~shWin.layout = VLayout(
		~shText, ~shSlider,
		HLayout(StaticText().string_("0 = breath36 as is"), nil, StaticText().string_("1 = short, dense, irregular")),
		HLayout(StaticText().string_("clock irregularity"), ~shNcvi, nil,
			StaticText().string_("mean IOI at full (s)"), ~shIoiBox),
		HLayout(StaticText().string_("min window (s)"), ~shLenBox, nil,
			StaticText().string_("knob glide (s)"), ~shGlideBox, nil, StaticText().string_("makeup at full"), ~shGainBox),
		HLayout(StaticText().string_("pos rand  (0 = cut the loop in place, 1 = jump anywhere)").fixedWidth_(300), ~shPosSlider),
		HLayout(StaticText().string_("per-voice spread  (0 .. 0.5)").fixedWidth_(300), ~shSpreadSlider),
		StaticText().string_("breath onsets: own loudness swells; clock joins above 40 %. breath36 sliders still work.").fixedHeight_(18)
	);
	~shWin.onClose = {
		var sharpSynths = ~b36Synths, ioiBufs = ~shIoiBufs, onsetBufs = ~shOnsetBufs;   // capture: re-evaluation rebinds these
		~b36Synths = ~shPlain;
		~b36Synths.do { |sy, i| sy.set(\fade, 1.0, \on, (i < ~b36N).asInteger, \morph, ~b36Morph[i]) };
		{ sharpSynths.do(_.free); ioiBufs.do(_.free); onsetBufs.do(_.free) }.defer(1.5);
	};
	"BREATH36_SHARP_READY (v2: windowed, one signal)".postln;
};
};
};
)
