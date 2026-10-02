/*
sweep_sync.scd (rig/dev/, 2026-09-29) -- sweep_live.scd with the ORIGINAL LOCKED TO THE SWEEP. DEV COPY: sweep_live.scd
is the stable one and is unchanged.
  ORIGINAL row: [x] original on / off, output menu, level (dB), offset / lead (ms). It has no transport of its own:
  it plays, stops and seeks with the sweep (PLAY/STOP, position slider, nanoKONTROL2).
    main output   sample-locked: the ladder synth writes its playhead to an audio bus; a second synth reads the
                  original at that same position (+ offset ms; default 0 = sample 0 of the planes = sample 0 of
                  phantom_pain.wav). Before the same limiter.
    headphones    on the METRONOME's server (~msServer, its Multi-Output/headphone device): phantom_pain.wav is
                  loaded there too; play / stop / seek go to both servers as bundles with the same timestamp;
                  the headphone player reports its position 4x/s and is re-seeked if it is > 30 ms off the sweep twice in a row
                  (+ lead). "lead ms" plays the headphone copy that much AHEAD, to meet late Bluetooth headphones.
                  If the metronome server is not running the option says so and stays silent.
    both          both of the above.
  Readout: bar.beat at Phantom Pain's ~110.36 BPM, first downbeat 0.134 s (4/4).
New names: ~ss..., SynthDefs \ssLadder (= \swLadder + playhead out) \ssOrigLocked (main) \ssHpOrig (metro server), OSCdef \ssHpPos.

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
~swRoot = ~swRootOverride ? (here +/+ ".." +/+ ".." +/+ "song_deconstruct" +/+ "sweeps");   // (dev/: two levels up)
~swOutBus = ~swOutBus ? 0;
~swP = (centre: 0, master: 0.5, variant: "_lr");
// MASTER (2026-10-01, Jon: "master didn't seem to affect anything"): now a dB trim on EVERYTHING this tab sends to the
// speakers -- the ladder AND the locked original (its own "level" is a trim under it). 0 dB = the levels as before
// (ladder 0.5); -40..+12 dB, all the way down = off. The original's in-ear (headphone) copy is not affected.
~swP[\trim] = ~swP[\trim] ? 1; ~swP.master = 0.5 * ~swP[\trim];
~swMaxPlanes = 128;
~swOrigPaths = [here +/+ ".." +/+ ".." +/+ "song_deconstruct" +/+ "in" +/+ "phantom_pain.wav",
	here +/+ ".." +/+ ".." +/+ "concatenator-corpus" +/+ "targets" +/+ "Bill Converse 2 - Phantom Pain.wav"];
~ssP = ~ssP ? (on: false, dest: 0, amp: 0.8, offset: 0, lead: 0);   // dest 0 main, 1 headphones, 2 both; offset / lead in s
~ssBpm = 110.3575; ~ssDownbeat = 0.1343;
// CENTRAL -> CENTRE (2026-10-01, Jon): the 7th force signal moves the plane around the fader:  centre = fader +
// 0.5 * knob * c * (planes - 1), clipped. c = ensemble activity (|AC| of central, ~5 s) / slow level / central DC / AC,
// DELAYED by "delay s" (the ladder follows the dancers that many seconds late), then smoothed. Needs the FORCE tab (~fhBus).
~ssF = ~ssF ? (on: false, knob: 1, signal: 0, smooth: 1, delay: 0);
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
	~ssFRout !? { ~ssFRout.stop }; ~ssFSyn !? { ~ssFSyn.free }; ~ssFSyn = nil; ~ssFBus !? { ~ssFBus.free }; ~ssFBus = nil;
	~ssOrigSynth !? { ~ssOrigSynth.free }; ~ssOrigSynth = nil; ~swOrigBuf !? { ~swOrigBuf.free }; ~swOrigBuf = nil;
	~ssHpSynth !? { ~ssHpSynth.free }; ~ssHpSynth = nil; ~ssHpBuf !? { ~ssHpBuf.free }; ~ssHpBuf = nil; ~ssHpServer = nil;
	~ssPhBus !? { ~ssPhBus.free }; OSCdef(\ssHpPos).free;

	// the original, sample-locked to the ladder's playhead (read from phBus); pos in ORIGINAL frames = ph * ratio + offset
	SynthDef(\ssOrigLocked, { |buf = 0, phBus = 0, ratio = 1, offset = 0, amp = 0.8, on = 0, out = 0|
		var pos = (In.ar(phBus) * ratio) + offset;
		var sig = BufRd.ar(2, buf, pos.clip(0, BufFrames.kr(buf) - 1), 0, 4) * (pos >= 0) * (pos < BufFrames.kr(buf));
		Out.ar(out, sig * amp.lag(0.05) * Lag.kr(on, 0.05));
	}).add;
	// the headphone copy on the metro server: its own playhead, driven by bundles; reports its position 4x/s
	~ssHpDef = SynthDef(\ssHpOrig, { |buf = 0, run = 0, t_reset = 0, resetPos = 0, end = 1, amp = 0.8, on = 0, out = 0|
		var ph = Phasor.ar(t_reset, BufRateScale.kr(buf) * run, 0, end, resetPos);
		var sig = BufRd.ar(2, buf, ph.min(BufFrames.kr(buf) - 1), 0, 4) * (ph < BufFrames.kr(buf));
		SendReply.kr(Impulse.kr(4), '/ssHpPos', [A2K.kr(ph) / BufSampleRate.kr(buf), run]);
		Out.ar(out, sig * amp.lag(0.05) * Lag.kr(on, 0.05));
	});
	SynthDef(\ssLadder, { |centre = 0, amp = 0.5, n = 1, frames = 1, rate = 1, t_reset = 0, resetPos = 0, run = 1, out = 0, phBus = 0|
		var bufs = \bufs.kr(0 ! ~swMaxPlanes);
		var c = Lag.kr(centre, 0.02).clip(0, n - 1);   // just enough to smooth mouse steps
		var k0 = c.floor, f = c - k0, k1 = (k0 + 1).min(n - 1);
		var ph = Phasor.ar(t_reset, rate * run, 0, frames, resetPos);
		var a = BufRd.ar(2, Select.kr(k0, bufs), ph, 1, 4);
		var b = BufRd.ar(2, Select.kr(k1, bufs), ph, 1, 4);
		SendReply.kr(Impulse.kr(4), '/swPos', A2K.kr(ph));
		Out.ar(phBus, ph * (phBus > 0));   // the playhead, for \ssOrigLocked; nothing unless a private bus is given
		Out.ar(out, ((a * cos(f * 0.5pi)) + (b * sin(f * 0.5pi))) * amp.lag(0.05));
	}).add;
	SynthDef(\ssCentral, { |in, out, csig = 0, csmooth = 1|
		var dc = In.kr(in + 6), ac = In.kr(in + 13), c = exp(-1 / (5 * ControlRate.ir));
		var x = Select.kr(csig, [(OnePole.kr(ac.abs, c) * 3).clip(0, 1), OnePole.kr(dc, c), dc, ac]);
		Out.kr(out, Lag.kr(x.clip(-1, 1), csmooth));   // the DELAY is applied language-side (~ssFDelayed): DelayN.kr warm-up misbehaved
	}).add;
	SynthDef(\swLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add;
	s.sync;
	~swLimiter = Synth.tail(s, \swLimit, [\out, ~swOutBus]);
	~ssPhBus = Bus.audio(s, 1);

	// ---- the original track, locked to the sweep ----
	~swOrigPath = ~swOrigPaths.detect { |f| File.exists(f) };
	~swOrigBuf = ~swOrigPath !? { |f| Buffer.read(s, f) };
	s.sync;
	~ssDestMain = { (~ssP[\dest] == 0) or: { ~ssP[\dest] == 2 } };
	~ssDestHp = { (~ssP[\dest] == 1) or: { ~ssP[\dest] == 2 } };
	// (re)made right AFTER the ladder synth every time a set loads: it must run after the ladder writes the playhead
	~ssMakeLocked = { ~ssOrigSynth !? { ~ssOrigSynth.free }; ~ssOrigSynth = nil;
		if (~swOrigBuf.notNil and: { ~swSynth.notNil }) {
			~ssOrigSynth = Synth.after(~swSynth, \ssOrigLocked, [\buf, ~swOrigBuf, \phBus, ~ssPhBus.index,
				\ratio, ~swOrigBuf.sampleRate / (~swSR ? 44100), \offset, ~ssP[\offset] * ~swOrigBuf.sampleRate,
				\amp, ~ssP[\amp] * ~swP[\trim], \on, (~ssP[\on] and: { ~ssDestMain.() }).asInteger, \out, ~swOutBus]) } };
	// headphone copy on the metronome's server
	~ssHpState = "off"; ~ssHpPos = 0; ~ssHpT = nil; ~ssResyncs = 0; ~ssLat = 0.08;
	~ssHpAvailable = { ~msServer.notNil and: { ~msServer.serverRunning } };
	~ssHpSetup = { var sv = ~msServer;   // load the original + a player on the metro server (again after a metro reboot)
		if (~ssHpAvailable.().not) { ~ssHpState = "metronome server not running -- headphones unavailable" } {
			if ((~ssHpServer !== sv) or: { ~ssHpSynth.isNil } or: { ~ssHpBoots != sv.tryPerform(\pid) }) {
				~ssHpServer = sv; ~ssHpBoots = sv.tryPerform(\pid); ~ssHpState = "loading the original on the metronome server ...";
				fork {
					~ssHpDef.send(sv);
					~ssHpBuf = Buffer.read(sv, ~swOrigPath); sv.sync;
					~ssHpSynth = Synth(\ssHpOrig, [\buf, ~ssHpBuf, \end, ((~swDur ? 400) + 10) * ~ssHpBuf.sampleRate,
						\amp, ~ssP[\amp], \on, (~ssP[\on] and: { ~ssDestHp.() }).asInteger, \run, 0], sv, \addToTail);
					sv.sync; ~ssHpState = "headphones ready"; ~ssHpSync.(true) } } } };
	// where the sweep is NOW (extrapolated from its last 4 Hz report)
	~ssSweepNow = { (~swPos ? 0) + (if (~swPlaying) { Main.elapsedTime - (~swPosT ? Main.elapsedTime) } { 0 }) };
	// put the headphone player where the sweep will be `lat` from now (+ lead), with the sweep's run state
	~ssHpSync = { |force = false| var sv = ~ssHpServer;
		if (~ssDestHp.() and: { ~ssHpSynth.notNil } and: { sv.notNil } and: { sv.serverRunning } and: { ~ssHpBuf.notNil }) {   // RME only unless headphones chosen
			sv.makeBundle(~ssLat, { ~ssHpSynth.set(\resetPos, ((~ssSweepNow.() + ~ssLat + ~ssP[\lead]).max(0) * ~ssHpBuf.sampleRate).asInteger,
				\t_reset, 1, \run, ~swPlaying.asInteger) }) } };
	OSCdef(\ssHpPos, { |m| if (~ssHpSynth.notNil and: { m[1] == ~ssHpSynth.nodeID }) { ~ssHpPos = m[3]; ~ssHpRun = m[4]; ~ssHpT = Main.elapsedTime } }, '/ssHpPos');
	// resync check (called 4x/s): > 30 ms off -> re-seek
	~ssHpCheck = { var want, have;
		if (~ssP[\on] and: { ~ssDestHp.() } and: { ~ssHpSynth.notNil } and: { ~ssHpT.notNil } and: { ~swPlaying } and: { ~ssHpRun == 1 }) {
			want = ~ssSweepNow.() + ~ssP[\lead];
			have = ~ssHpPos + (Main.elapsedTime - ~ssHpT);
			~ssHpErr = have - want;
			// two checks in a row (0.25 s apart) must be off: a single report can be ~20 ms late by itself
			~ssBad = if (~ssHpErr.abs > 0.03) { (~ssBad ? 0) + 1 } { 0 };
			if (~ssBad >= 2) { ~ssBad = 0; ~ssResyncs = ~ssResyncs + 1; ~ssHpSync.() } } };
	~ssApply = { ~ssOrigSynth !? { ~ssOrigSynth.set(\on, (~ssP[\on] and: { ~ssDestMain.() }).asInteger, \amp, ~ssP[\amp] * ~swP[\trim],
			\offset, ~ssP[\offset] * ~swOrigBuf.sampleRate) };
		if (~ssP[\on] and: { ~ssDestHp.() }) { ~ssHpSetup.() };
		~ssHpSynth !? { if (~ssHpServer.notNil and: { ~ssHpServer.serverRunning }) {
			~ssHpSynth.set(\on, (~ssP[\on] and: { ~ssDestHp.() }).asInteger, \amp, ~ssP[\amp]); ~ssHpSync.() } } };

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
			~swSynth = Synth.before(~swLimiter, \ssLadder, [\bufs, ~swBufs.collect(_.bufnum) ++ (0 ! (~swMaxPlanes - ~swN)),
				\centre, ~swP.centre.clip(0, ~swN - 1), \amp, ~swP.master, \n, ~swN, \frames, ~swFrames,
				\rate, ~swSR / s.sampleRate, \run, 0, \out, ~swOutBus, \phBus, ~ssPhBus.index]);
			~ssMakeLocked.(); ~swPlaying = false; ~ssHpSync.();
			{ ~swSetText.string = name.asString ++ ":  " ++ ~swN ++ " planes  " ++ ~swDur.round(0.1) ++ " s  " ++ ~swSR ++ " Hz  variant "
				++ ~swP.variant ++ "   (loaded in " ++ (Main.elapsedTime - t0).round(0.1) ++ " s)";
			  ~swPlayBtn.enabled = true; ~swVarBtn.value = (~swP.variant == "_mid").asInteger; }.defer;
			~swDirty = true;
		};
	};
	// transport: the ladder (and with it the locked original) and the headphone copy get bundles with the SAME timestamp
	// The sweep plays on the MAIN server (the RME) only (2026-10-01, Jon). The metronome server is touched ONLY when the
	// original's destination includes headphones, and never in a way that can stop PLAY / STOP / seek on the RME.
	~ssBoth = { |ladderArgs, hpPos| var sv = ~ssHpServer;
		s.makeBundle(~ssLat, { ~swSynth !? { ~swSynth.set(*ladderArgs) } });
		if (~ssDestHp.() and: { ~ssHpSynth.notNil } and: { sv.notNil } and: { sv.serverRunning } and: { ~ssHpBuf.notNil }) {
			try { sv.makeBundle(~ssLat, { ~ssHpSynth.set(\resetPos, ((hpPos + ~ssP[\lead]).max(0) * ~ssHpBuf.sampleRate).asInteger, \t_reset, 1,
				\run, ~swPlaying.asInteger) }) } { |e| ("sweep: headphone copy not updated (" ++ e.errorString ++ ")").warn } } };
	~swPlay = { ~swPlaying = true; ~swPosT = Main.elapsedTime + ~ssLat; ~ssBoth.([\run, 1], ~swPos ? 0); ~uiLater.(\swPlayBtn, { ~swPlayBtn.value = 1 }) };
	~swStop = { var p = ~ssSweepNow.(); ~swPlaying = false; ~ssBoth.([\run, 0], p); ~uiLater.(\swPlayBtn, { ~swPlayBtn.value = 0 }) };
	~swSeek = { |secs| var x = secs.clip(0, ~swDur ? 0); ~swPos = x; ~swPosT = Main.elapsedTime + ~ssLat;
		~ssBoth.([\resetPos, (x * (~swSR ? 44100)).asInteger, \t_reset, 1], x) };
	// throttle: at most ~swRateHz sends per control while dragging; the last value always lands (trailing send)
	~swRateHz = 4; ~swLastSend = IdentityDictionary.new; ~swPendingSend = IdentityDictionary.new;
	~swThrottle = { |key, fn| var now = Main.elapsedTime, last = ~swLastSend[key] ? 0, gap = 1 / ~swRateHz;
		if ((now - last) >= gap) { ~swLastSend[key] = now; fn.value } {
			if (~swPendingSend[key].isNil) { ~swPendingSend[key] = true;
				AppClock.sched(gap - (now - last), { ~swPendingSend[key] = nil; ~swLastSend[key] = Main.elapsedTime; fn.value; nil }) };
			~swPendingSend[\fn ++ key] = fn } };
	~swSetCentre = { |c| ~swP.centre = c.clip(0, (~swN - 1).max(0));
		~swSend.(\centre, if (~ssF[\on]) { (~swP.centre + (~ssFOff ? 0)).clip(0, (~swN - 1).max(0)) } { ~swP.centre }); ~swDirty = true };
	// ---- CENTRAL -> centre: own central synth (started when the FORCE tab's buses exist), 20 x a second ----
	~ssFBus = Bus.control(s, 1);
	// delay: a short history of the central signal; the value from `delay` seconds ago (older than the history -> its oldest)
	~ssFHist = List.new;
	~ssFDelayed = { |c| var now = Main.elapsedTime, d = ~ssF[\delay], old;
		~ssFHist.add([now, c]); while { ~ssFHist.size > 2 and: { ~ssFHist[1][0] < (now - d - 0.5) } } { ~ssFHist.removeAt(0) };
		if (d <= 0) { c } { old = ~ssFHist.detect { |e| e[0] >= (now - d) }; (old ? ~ssFHist.last)[1] } };
	~ssFStart = { ~ssFSyn !? { ~ssFSyn.free }; ~ssFSyn = nil;
		if (~fhBus.notNil) { ~ssFSyn = Synth(\ssCentral, [\in, ~fhBus.index, \out, ~ssFBus.index, \csig, ~ssF[\signal],
			\csmooth, ~ssF[\smooth]], s, \addToHead) } };
	~ssFSetOn = { |on| ~ssF[\on] = on;
		if (on and: { ~ssFSyn.isNil }) { ~ssFStart.(); if (~ssFSyn.isNil) { "sweep: CENTRAL needs the FORCE tab (~fhBus)".warn; ~ssF[\on] = false } };
		if (~ssF[\on].not) { ~ssFOff = 0; ~swSend.(\centre, ~swP.centre) } };
	~ssFRout = Routine { loop {
		if (~ssF[\on] and: { ~ssFSyn.notNil } and: { ~swN > 1 }) {
			// read straight from shared memory (local server): async Bus.get at 20 Hz delivered stale values (2026-10-01 test)
			var c = ~ssFDelayed.(~ssFBus.getSynchronous);
			~ssFVal = c; ~ssFOff = 0.5 * ~ssF[\knob] * c * (~swN - 1);
			~ssFEff = (~swP.centre + ~ssFOff).clip(0, ~swN - 1); ~swSend.(\centre, ~ssFEff) };
		0.05.wait } }.play(SystemClock);   // SOUND: every mouse move, unthrottled
	OSCdef(\swPos, { |m| ~swPos = m[3] / (~swSR ? 44100); ~swPosT = Main.elapsedTime }, '/swPos');

	// ---- GUI ----
	// ---- display rate limit (Jon: nothing on screen may change faster than 4 times a second -- vestibular
	// migraine). Sound changes at once; a control moved by the nanoKONTROL2 (or by another control) is
	// redrawn by ONE shared routine every 0.25 s: ~uiLater.(key, { widget.value = x }) -- the last one wins.
	~uiPending = ~uiPending ? IdentityDictionary.new;
	~uiLater = { |key, fn| ~uiPending[key] = fn };
	if (~uiRout.isNil or: { ~uiRout.isPlaying.not }) {
		~uiRout = Routine { loop { var p = ~uiPending; ~uiPending = IdentityDictionary.new;
			p.do { |fn| try { fn.value } }; 0.25.wait } }.play(AppClock) };
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
	~swMasterSpec = ControlSpec(-40, 12);
	~swMasterSl = Slider().orientation_(\horizontal).fixedHeight_(22)
		.value_(if (~swP[\trim] <= 0.0001) { 0 } { ~swMasterSpec.unmap(~swP[\trim].ampdb) })
		.action_({ |sl| ~swP[\trim] = if (sl.value <= 0.001) { 0 } { ~swMasterSpec.map(sl.value).dbamp }; ~swP.master = 0.5 * ~swP[\trim];
			~swSend.(\amp, ~swP.master); ~ssApply.();
			~uiLater.(\swMasterDb, { ~swMasterDb.string = if (~swP[\trim] <= 0.0001) { "off" } { ~swP[\trim].ampdb.round(0.5).asString ++ " dB" } }) });
	~swMasterDb = StaticText().string_(if (~swP[\trim] <= 0.0001) { "off" } { ~swP[\trim].ampdb.round(0.5).asString ++ " dB" }).fixedWidth_(60);
	~swPlayBtn = Button().states_([["PLAY"], ["STOP", Color.white, Color.green(0.5)]]).fixedWidth_(80)
		.action_({ |b| if (b.value == 1) { ~swPlay.value } { ~swStop.value } });
	~swPosSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0).action_({ |sl| ~swSeek.(sl.value * (~swDur ? 0)) });
	~swPosText = StaticText().string_("0:00").fixedWidth_(60);
	~swInfo = StaticText().string_("").fixedHeight_(18);
	~swMidiText = StaticText().string_("").fixedHeight_(16);
	~ssOnBox = CheckBox().string_("original").value_(~ssP[\on]).enabled_(~swOrigBuf.notNil).action_({ |c| ~ssP[\on] = c.value; ~ssApply.() });
	~ssDestMenu = PopUpMenu().items_(["-> main output (locked)", "-> headphones (metronome server)", "-> both"]).value_(~ssP[\dest]).fixedWidth_(240)
		.action_({ |m| ~ssP[\dest] = m.value; ~ssApply.() });
	~ssAmpSl = Slider().orientation_(\horizontal).fixedHeight_(22).fixedWidth_(130).value_(if (~ssP[\amp] <= 0.001) { 0 } { ControlSpec(-60, 6).unmap(~ssP[\amp].ampdb) })
		.action_({ |sl| ~ssP[\amp] = if (sl.value <= 0.001) { 0 } { ControlSpec(-60, 6).map(sl.value).dbamp }; ~ssApply.();
			~uiLater.(\ssDb, { ~ssDbText.string = if (~ssP[\amp] <= 0.001) { "off" } { ~ssP[\amp].ampdb.round(0.5).asString ++ " dB" } }) });
	~ssDbText = StaticText().string_(if (~ssP[\amp] <= 0.001) { "off" } { ~ssP[\amp].ampdb.round(0.5).asString ++ " dB" }).fixedWidth_(60);
	~ssOffBox = NumberBox().clipLo_(-500).clipHi_(500).step_(1).scroll_step_(1).decimals_(0).value_(~ssP[\offset] * 1000).fixedWidth_(50)
		.action_({ |b| ~ssP[\offset] = b.value / 1000; ~ssApply.() });
	~ssLeadBox = NumberBox().clipLo_(0).clipHi_(500).step_(5).scroll_step_(5).decimals_(0).value_(~ssP[\lead] * 1000).fixedWidth_(50)
		.action_({ |b| ~ssP[\lead] = b.value / 1000; ~ssApply.() });
	~ssStatus = StaticText().string_(if (~swOrigBuf.notNil) { "" } { "no phantom_pain.wav found" }).fixedHeight_(16).font_(Font.default.size_(11));
	~swWin.layout = VLayout(
		HLayout(~ssOnBox, ~ssDestMenu, StaticText().string_("level"), ~ssAmpSl, ~ssDbText,
			StaticText().string_("offset ms"), ~ssOffBox, StaticText().string_("headphone lead ms"), ~ssLeadBox, nil),
		~ssStatus,
		View().fixedHeight_(1).background_(Color.grey(0.6)),
		HLayout(StaticText().string_("set"), ~swSetMenu, ~swVarBtn, nil), ~swSetText,
		~swCentreText, ~swCentreSl,
		HLayout(~ssFBox = CheckBox().string_("CENTRAL -> centre").value_(~ssF[\on]).action_({ |c| ~ssFSetOn.(c.value); c.value = ~ssF[\on] }),
			Knob().fixedSize_(Size(30, 30)).value_(~ssF[\knob]).action_({ |k| ~ssF[\knob] = k.value }),
			PopUpMenu().items_(["ensemble activity (5 s)", "ensemble slow level", "central DC", "central AC"]).value_(~ssF[\signal]).fixedWidth_(170)
				.action_({ |m| ~ssF[\signal] = m.value; ~ssFSyn !? { ~ssFSyn.set(\csig, m.value) } }),
			StaticText().string_("delay s"), NumberBox().clipLo_(0).clipHi_(60).decimals_(1).step_(0.5).scroll_step_(0.5).value_(~ssF[\delay]).fixedWidth_(46)
				.action_({ |b| ~ssF[\delay] = b.value }),
			StaticText().string_("smooth s"), NumberBox().clipLo_(0).clipHi_(10).decimals_(1).step_(0.1).scroll_step_(0.1).value_(~ssF[\smooth]).fixedWidth_(46)
				.action_({ |b| ~ssF[\smooth] = b.value; ~ssFSyn !? { ~ssFSyn.set(\csmooth, b.value) } }),
			~ssFText = StaticText().string_("").fixedWidth_(240), nil),
		HLayout(StaticText().string_("master").fixedWidth_(60), ~swMasterSl, ~swMasterDb),
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
		~ssHpCheck.();
		if (~swOrigBuf.notNil) { var b = ((~ssSweepNow.() - ~ssDownbeat) * ~ssBpm / 60), hp = ~ssDestHp.();
			~ssStatus.string = "Phantom Pain ~110.36 BPM   bar " ++ ((b.max(0) div: 4) + 1) ++ "." ++ ((b.max(0).floor % 4) + 1).asInteger
				++ "   |   original " ++ (if (~ssP[\on]) { ["main output, sample-locked", "headphones", "main + headphones"][~ssP[\dest]] } { "off" })
				++ (if (hp and: { ~ssP[\on] }) { "   |   headphones: " ++ (if (~ssHpAvailable.()) { ~ssHpState
					++ (~ssHpErr !? { |e| ", off by " ++ (e * 1000).round.asInteger ++ " ms" } ? "") ++ ", resyncs " ++ ~ssResyncs } { "metronome server not running" }) } { "" }) };
		~swTickN = (~swTickN ? 0) + 1;
		~ssFText !? { ~ssFText.string = if (~ssF[\on] and: { ~ssFEff.notNil }) {
			"signal " ++ ((~ssFVal ? 0) * 100).round.asInteger ++ "%  ->  plane " ++ (~ssFEff + 1).round(0.1) ++ "  (fader " ++ (~swP.centre + 1).round(0.1) ++ ")" }
			{ "centre = the fader alone" } };
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
			if (cc == 20) { if (~swPick.(cc, v, ~swMasterSl.value)) { ~swMasterSl.action.value(Ref(v)); ~uiLater.(~swMasterSl, { ~swMasterSl.value = v }) } };
			if (val > 0) { if (cc == 41) { ~swPlay.value }; if (cc == 42) { ~swStop.value }; if (cc == 46) { ~swVarBtn.valueAction = 1 - ~swVarBtn.value } };
		  } }.defer }).permanent_(true);
	MIDIdef.noteOn(\swnote, { |vel, note| { if (note == 58 or: { note == 59 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (note == 59) { 1 } { -1 }); ~swMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } }.defer }).permanent_(true);
	~swWin.onClose = { ~swRout.stop; ~ssFRout.stop; ~ssFSyn !? { ~ssFSyn.free }; ~ssFSyn = nil; ~ssFBus !? { ~ssFBus.free }; ~ssFBus = nil; ~ssOrigSynth !? { ~ssOrigSynth.free }; ~ssOrigSynth = nil; ~swOrigBuf !? { ~swOrigBuf.free }; ~swOrigBuf = nil;
		~ssHpSynth !? { if (~ssHpServer.notNil and: { ~ssHpServer.serverRunning }) { ~ssHpSynth.free; ~ssHpBuf !? { ~ssHpBuf.free } } }; ~ssHpSynth = nil; ~ssHpBuf = nil;
		~ssPhBus !? { ~ssPhBus.free }; ~ssPhBus = nil; OSCdef(\ssHpPos).free; ~swSynth !? { ~swSynth.free }; ~swLimiter !? { ~swLimiter.free; ~swLimiter = nil }; ~swBufs.do(_.free); ~swBufs = [];
		MIDIdef(\swcc).free; MIDIdef(\swnote).free; OSCdef(\swPos).free; ~mkOwners.remove(\sweep); ~mkOwner = ~mkOwners.first };
	~ssApply.();
	"SWEEP_SYNC_READY".postln;
};
)
