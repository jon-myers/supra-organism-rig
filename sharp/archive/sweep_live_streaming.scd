/*
sweep_live.scd -- the Phantom Pain "mass panner": sweep live through a LADDER of full-track
LatentFT renders (one per latent-frequency cutoff / band), all sample-aligned to one transport.

A set = a folder of N planes (wav, 22.05 or 44.1 kHz stereo, all the same length) + optional
manifest.json. Planes are streamed from disk (VDiskIn), so any number of sets fits in RAM.
  centre   where you are on the ladder (0 .. N-1, continuous). The two planes either side of the
           centre play with an EQUAL-POWER crossfade by the fraction between them; at an integer
           value exactly one plane sounds. Each plane is heard in its own stereo, untouched.
  variant  _lr / _mid (the two vocodings of each plane, when a set has both)
  transport play / stop / seek; the position is shared by every plane, so moving the centre
           crossfades between renders while the music keeps walking through the form.
Sets: edit ~swSets (name -> folder). nanoKONTROL2 when ~mkOwner == \sweep: slider 1 centre,
knob 5 master, PLAY/STOP transport, CYCLE lr/mid.
Select all, evaluate.
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~swRoot = here +/+ ".." +/+ "song_deconstruct" +/+ "sweeps";        // pulled-down ladders live here
// ladders from the cluster session (latentft_stereo/ladders/<set>/<grain>/plane_NN_{lr,mid}.wav + plane_NN.json)
~swSets = ~swSets ?? { var d = IdentityDictionary.new;
	["lowpass", "highpass", "band_bin", "band_1oct", "band_2oct", "notch_bin", "notch_1oct", "notch_2oct"].do { |set|
		["full", "2bar"].do { |grain| d[(set ++ "_" ++ grain).asSymbol] = ~swRoot +/+ set +/+ grain } };
	d[\test_pieces] = here +/+ ".." +/+ "song_deconstruct/.claude/worktrees/latentft/out/latentft/pieces"; d };
~swOutBus = ~swOutBus ? 0;
~swP = (centre: 0, master: 0.5, variant: "_lr", maxActive: 4);   // planes are near 0 dBFS and sum hotter than either mid-fade: -6 dB default
s = Server.default;
s.waitForBoot {
	var loadSet;
	// ---- tear down a previous evaluation before anything else ----
	~swWin !? { if (~swWin.isClosed.not) { ~swWin.onClose = nil; ~swWin.close } };
	~swTick !? { ~swTick.stop }; ~swRout !? { ~swRout.stop };
	~swPlanes !? { ~swPlanes.do { |p| p !? { p[\synth] !? { |sy| sy.free }; p[\buf] !? { |b| b.close; b.free } } } };
	MIDIdef(\swcc).free; MIDIdef(\swnote).free;
	~swPlanes = []; ~swPlaying = false;
	SynthDef(\swPlane, { |buf, gain = 0, amp = 1, gate = 1, out = 0|
		var sig = VDiskIn.ar(2, buf, BufRateScale.kr(buf), 1);   // the plane's own stereo, untouched
		var env = EnvGen.kr(Env.asr(0.05, 1, 0.15), gate, doneAction: 2);
		Out.ar(out, sig * Lag.kr(gain, 0.05) * env * amp);
	}).add;
	SynthDef(\swLimit, { |out = 0| ReplaceOut.ar(out, Limiter.ar(In.ar(out, 2), 0.95, 0.01)) }).add;   // safety net on the output
	s.sync;
	~swLimiter !? { ~swLimiter.free }; ~swLimiter = Synth.tail(s, \swLimit, [\out, ~swOutBus]);
	~swPlanes = []; ~swN = 0; ~swSetName = nil;      // per plane index: (buf:, synth:) or nil
	~swPlaying = false; ~swPos0 = 0; ~swT0 = nil;   // transport: position when started, and wall time then
	~swPos = { if (~swPlaying) { ~swPos0 + (Main.elapsedTime - ~swT0) } { ~swPos0 } };

	loadSet = { |name|
		var dir = ~swSets[name], files, variants, sr;
		~swStopAll.value;
		files = ((dir +/+ "*.wav").pathMatch ++ (dir +/+ "*.flac").pathMatch).sort;   // ladders arrive as FLAC (libsndfile reads it)
		variants = files.collect { |f| if (f.contains("_mid")) { "_mid" } { if (f.contains("_lr")) { "_lr" } { "" } } }.asSet.asArray;
		~swVariants = variants; if (variants.includesEqual(~swP.variant).not) { ~swP.variant = variants.first };   // includes() compares Strings by identity
		~swFiles = files.select { |f| (~swP.variant == "") or: { f.contains(~swP.variant) } };
		~swN = ~swFiles.size; ~swSetName = name;
		sr = if (~swN > 0) { SoundFile.use(~swFiles[0], { |sf| ~swDur = sf.numFrames / sf.sampleRate; sf.sampleRate }) } { 44100 };
		~swSR = sr; ~swPlanes = nil ! ~swN;
		~swDir = dir; ~swPlaneInfo = IdentityDictionary.new;   // plane_NN.json read lazily (which bins the plane keeps, Hz)
		~swLoop = ~swDur < 30;                                  // 2-bar sets loop; the full track runs once
		{ ~swSetText.string = name.asString ++ ":  " ++ ~swN ++ " planes  " ++ ~swDur.round(0.1) ++ " s  " ++ sr ++ " Hz  variant " ++ ~swP.variant;
		  ~swCentreSl.step = 1 / (~swN - 1).max(1) / 4 }.defer;
		~swDirty = true;
	};
	// the two planes either side of the centre, equal-power crossfade by the fraction between them
	~swWeights = {
		var c = ~swP.centre.clip(0, (~swN - 1).max(0)), k0 = c.floor.asInteger, f = c - k0, out = IdentityDictionary.new;
		if (~swN > 0) {
			out[k0] = cos(f * 0.5pi);
			if ((f > 0.0005) and: { k0 + 1 < ~swN }) { out[k0 + 1] = sin(f * 0.5pi) };
		};
		out;
	};
	~swLead = 0.12;   // s between cueing a plane and letting it sound: the disk buffer fills first, and it starts aligned
	~swStartPlane = { |k|
		var pos = ~swPos.value + ~swLead + s.latency;            // where the transport will be when the synth starts
		var frame = (pos * ~swSR).asInteger.clip(0, ((~swDur - 0.5) * ~swSR).asInteger);
		var rec = IdentityDictionary[\buf -> nil, \synth -> nil, \pending -> true];
		~swPlanes[k] = rec;
		rec[\buf] = Buffer.cueSoundFile(s, ~swFiles[k], frame, 2, 65536);   // NO completion function: its return value is sent as an OSC message
		SystemClock.sched(~swLead, {                                         // the disk buffer has filled by now (local SSD); start aligned
			if (~swPlanes[k] === rec and: { ~swPlaying }) {
				// start WITH its current weight: the server confirms a new node only after s.latency, so an immediate /n_set would be dropped
				s.makeBundle(s.latency, { rec[\synth] = Synth(\swPlane, [\buf, rec[\buf], \gain, ~swWeights.value[k] ? 0, \amp, ~swP.master, \out, ~swOutBus]).register });
				rec[\pending] = false;
				SystemClock.sched(s.latency + 0.1, { ~swUpdate.value; nil });   // and catch any move made while it was starting
			} { rec[\buf].close; rec[\buf].free };
			nil });
	};
	~swStopPlane = { |k| var p = ~swPlanes[k]; p !? { p[\synth] !? { |sy| if (sy.isRunning) { sy.set(\gate, 0) } }; { p[\buf] !? { |b| b.close; b.free } }.defer(0.5); ~swPlanes[k] = nil } };
	~swStopAll = { ~swPlanes.do { |p, k| p !? { ~swStopPlane.(k) } } };
	~swUpdate = {   // called on every control change while playing
		var w = ~swWeights.value, c = ~swP.centre.clip(0, (~swN - 1).max(0)), k0 = c.floor.asInteger;
		var keep = ((k0 - 1)..(k0 + 2)).select { |k| (k >= 0) and: { k < ~swN } };   // pre-rolled neighbours
		if (~swPlaying) {
			(0..(~swN - 1)).do { |k|
				if (keep.includes(k)) {
					if (~swPlanes[k].isNil) { ~swStartPlane.(k) };
					~swPlanes[k] !? { |p| p[\synth] !? { |sy| if (sy.isRunning) { sy.set(\gain, w[k] ? 0, \amp, ~swP.master) } } };
				} { ~swPlanes[k] !? { ~swStopPlane.(k) } };
			};
		};
		~swDirty = true;
	};
	~swPlay = { |pos| ~swPos0 = pos ? ~swPos.value; ~swT0 = Main.elapsedTime; ~swPlaying = true; ~swUpdate.value; { ~swPlayBtn.value = 1 }.defer };
	~swStop = { ~swPos0 = ~swPos.value; ~swPlaying = false; ~swStopAll.value; ~swDirty = true; { ~swPlayBtn.value = 0 }.defer };
	~swSeek = { |secs| var was = ~swPlaying; if (was) { ~swStop.value }; ~swPos0 = secs.clip(0, ~swDur - 1); if (was) { ~swPlay.(~swPos0) }; ~swDirty = true };
	~swTick = Routine { loop { if (~swPlaying and: { ~swPos.value >= (~swDur - 0.2) }) { if (~swLoop) { ~swStop.value; ~swPlay.(0) } { ~swStop.value } }; 0.25.wait } }.play(SystemClock);

	// ---- GUI ----
	~swWin !? { if (~swWin.isClosed.not) { ~swWin.close } };
	~swWin = Window("phantom pain sweep", Rect(700, 620, 720, 300)).front;
	~swSetMenu = PopUpMenu().items_(~swSets.keys.asArray.select { |k| (~swSets[k] +/+ "*.flac").pathMatch.notEmpty or: { (~swSets[k] +/+ "*.wav").pathMatch.notEmpty } }.sort.collect(_.asString)).action_({ |pm| loadSet.(pm.item.asSymbol) });
	~swVarBtn = Button().states_([["variant: _lr"], ["variant: _mid"]]).fixedWidth_(110)
		.action_({ |b| ~swP.variant = if (b.value == 1) { "_mid" } { "_lr" }; loadSet.(~swSetName) });
	~swSetText = StaticText().string_("no set loaded").fixedHeight_(18);
	~swCentreText = StaticText().string_("centre 0").align_(\center).font_(Font.default.size_(30).boldVariant);
	~swCentreSl = Slider().orientation_(\horizontal).fixedHeight_(44).value_(0)
		.action_({ |sl| ~swP.centre = (sl.value ? 0) * ((~swN ? 1) - 1).max(0); ~swUpdate.value });
	~swMasterSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(~swP.master).action_({ |sl| ~swP.master = sl.value; ~swUpdate.value });
	~swPlayBtn = Button().states_([["PLAY"], ["STOP", Color.white, Color.green(0.5)]]).fixedWidth_(80).action_({ |b| if (b.value == 1) { ~swPlay.value } { ~swStop.value } });
	~swPosSl = Slider().orientation_(\horizontal).fixedHeight_(22).value_(0).action_({ |sl| ~swSeek.(sl.value * (~swDur ? 0)) });
	~swPosText = StaticText().string_("0:00").fixedWidth_(60);
	~swInfo = StaticText().string_("").fixedHeight_(18);
	~swMidiText = StaticText().string_("").fixedHeight_(16);
	~swWin.layout = VLayout(
		HLayout(StaticText().string_("set"), ~swSetMenu, ~swVarBtn, nil), ~swSetText,
		~swCentreText, ~swCentreSl,
		HLayout(StaticText().string_("master").fixedWidth_(150), ~swMasterSl),
		HLayout(~swPlayBtn, ~swPosSl, ~swPosText), ~swInfo, ~swMidiText
	);
	~swDirty = true;
	~swRout = Routine { loop {
		var pos = ~swPos.value;
		if (~swDirty and: { ~swN.notNil }) { ~swDirty = false;
			~swCentreText.string = "centre " ++ ~swP.centre.round(0.01) ++ "   (" ++ ~swPlanes.count(_.notNil) ++ " streaming)";
			~swInfo.string = if (~swN > 0) { var k = ~swP.centre.round.asInteger.clip(0, ~swN - 1), jp = ~swDir +/+ ("plane_" ++ (k + 1).asString.padLeft(2, "0") ++ ".json");
				~swPlaneInfo[k] ?? { ~swPlaneInfo[k] = if (File.exists(jp)) { File.readAllString(jp).parseJSON } { () } };
				"plane " ++ (k + 1) ++ ": " ++ ~swPlaneInfo[k].asString.keep(150) } { "" } };
		if (~swPlaying and: { ~swDur.notNil }) { ~swPosText.string = (pos / 60).floor.asInteger.asString ++ ":" ++ (pos % 60).floor.asInteger.asString.padLeft(2, "0"); ~swPosSl.value = pos / (~swDur ? 1) };
		0.25.wait } }.play(AppClock);
	// start on the first set that exists on disk, preferring highpass_full (indexOf on Strings is identity in SC: use detectIndex)
	["highpass_full", "lowpass_full", "test_pieces"].do { |want| var i;
		if (~swSetName.isNil and: { File.exists(~swSets[want.asSymbol] ? "") }) {
			i = ~swSetMenu.items.detectIndex { |it| it == want }; i !? { ~swSetMenu.valueAction = i } } };

	// ---- nanoKONTROL2 (shared ownership) ----
	~mkOwners = (~mkOwners ? []).add(\sweep).asSet.asArray; ~mkOwner = \sweep;
	~swMidiText.string = "nanoKONTROL2: this patch owns the surface (TRACK < > to pass it)";
	~swLastCC = IdentityDictionary.new; ~swCaught = IdentityDictionary.new;
	~swPick = { |cc, v, cur| var caught = ~swCaught[cc] ? false, last = ~swLastCC[cc];
		if (caught.not) { if (((v - cur).abs < 0.03) or: { last.notNil and: { (last - cur).sign != (v - cur).sign } }) { caught = true } };
		~swLastCC[cc] = v; ~swCaught[cc] = caught; caught };
	if (MIDIClient.initialized.not) { MIDIClient.init(verbose: false) }; MIDIIn.connectAll(verbose: false);
	MIDIdef.cc(\swcc, { |val, cc, chan| var v = val / 127;
		{ if ((cc == 58 or: { cc == 59 }) and: { val > 0 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (cc == 59) { 1 } { -1 }); ~swMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner };
		  if (~mkOwner == \sweep) {
			if (cc == 0) { if (~swPick.(cc, v, ~swCentreSl.value)) { ~swCentreSl.valueAction = v } };
			if (cc == 20) { if (~swPick.(cc, v, ~swMasterSl.value)) { ~swMasterSl.valueAction = v } };
			if (val > 0) { if (cc == 41) { ~swPlay.value }; if (cc == 42) { ~swStop.value }; if (cc == 46) { ~swVarBtn.valueAction = 1 - ~swVarBtn.value } };
		  } }.defer }).permanent_(true);
	MIDIdef.noteOn(\swnote, { |vel, note| { if (note == 58 or: { note == 59 }) { ~mkOwner = ~mkOwners.wrapAt(~mkOwners.indexOf(~mkOwner) + if (note == 59) { 1 } { -1 }); ~swMidiText.string = "nanoKONTROL2 owner: " ++ ~mkOwner } }.defer }).permanent_(true);
	~swWin.onClose = { ~swTick.stop; ~swRout.stop; ~swStopAll.value; ~swLimiter !? { ~swLimiter.free; ~swLimiter = nil }; MIDIdef(\swcc).free; MIDIdef(\swnote).free; ~mkOwners.remove(\sweep); ~mkOwner = ~mkOwners.first };
	"SWEEP_LIVE_READY".postln;
};
)
