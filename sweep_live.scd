/*
sweep_live.scd -- sweep live through a LADDER of LatentFT renders of Phantom Pain (one render per
latent-frequency cutoff / band = a "plane"), all sample-aligned.

In-memory, two readers (v3, 2026-09-28). The chosen set is loaded into RAM once (full-track set ~4.5 GB,
load ~30 s; 2-bar sets are instant). ONE synth plays it: a single shared playhead and exactly TWO buffer
readers, A = plane floor(centre), B = plane floor(centre)+1, mixed with an equal-power crossfade by the
fraction between them. Each plane is heard in its own stereo, untouched. When the centre crosses a
whole number the readers swap planes at the instant the plane being swapped out is silent, so there is
nothing to hear and nothing is ever loaded or started during playback.
  centre   0 .. N-1, continuous; at a whole number exactly one plane sounds
  variant  _lr / _mid (reloads the set)          master   output level (limiter after it)
  PLAY/STOP, position slider = seek; the playhead loops at the end of the render.
Sets: every folder under song_deconstruct/sweeps/<set>/<grain>/ that holds planes (plane_NN_*.flac/wav).
ORIGINAL row at the top: plain playback of the unprocessed Phantom Pain (song_deconstruct/in/phantom_pain.wav),
independent of the sweep -- own PLAY/STOP, position (seek), level; plays through the same limiter.
nanoKONTROL2 when ~mkOwner == \sweep: slider 1 centre, knob 5 master, PLAY/STOP, CYCLE variant.
Select all, evaluate. Re-evaluating tears the previous instance down first.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~swRoot = here +/+ ".." +/+ "song_deconstruct" +/+ "sweeps";
~swOutBus = ~swOutBus ? 0;
~swP = (centre: 0, master: 0.5, variant: "_lr");
~swMaxPlanes = 128;
~swOrigPaths = [here +/+ ".." +/+ "song_deconstruct" +/+ "in" +/+ "phantom_pain.wav",
	here +/+ ".." +/+ "concatenator-corpus" +/+ "targets" +/+ "Bill Converse 2 - Phantom Pain.wav"];
~swOrigAmp = 0.8;
s = Server.default;
s.options.numBuffers = s.options.numBuffers.max(4096);
s.waitForBoot {
	var loadSet, sets;
	// ---- tear down a previous evaluation ----
	~swWin !? { if (~swWin.isClosed.not) { ~swWin.onClose = nil; ~swWin.close } };
	~swRout !? { ~swRout.stop }; ~swTick !? { ~swTick.stop };
	~swSynth !? { ~swSynth.free }; ~swSynth = nil; ~swLimiter !? { ~swLimiter.free };
	~swPlanes !? { ~swPlanes.do { |p| p !? { p.tryPerform(\free); p.tryPerform(\at, \buf) !? { |b| b.free } } } };
	~swBufs !? { ~swBufs.do(_.free) }; ~swBufs = [];
	MIDIdef(\swcc).free; MIDIdef(\swnote).free; OSCdef(\swPos).free;
	~swOrigSynth !? { ~swOrigSynth.free }; ~swOrigSynth = nil; ~swOrigBuf !? { ~swOrigBuf.free }; ~swOrigBuf = nil;
	OSCdef(\swOrigPos).free; OSCdef(\swOrigEnd).free;

	SynthDef(\swOrig, { |buf = 0, amp = 0.8, start = 0, gate = 1, out = 0|
		var env = EnvGen.kr(Env.asr(0.01, 1, 0.08), gate, doneAction: 2);
		var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), 1, start, 0, doneAction: 2);
		SendReply.kr(Impulse.kr(4), '/swOrigPos', (start / BufSampleRate.kr(buf)) + Sweep.kr(0, 1));
		SendReply.kr(Done.kr(sig), '/swOrigEnd', 1);
		Out.ar(out, sig * env * amp.lag(0.05));
	}).add;
	SynthDef(\swLadder, { |centre = 0, amp = 0.5, n = 1, frames = 1, rate = 1, t_reset = 0, resetPos = 0, run = 1, out = 0|
		var bufs = \bufs.kr(0 ! ~swMaxPlanes);
		var c = Lag.kr(centre, 0.02).clip(0, n - 1);   // just enough to smooth mouse steps
		var k0 = c.floor, f = c - k0, k1 = (k0 + 1).min(n - 1);
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos);
		var a = BufRd.ar(2, Select.kr(k0, bufs), ph, 1, 4);
		var b = BufRd.ar(2, Select.kr(k1, bufs), ph, 1, 4);
		SendReply.kr(Impulse.kr(4), '/swPos', A2K.kr(ph));
		Out.ar(out, ((a * cos(f * 0.5pi)) + (b * sin(f * 0.5pi))) * amp.lag(0.05));
	}).add;
	SynthDef(\swLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add;
	s.sync;
	~swLimiter = Synth.tail(s, \swLimit, [\out, ~swOutBus]);

	// ---- the original track (plain playback) ----
	~swOrigPath = ~swOrigPaths.detect { |f| File.exists(f) };
	~swOrigBuf = ~swOrigPath !? { |f| Buffer.read(s, f) };
	s.sync;
	~swOrigDur = ~swOrigBuf !? { |b| b.numFrames / b.sampleRate } ? 0;
	~swOrigPos = 0; ~swOrigPlaying = false;
	~swOrigStart = { ~swOrigBuf !? { |b|
		~swOrigSynth !? { ~swOrigSynth.set(\gate, 0) };
		if (~swOrigPos >= (~swOrigDur - 0.5)) { ~swOrigPos = 0 };
		~swOrigSynth = Synth.before(~swLimiter, \swOrig, [\buf, b, \amp, ~swOrigAmp, \start, (~swOrigPos * b.sampleRate).asInteger, \out, ~swOutBus]);
		~swOrigPlaying = true; { ~swOrigBtn.value = 1 }.defer } };
	~swOrigStop = { ~swOrigSynth !? { ~swOrigSynth.set(\gate, 0) }; ~swOrigSynth = nil; ~swOrigPlaying = false; { ~swOrigBtn.value = 0 }.defer };
	OSCdef(\swOrigPos, { |m| if (~swOrigSynth.notNil and: { m[1] == ~swOrigSynth.nodeID }) { ~swOrigPos = m[3] } }, '/swOrigPos');
	OSCdef(\swOrigEnd, { |m| if (~swOrigSynth.notNil and: { m[1] == ~swOrigSynth.nodeID }) { ~swOrigSynth = nil; ~swOrigPos = 0; ~swOrigPlaying = false; { ~swOrigBtn.value = 0 }.defer } }, '/swOrigEnd');

	// sets on disk: <root>/<set>/<grain>/ with planes; plus any older layout folders that hold *.flac/*.wav
	sets = IdentityDictionary.new;
	PathName(~swRoot).folders.do { |setDir| setDir.folders.do { |g|
		// full-track sets only (the 6-s 2bar clips stay on disk, unlisted)
		if (g.folderName.beginsWith("full") and: { (g.fullPath +/+ "plane_*").pathMatch.notEmpty }) { sets[(setDir.folderName ++ "_" ++ g.folderName).asSymbol] = g.fullPath } } };
	~swSets = sets;

	~swPlaying = false; ~swPos = 0; ~swN = 0; ~swSetName = nil;
	~swSend = { |...args| ~swSynth !? { ~swSynth.set(*args) } };
	loadSet = { |name|
		var dir = ~swSets[name], files, variants;
		~swSynth !? { ~swSynth.free; ~swSynth = nil }; ~swPlaying = false;
		~swBufs.do(_.free); ~swBufs = [];
		files = ((dir +/+ "*.flac").pathMatch ++ (dir +/+ "*.wav").pathMatch).sort;
		variants = files.collect { |f| case { f.contains("_mid.") } { "_mid" } { f.contains("_lr.") } { "_lr" } { "" } }.asSet.asArray.sort;
		if (variants.includesEqual(~swP.variant).not) { ~swP.variant = variants.first };
		~swVariants = variants;
		files = files.select { |f| (~swP.variant == "") or: { f.contains(~swP.variant ++ ".") } }.keep(~swMaxPlanes);
		~swFiles = files; ~swN = files.size; ~swSetName = name; ~swDir = dir; ~swPlaneInfo = IdentityDictionary.new;
		// each plane's rate in Hz, from its plane_NN.json "desc" (the first number before " Hz": band/notch centre,
		// lowpass/highpass cutoff). The scale differs per set, so the slider's labels are built from these.
		~swPlaneHz = files.collect { |f| var jp = dir +/+ f.basename.copyRange(0, 7) ++ ".json", m;
			if (File.exists(jp)) { m = File.readAllString(jp).findRegexp("[0-9.]+ Hz"); if (m.notEmpty) { m[0][1].asFloat } } };
		if (~swPlaneHz.any(_.isNil) or: { ~swPlaneHz.differentiate.drop(1).any { |d| d <= 0 } }) { ~swPlaneHz = nil };
		{ ~swCentreSl !? { ~swCentreSl.refresh } }.defer;
		{ ~swSetText.string = name.asString ++ ":  loading " ++ ~swN ++ " planes into memory ..."; ~swPlayBtn.enabled = false }.defer;
		fork {
			var t0 = Main.elapsedTime;
			~swBufs = files.collect { |f| Buffer.read(s, f) };
			s.sync;
			~swFrames = ~swBufs.collect(_.numFrames).minItem; ~swSR = ~swBufs[0].sampleRate; ~swDur = ~swFrames / ~swSR;
			~swSynth = Synth.before(~swLimiter, \swLadder, [\bufs, ~swBufs.collect(_.bufnum) ++ (0 ! (~swMaxPlanes - ~swN)),
				\centre, ~swP.centre.clip(0, ~swN - 1), \amp, ~swP.master, \n, ~swN, \frames, ~swFrames,
				\rate, ~swSR / s.sampleRate, \run, 0, \out, ~swOutBus]);
			{ ~swSetText.string = name.asString ++ ":  " ++ ~swN ++ " planes  " ++ ~swDur.round(0.1) ++ " s  " ++ ~swSR ++ " Hz  variant "
				++ ~swP.variant ++ "   (loaded in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s)";
			  ~swPlayBtn.enabled = true; ~swVarBtn.value = (~swP.variant == "_mid").asInteger; }.defer;
			~swDirty = true;
		};
	};
	~swPlay = { ~swPlaying = true; ~swSend.(\run, 1); { ~swPlayBtn.value = 1 }.defer };
	~swStop = { ~swPlaying = false; ~swSend.(\run, 0); { ~swPlayBtn.value = 0 }.defer };
	~swSeek = { |secs| ~swSend.(\resetPos, (secs.clip(0, ~swDur ? 0) * (~swSR ? 44100)).asInteger, \t_reset, 1) };
	// throttle: at most ~swRateHz sends per control while dragging; the last value always lands (trailing send)
	~swRateHz = 4; ~swLastSend = IdentityDictionary.new; ~swPendingSend = IdentityDictionary.new;
	~swThrottle = { |key, fn| var now = Main.elapsedTime, last = ~swLastSend[key] ? 0, gap = 1 / ~swRateHz;
		if ((now - last) >= gap) { ~swLastSend[key] = now; fn.value } {
			if (~swPendingSend[key].isNil) { ~swPendingSend[key] = true;
				AppClock.sched(gap - (now - last), { ~swPendingSend[key] = nil; ~swLastSend[key] = Main.elapsedTime; fn.value; nil }) };
			~swPendingSend[\fn ++ key] = fn } };
	~swSetCentre = { |c| ~swP.centre = c.clip(0, (~swN - 1).max(0)); ~swSend.(\centre, ~swP.centre); ~swDirty = true };   // SOUND: every mouse move, unthrottled
	OSCdef(\swPos, { |m| ~swPos = m[3] / (~swSR ? 44100) }, '/swPos');

	// ---- GUI ----
	~swWin = if (~stHost.notNil) { ~stHost.(\sweep) } { Window("phantom pain sweep", Rect(700, 520, 760, 340)).front };   // in a tab of show_tabs.scd, or its own window
	// nanoKONTROL2 follows the FRONT window: bringing this window forward makes it the owner
	~swWin.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\sweep).asSet.asArray; ~mkOwner = \sweep;
		{ ~swMidiText !? { ~swMidiText.string = "nanoKONTROL2: this window (front)" } }.defer });
	~swSetMenu = PopUpMenu().items_(~swSets.keys.asArray.sort.collect(_.asString)).action_({ |pm| loadSet.(pm.item.asSymbol) });
	~swVarBtn = Button().states_([["variant: _lr"], ["variant: _mid"]]).fixedWidth_(110)
		.action_({ |b| ~swP.variant = if (b.value == 1) { "_mid" } { "_lr" }; ~swSetName !? { loadSet.(~swSetName) } });
	~swSetText = StaticText().string_("no set loaded").fixedHeight_(18);
	~swCentreText = StaticText().string_("plane 1").align_(\center).font_(Font.default.size_(30).boldVariant);
	// the plane slider is drawn by the patch, not the OS: the mouse sets the value continuously, but the
	// handle is redrawn only ~swDrawHz times a second, in steps (no 60-fps tracking under the cursor)
	~swDrawHz = 4; ~swCentreVal = 0; ~swCentreShown = 0;
	~swCentreSet = { |v| ~swCentreVal = v.clip(0, 1); ~swSetCentre.(~swCentreVal * ((~swN ? 1) - 1).max(0)) };
	// Hz labels along the top: where each round rate falls on this set's planes (log-interpolated between planes)
	~swHzPos = { |hz| var a = ~swPlaneHz, i;
		if (a.isNil or: { hz < a.first } or: { hz > a.last }) { nil } {
			i = a.indexOfGreaterThan(hz) ? (a.size - 1); i = (i - 1).max(0);
			(i + ((hz / a[i]).log / (a[(i + 1).min(a.size - 1)] / a[i]).max(1.0001).log)) / (a.size - 1).max(1) } };
	~swCentreSl = UserView().fixedHeight_(62).background_(Color.grey(0.93))
		.drawFunc_({ |uv| var w = uv.bounds.width, h = uv.bounds.height, x = 8 + (~swCentreShown * (w - 16)), ty = 20;
			[0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 40].do { |hz| ~swHzPos.(hz) !? { |t| var lx = 8 + (t * (w - 16));
				Pen.strokeColor = Color.grey(0.6); Pen.line(lx @ (ty - 4), lx @ (ty + 2)); Pen.stroke;
				(hz.asString ++ (if (hz == 0.1) { " Hz" } { "" })).drawCenteredIn(Rect(lx - 30, 0, 60, 14), Font.default.size_(10), Color.grey(0.3)) } };
			Pen.fillColor = Color.grey(0.75); Pen.fillRect(Rect(8, ty + 16, w - 16, 6));
			Pen.fillColor = Color.grey(0.25); Pen.fillRect(Rect(x - 5, ty + 4, 10, h - ty - 8)) })
		.mouseDownAction_({ |uv, x| ~swCentreSet.((x - 8) / (uv.bounds.width - 16)) })
		.mouseMoveAction_({ |uv, x| ~swCentreSet.((x - 8) / (uv.bounds.width - 16)) });
	~swMasterSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(~swP.master)
		.action_({ |sl| ~swP.master = sl.value; ~swSend.(\amp, ~swP.master) });
	~swPlayBtn = Button().states_([["PLAY"], ["STOP", Color.white, Color.green(0.5)]]).fixedWidth_(80)
		.action_({ |b| if (b.value == 1) { ~swPlay.value } { ~swStop.value } });
	~swPosSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0).action_({ |sl| ~swSeek.(sl.value * (~swDur ? 0)) });
	~swPosText = StaticText().string_("0:00").fixedWidth_(60);
	~swInfo = StaticText().string_("").fixedHeight_(18);
	~swMidiText = StaticText().string_("").fixedHeight_(16);
	~swOrigBtn = Button().states_([["PLAY original"], ["STOP original", Color.white, Color.green(0.5)]]).fixedWidth_(110)
		.enabled_(~swOrigBuf.notNil).action_({ |b| if (b.value == 1) { ~swOrigStart.value } { ~swOrigStop.value } });
	~swOrigPosSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0)
		.action_({ |sl| ~swOrigPos = sl.value * ~swOrigDur; if (~swOrigPlaying) { ~swOrigStart.value } });
	~swOrigPosText = StaticText().string_(if (~swOrigBuf.notNil) { "0:00" } { "no file" }).fixedWidth_(60);
	~swOrigAmpSl = Slider().orientation_(\horizontal).fixedHeight_(22).fixedWidth_(110).value_(~swOrigAmp)
		.action_({ |sl| ~swOrigAmp = sl.value; ~swOrigSynth !? { ~swOrigSynth.set(\amp, ~swOrigAmp) } });
	~swWin.layout = VLayout(
		HLayout(~swOrigBtn, ~swOrigPosSl, ~swOrigPosText, StaticText().string_("level"), ~swOrigAmpSl),
		View().fixedHeight_(1).background_(Color.grey(0.6)),
		HLayout(StaticText().string_("set"), ~swSetMenu, ~swVarBtn, nil), ~swSetText,
		~swCentreText, ~swCentreSl,
		HLayout(StaticText().string_("master").fixedWidth_(60), ~swMasterSl),
		HLayout(~swPlayBtn, ~swPosSl, ~swPosText), ~swInfo, ~swMidiText
	);
	~swDirty = true;
	~swRout = Routine { loop {
		if (~swDirty and: { ~swN > 0 }) { var c = ~swP.centre, k0 = c.floor.asInteger, f = c - k0, jp;
			~swDirty = false;
			~swCentreText.string = (if (f < 0.005) { "plane " ++ (k0 + 1) } { "plane " ++ (k0 + 1) ++ " / " ++ (k0 + 2) ++ "   (" ++ (f * 100).round.asInteger ++ " %)" })
				++ (~swPlaneHz !? { |a| "   " ++ a[c.round.asInteger.clip(0, a.size - 1)].round(if (a[c.round.asInteger.clip(0, a.size - 1)] < 1) { 0.01 } { 0.1 }) ++ " Hz" } ? "");
			jp = ~swDir +/+ ("plane_" ++ (c.round.asInteger + 1).asString.padLeft(2, "0") ++ ".json");
			~swInfo.string = if (File.exists(jp)) { File.readAllString(jp).keep(160) } { "" } };
		if (~swCentreShown != ~swCentreVal) { ~swCentreShown = ~swCentreVal; ~swCentreSl.refresh };
		if (~swDur.notNil) { var p = ~swPos; ~swPosText.string = (p / 60).floor.asInteger.asString ++ ":" ++ (p % 60).floor.asInteger.asString.padLeft(2, "0");
			if (~swPlaying and: { ~swTickN % 4 == 0 }) { ~swPosSl.value = p / ~swDur } };   // position bar steps once a second (motion-safe)
		if (~swOrigBuf.notNil) { var p = ~swOrigPos; ~swOrigPosText.string = (p / 60).floor.asInteger.asString ++ ":" ++ (p % 60).floor.asInteger.asString.padLeft(2, "0");
			if (~swOrigPlaying and: { ~swTickN % 4 == 0 }) { ~swOrigPosSl.value = p / ~swOrigDur.max(1) } };
		~swTickN = (~swTickN ? 0) + 1;
		0.25.wait } }.play(AppClock);
	["lowpass_full2bar", "highpass_full2bar", "highpass_full", "lowpass_full"].do { |want| var i;
		if (~swSetName.isNil) { i = ~swSetMenu.items.detectIndex { |it| it == want }; i !? { ~swSetMenu.valueAction = i } } };

	// ---- nanoKONTROL2 (shared ownership) ----
	~mkOwners = (~mkOwners ? []).add(\sweep).asSet.asArray; ~mkOwner = \sweep;
	~swMidiText.string = "nanoKONTROL2: this patch owns the surface (TRACK < > to pass it)";
	~swLastCC = IdentityDictionary.new; ~swCaught = IdentityDictionary.new;
	~swPick = { |cc, v, cur| var caught = ~swCaught[cc] ? false, last = ~swLastCC[cc];
		if (caught.not) { if (((v - cur).abs < 0.03) or: { last.notNil and: { (last - cur).sign != (v - cur).sign } }) { caught = true } };
		~swLastCC[cc] = v; ~swCaught[cc] = caught; caught };
	MIDIClient.init(verbose: false); MIDIIn.connectAll(verbose: false);   // always rescan: picks up a controller plugged in after SC started
	if (MIDIClient.sources.any { |e| e.device.contains("nanoKONTROL") }.not) { { ~swMidiText.string = "nanoKONTROL2: NOT FOUND -- plug it in and re-evaluate" }.defer(0.5) };
	MIDIdef.cc(\swcc, { |val, cc, chan| var v = val / 127;
		{ if ((cc == 58 or: { cc == 59 }) and: { val > 0 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (cc == 59) { 1 } { -1 }); ~swMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner };
		  if (~mkOwner == \sweep) {
			if (cc == 0) { if (~swPick.(cc, v, ~swCentreVal)) { ~swCentreSet.(v) } };
			if (cc == 20) { if (~swPick.(cc, v, ~swMasterSl.value)) { ~swMasterSl.valueAction = v } };
			if (val > 0) { if (cc == 41) { ~swPlay.value }; if (cc == 42) { ~swStop.value }; if (cc == 46) { ~swVarBtn.valueAction = 1 - ~swVarBtn.value } };
		  } }.defer }).permanent_(true);
	MIDIdef.noteOn(\swnote, { |vel, note| { if (note == 58 or: { note == 59 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (note == 59) { 1 } { -1 }); ~swMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } }.defer }).permanent_(true);
	~swWin.onClose = { ~swRout.stop; ~swOrigSynth !? { ~swOrigSynth.free }; ~swOrigSynth = nil; ~swOrigBuf !? { ~swOrigBuf.free }; ~swOrigBuf = nil; OSCdef(\swOrigPos).free; OSCdef(\swOrigEnd).free; ~swSynth !? { ~swSynth.free }; ~swLimiter !? { ~swLimiter.free; ~swLimiter = nil }; ~swBufs.do(_.free); ~swBufs = [];
		MIDIdef(\swcc).free; MIDIdef(\swnote).free; OSCdef(\swPos).free; ~mkOwners.remove(\sweep); ~mkOwner = ~mkOwners.first };
	"SWEEP_LIVE_READY".postln;
};
)
