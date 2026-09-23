/*
Supra-Organism rehearsal rig: FlowEdit morph + Concatenator + set panes
--------------------------------------------------------------------------
One window, six tabs, shared 4-lane capture strip:

  CAPTURE  record up to 4 input channels at once (armed lanes), or load files.
           Also long-form "corpus rec" straight to disk for the concatenator.
  TAB 1    FlowEdit: per-lane src/tar presets -> GENERATE (server pool,
           parallel across servers) -> per-lane swipeable morph players.
  TAB 2    Concatenator: per-lane live_shim.py processes (concatenator-corpus
           repo), live OSC knobs, direct-to-hardware output (no Loopback).
  TAB 4-6  Set panes, one lane each: WALL OF SOUND (lane 1 = bell_12min render
           streamed from disk, lane 2 = live dyad firing), METRONOMES (lane 3 =
           Callender files / live fader click / glide-to-target), LATENTFT
           (lane 4 = sample-locked A/B with equal-power crossfade, section cues).

nanoKONTROL2 (factory CC map): sliders 1-4 = lane main gesture (morph pos /
chase speed), sliders 5-8 = lane levels, knobs 1-4 = pan, knobs 5-8 = wet
(concat tab), M buttons = mute, S = solo, track < > = tab switch.

Motion-safe by design: all readouts are stepped (1-2 Hz), no animation, no
drag-selection. (Vestibular-migraine rules from flowedit_morph.scd apply.)

Prereqs: tunnel with 7888 + 7893 forwarded; concatenator-corpus repo + venv.
Select all, evaluate. See STUDIO-RIG.md for the runbook.
*/

(
// ------------------------- config -------------------------
~srDevice     = nil;    // ServerOptions.devices to list; nil = default
~srInDevice   = nil;   // studio: e.g. "Waves SoundGrid"
~srOutDevice  = nil;   // nil = system default; studio: e.g. "Waves SoundGrid"
                       // (DacMagic name has a trailing space when connected!)
~srSampleRate = nil;    // nil = device defaults. If boot fails with "sample
                        // rates do not match", set the two devices to the same
                        // rate in Audio MIDI Setup (or pin e.g. 44100 here)
~srNumInputs  = 2;      // SoundGrid: 32; dLive: as patched
~srNumOutputs = 2;
~srOutBus     = 0;

// Input metering. Segmented (LED-style), NOT a sliding bar: a block is lit
// or it isn't, and the row is only repainted when the lit count actually
// changes, so there is no continuous motion. 4 Hz is the deliberate ceiling
// -- fast enough to read a performance, slow enough to stay legible rather
// than shimmering. Peak hold catches what falls between updates.
// Hard-capped at 4 Hz below, whatever is set here.
~srMeterHz    = 4;
~srMeterSegs  = 14;     // segments per lane, spanning -60..0 dBFS
~srMeterHz    = ~srMeterHz.clip(1, 4);

// tab order (StackLayout indices) -- named so index-dependent logic
// cannot silently rot when tabs are reordered
// column geometry -- the settings column above each strip and the strip
// itself use these, which is what keeps the two rows aligned
~stripW = 176;
~transportW = 214;

~tabFe = 0; ~tabLc = 1; ~tabCc = 2;

~srNumLanes   = 4;
~srLaneChans  = [0, 0, 0, 0];   // input channel per lane -- EDIT IN GUI too

// Loaded into lanes 1-4 on evaluation so the rig is playable before anyone
// records anything. Local copies (input_audio/defaults/) so the patch does
// not depend on the loras dataset tree. nil disables autoload.
~srDefaultTakes = ["raymond", "sora", "anna", "grisha"].collect { |n|
	"input_audio/defaults/breathing_2__" ++ n ++ ".wav"
};
// Take length. 45 s is a deliberate ceiling, not a buffer limit: the client
// pins the model's seconds_total conditioning to min(duration, 47), so past
// ~47 s the model is told a 47-second piece while being handed more than
// that -- silently wrong. Renders also scale badly (a 104 s take took 190 s
// on the fast server; x4 lanes is 12+ minutes). Staying under the cap keeps
// conditioning honest AND the studio loop workable. Allow tail padding:
// record ~45 s, set `keep s` to ~36 to crop the tail passthrough.
~srMaxRecSecs  = 45;            // recording cap
~srMaxSendSecs = 45;            // hard cap on what FlowEdit is sent

// FlowEdit server pool: jobs are distributed across entries, one job per
// server at a time. 7893 = dual-merge (fast; binding BAKED -> no strength
// flags allowed). 7888 = production unmerged (needs explicit per-pass
// binding flags). Remove an entry to take it out of rotation.
// All lanes go through ONE server, strictly one at a time (a server renders
// one request at a time anyway). To render on the slow production server
// instead, swap which entry is uncommented -- do NOT list both unless you
// want lanes split across servers.
~srServerPool = [
	(name: "7893 dual-merge", url: "http://127.0.0.1:7893/generate", extra: [])
	// (name: "7888 stacked", url: "http://127.0.0.1:7888/generate",
	//	extra: ["--src-lora-strengths", "1", "0", "--tar-lora-strengths", "0", "1"])
];

// Everything is located relative to THIS file: rig/ sits inside the
// supra-organism folder next to sa-flowedit, sa-latent-collage, wall_of_sound,
// metronomes, song_deconstruct and concatenator-corpus, on either machine.
~soRoot      = PathName(thisProcess.nowExecutingPath).pathOnly.withoutTrailingSlash.dirname;
~rigRoot     = ~soRoot +/+ "rig";
~srRoot      = ~soRoot +/+ "sa-flowedit";
~srBridge    = ~srRoot +/+ "sc_bridge.py";
~srPresetsFile = ~rigRoot +/+ "studio_presets.json";
// latent collage (sibling repo; service on 7884, already in the ssh forwards)
~srLcRoot    = ~soRoot +/+ "sa-latent-collage";
~srLcUrl     = "http://127.0.0.1:7884";

~srCcRoot    = ~soRoot +/+ "concatenator-corpus";
~srCcPython  = ~srCcRoot +/+ ".venv/bin/python";
~srCcShim    = ~srCcRoot +/+ "live_shim.py";
~srCcParticles = 500;
// The particle filter holds the entire corpus in RAM (~7 GB per corpus-hour,
// measured). Refuse anything bigger than this rather than swap the machine.
~srMaxCorpusHours = 3;    // per-lane live particle count (headroom-safe)
~srShimBasePort = 57210; // lane i listens on base+i

// FlowEdit render params
~srLfeSteps  = 20;
// lfe 20 steps, capturing every other one => 10 morph stops between your take
// and the target. Each intermediate costs ~1.2 s of server time.
~srNumInter  = 10;
~srSrcCfg    = 1.0;
~srKeepFrac  = 0.8;      // tail passthrough: keep first 80% of each render

// nanoKONTROL2 factory CC map (remap here if the unit is customized)
// Strip n = lane n: the KNOB directly above each fader is that lane's volume,
// the fader is its morph. Pan and wet live on the second bank of four.
// ------------------------- set panes (tabs 4-6) -------------------------
// Each pane is bound to ONE lane so the strips, MIDI S-row, mute/solo and the
// output meters keep meaning what they mean: lane 1 = bell_12min render,
// lane 2 = live dyads, lane 3 = metronome, lane 4 = LatentFT crossfade.
~tabWs = 3; ~tabMt = 4; ~tabLf = 5;
~wsLane = 0; ~dyLane = 1; ~mtLane = 2; ~lfLane = 3;
~wsRoot      = ~soRoot +/+ "wall_of_sound";
~wsRenders   = ~wsRoot +/+ "renders/bell_12min";
~wsStems     = ~wsRoot +/+ "stems";
~wsLoadStems = true;      // 24 x ~26 MB stereo 96 kHz stems into RAM at boot
~mtRoot      = ~soRoot +/+ "metronomes";
~lfFormFile  = ~soRoot +/+ "phantom_pain_form/out/form_compact.json";
// the original track: the project copy first, then this Mac's pre-migration copy
~lfOriginals = [
	~soRoot +/+ "song_deconstruct/in/phantom_pain.wav",
	~soRoot +/+ "phantom_pain_form/in/phantom_pain.wav",
	~soRoot.dirname.dirname +/+ "experiments/song_deconstruct/in/phantom_pain.wav"
];
~lfDirs = [    // label -> folder, scanned for wavs at eval time (rescan button)
	"fullsong" -> "song_deconstruct/.claude/worktrees/latentft/out/latentft/fullsong",
	"pieces"   -> "song_deconstruct/.claude/worktrees/latentft/out/latentft/pieces",
	"run11"    -> "song_deconstruct/.claude/worktrees/latentft/out/latentft/LISTEN_run11_grid_and_bandpass",
	"run10"    -> "song_deconstruct/out/latentft/LISTEN_run10_FULLSONG_pieces",
	"for_ann"  -> "song_deconstruct/out/latentft/for_ann",
	"for_ann"  -> "song_deconstruct/.claude/worktrees/for-ann/out/latentft/for_ann"
];

~srMidi = (
	gestureSliders: [0, 1, 2, 3],     // morph (tabs 1+3) / chase speed (tab 2)
	volumeKnobs:    [16, 17, 18, 19], // knob above the fader
	wetSliders:     [4, 5, 6, 7],     // concatenator wet/dry
	panKnobs:       [20, 21, 22, 23],
	playBtns:       [32, 33, 34, 35],   // S row = play
	collageBtns:    [48, 49, 50, 51],   // M row = collage
	morphBtns:      [64, 65, 66, 67],   // R row = morph
	tabPrev: 58, tabNext: 59
);

// ------------------------- session dir -------------------------
~srSession = ~srRoot +/+ "studio_sessions" +/+ (Date.getDate.year.asString
	++ (Date.getDate.month).asString.padLeft(2, "0")
	++ (Date.getDate.day).asString.padLeft(2, "0"));
("mkdir -p " ++ (~srSession +/+ "corpus/shared").shellQuote).systemCmd;
~srNumLanes.do { |i|
	("mkdir -p " ++ (~srSession +/+ "corpus/lane" ++ (i + 1)).shellQuote).systemCmd;
	("mkdir -p " ++ (~srRoot +/+ "output_audio/lane" ++ (i + 1)).shellQuote).systemCmd;
};

// ------------------------- server boot -------------------------
~srDevice     !? { Server.default.options.device = ~srDevice };
~srInDevice   !? { Server.default.options.inDevice = ~srInDevice };
~srOutDevice  !? { Server.default.options.outDevice = ~srOutDevice };
~srSampleRate !? { Server.default.options.sampleRate = ~srSampleRate };
Server.default.options.numInputBusChannels  = ~srNumInputs;
Server.default.options.numOutputBusChannels = ~srNumOutputs;

s.waitForBoot {
	var nL = ~srNumLanes;

	// ---------------- lane state ----------------
	~laneBuf      = Array.newClear(nL);   // mono take buffer (preview/waveform)
	~laneTakePath = Array.newClear(nL);   // wav on disk for this lane's take
	~laneSendPath = nL.collect { |i| ~srSession +/+ "send_lane" ++ (i + 1) ++ ".wav" };
	~laneLastSrc  = Array.newClear(nL);   // file the last morph actually used
	~laneDur      = Array.newClear(nL);
	~laneSelStart = 0.0 ! nL;
	~laneSelEnd   = Array.newClear(nL);
	~laneArm      = true ! nL;
	~laneLevel    = 0.7 ! nL;
	~lanePan      = [ -0.7, -0.25, 0.25, 0.7 ];
	~laneMute     = false ! nL;
	~laneSolo     = false ! nL;
	~laneMorph    = 0.0 ! nL;
	~laneTemp     = 50.0 ! nL;
	~laneWet      = 1.0 ! nL;
	~laneGrain    = 0.1 ! nL;
	// Prompt state lives in PLAIN VARIABLES, never in the widgets. A Qt view
	// can only belong to one layout, so sharing the prompt fields between the
	// lane column and the prompt window moved them out of the column, and
	// closing that window destroyed them -- after which .string returned nil
	// and GEN died on it. The window now builds its own widgets around these.
	~laneSrcStr    = Array.newClear(nL);
	~laneTarStr    = Array.newClear(nL);
	~laneTarCfgVal = 5.0 ! nL;
	// FlowEdit playback
	~laneSlotBufs = nil ! nL;
	~laneSlotPos  = nil ! nL;
	~laneSlotGain = nil ! nL;   // per-slot loudness match (slot_gains.py)
	~laneMorphSynth = nil ! nL;
	// Concat
	~laneShimUp   = false ! nL;
	~laneRenderBuf = Array.newClear(nL);
	~laneRenderSynth = nil ! nL;
	// recording
	~laneRecSynth = Array.newClear(nL);
	~laneDiskSynth = Array.newClear(nL);
	~laneDiskBuf  = Array.newClear(nL);
	// Take numbering CONTINUES from what is already in the session folder.
	// It used to reset to 0 on every evaluation, so re-evaluating the patch
	// made the next recording take01 again and overwrote the take01 already
	// on disk -- silent loss of exactly the material we want to keep.
	~nextTakeNum = {
		var nums = PathName(~srSession).files
			.select { |f| f.fileName.beginsWith("take") }
			.collect { |f| f.fileName.copyRange(4, 5).asInteger };
		if (nums.isEmpty) { 1 } { nums.maxItem + 1 };
	};
	~stamp = {
		var d = Date.getDate;
		d.hour.asString.padLeft(2, "0") ++ d.minute.asString.padLeft(2, "0")
			++ d.second.asString.padLeft(2, "0");
	};
	~takeNum = 0;
	~jobsRunning = 0;
	~midiDirty = false;

	nL.do { |i| ~laneBuf[i] = Buffer.alloc(s, s.sampleRate * ~srMaxRecSecs, 1) };

	// ---------------- SynthDefs ----------------
	SynthDef(\srRec, { |buf|
		RecordBuf.ar(SoundIn.ar(\chan.kr(0)), buf, loop: 0);
	}).add;
	SynthDef(\srDiskRec, { |buf|
		DiskOut.ar(buf, SoundIn.ar(\chan.kr(0)));
	}).add;
	// Every player reports its own POST-fader peak, tagged with its lane via
	// SendReply's replyID, so the output meters read what you actually hear
	// (level, pan and mute/solo included) no matter which tab is playing.
	~outMeter = { |sig, lane|
		var t = Impulse.kr(\mrate.kr(4));
		SendReply.kr(t, '/srOutMeters', A2K.kr(Peak.ar(sig, Delay1.kr(t))),
			\lane.kr(lane));
	};

	SynthDef(\srPrev, { |buf, amp = 0.7, pan = 0, out = 0|
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), loop: 0, doneAction: 2);
		var o = Pan2.ar(sig, pan, amp.lag(0.05));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	SynthDef(\srFilePlay, { |buf, amp = 0.7, pan = 0, out = 0, loop = 1|
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), loop: loop, doneAction: 2);
		var o = Pan2.ar(sig, pan.lag(0.05), amp.lag(0.05));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// stereo file player (collage output is stereo when stacked)
	SynthDef(\srFilePlay2, { |buf, amp = 0.7, pan = 0, out = 0, loop = 1|
		var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), loop: loop, doneAction: 2);
		var o = Balance2.ar(sig[0], sig[1], pan.lag(0.05), amp.lag(0.05));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// Input metering, sent at ~srMeterHz (<= 4). Reports TRUE PEAK over each
	// window rather than the instantaneous level: at 4 Hz a sampled amplitude
	// would step straight over transients between reports, so a loud snap
	// could read as nothing. Delay1 resets Peak only AFTER the value is read
	// (the idiom SC's own meters use).
	~makeMeterDef = {
		SynthDef(\srMeter, {
			var chans = \chans.kr(~srLaneChans);
			var trig = Impulse.kr(\rate.kr(4));
			var peak = A2K.kr(Peak.ar(SoundIn.ar(chans), Delay1.kr(trig)));
			SendReply.kr(trig, '/srMeters', peak);
		}).add;
	};
	~makeMeterDef.value;

	// ---- set panes: players ----
	// 12-minute render streamed from disk (96 kHz wav or 48 kHz mp3, rate-
	// scaled to the server rate). Position is reported once a second.
	SynthDef(\srDisk, { |buf, amp = 0.7, pan = 0, out = 0, rate = 1, start = 0, dur = 1|
		var sig = VDiskIn.ar(2, buf, rate, loop: 0);
		var pos = Line.kr(start, dur, (dur - start).max(0.01), doneAction: 2);
		var o = Balance2.ar(sig[0], sig[1], pan.lag(0.05), amp.lag(0.05));
		SendReply.kr(Impulse.kr(1), '/srWsPos', pos, \lane.kr(0));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// one dyad stem with compose.py's apex envelope: rise from silence to the
	// apex, fall to the end, no sustain. gain = the event's own random level,
	// amp = the lane level (set on the group by the mixer).
	SynthDef(\srDyad, { |buf, amp = 0.7, gain = 1, pos = 0, apex = 0.5, out = 0|
		var durS = BufDur.kr(buf);
		var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), loop: 0, doneAction: 2);
		var env = EnvGen.kr(Env([0, 1, 0], [apex * durS, (1 - apex) * durS], \sin));
		var o = Balance2.ar(sig[0], sig[1], pos, amp.lag(0.05) * gain * env);
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// metronome file (mono), position reported twice a second for the
	// beat / BPM readout
	SynthDef(\srMetro, { |buf, amp = 0.7, pan = 0, out = 0, start = 0|
		var dur = BufDur.kr(buf);
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf),
			startPos: start * BufSampleRate.kr(buf), loop: 0, doneAction: 2);
		var pos = Line.kr(start, dur, (dur - start).max(0.01));
		var o = Pan2.ar(sig, pan.lag(0.05), amp.lag(0.05));
		SendReply.kr(Impulse.kr(2), '/srMtPos', pos, \lane.kr(0));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// live click: the tempo is a control that GLIDES (VarLag) so a fader move
	// or a typed target never steps. voice 0 = synthesised pyramid-metronome
	// tock (1050/1900/3250 Hz + noise transient), 1 = Reaper-style 880 Hz beep.
	// Beat count + current BPM are reported twice a second.
	SynthDef(\srClick, { |amp = 0.7, pan = 0, out = 0, bpm = 60, glide = 1,
		curve = 0, voice = 0, t_reset = 0|
		var bpmNow = VarLag.kr(bpm, glide, curve);
		var trig = Impulse.kr(bpmNow / 60);
		var tock = (SinOsc.ar([1050, 1900, 3250]) * [1, 0.5, 0.3]).sum
			* EnvGen.ar(Env.perc(0.0005, 0.06, 1, -6), trig) * 0.5
			+ (BPF.ar(WhiteNoise.ar, 2500, 0.5)
				* EnvGen.ar(Env.perc(0.0002, 0.006, 1, -4), trig));
		var beep = SinOsc.ar(880) * EnvGen.ar(Env.perc(0.0005, 0.03, 0.7, -4), trig);
		var sig = Select.ar(voice, [tock, beep]);
		var o = Pan2.ar(sig, pan.lag(0.05), amp.lag(0.05));
		SendReply.kr(Impulse.kr(2), '/srClick',
			[PulseCount.kr(trig, t_reset), bpmNow], \lane.kr(0));
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;
	// LatentFT: two sources read by ONE clock in seconds, so files at 22050
	// and 44100 Hz stay sample-locked; equal-power crossfade xf 0 = A, 1 = B.
	// offB shifts B (a 40 s piece cut from 60 s in wants offB = -60).
	SynthDef(\srLfX, { |bufA, bufB, xf = 0, amp = 0.7, pan = 0, out = 0,
		start = 0, dur = 300, offB = 0|
		var sec = Phasor.ar(0, SampleDur.ir, start, 1e9, start);
		var rdA = BufRd.ar(2, bufA,
			(sec * BufSampleRate.kr(bufA)).clip(0, BufFrames.kr(bufA) - 1), 0, 4);
		var rdB = BufRd.ar(2, bufB,
			((sec + offB) * BufSampleRate.kr(bufB)).clip(0, BufFrames.kr(bufB) - 1), 0, 4);
		var x = xf.lag(0.05).clip(0, 1) * 0.5pi;
		var mix = (rdA * x.cos) + (rdB * x.sin);
		var o = Balance2.ar(mix[0], mix[1], pan.lag(0.05), amp.lag(0.05));
		var ksec = A2K.kr(sec);
		SendReply.kr(Impulse.kr(1), '/srLfPos', ksec, \lane.kr(0));
		FreeSelf.kr(ksec > dur);
		~outMeter.(o, 0);
		Out.ar(out, o);
	}).add;

	// per-lane morph def, sized to slot count (same crossfade math as
	// flowedit_morph.scd, plus pan/level)
	~makeMorphDef = { |lane, n|
		SynthDef(("srMorphL" ++ lane).asSymbol, { |morph = 0, morphlag = 0.08,
			amp = 0.7, pan = 0, out = 0|
			var bufnums = \bufnums.kr(0 ! n);
			var pos = \slotpos.kr(Array.series(n, 0, 1 / (n - 1)));
			var m = (VarLag.kr(morph, morphlag) / 10).clip(0, 1);
			var norm = Phasor.ar(0,
				BufRateScale.kr(bufnums.last) / BufFrames.kr(bufnums.last), 0, 1);
			var sg = \slotgain.kr(1 ! n);   // loudness match across the sweep
			var mix = n.collect { |i|
				var pl = if (i == 0) { -1.0 } { pos[i - 1] };
				var pr = if (i == (n - 1)) { 2.0 } { pos[i + 1] };
				var up = (m - pl) / max(pos[i] - pl, 1e-4);
				var down = (pr - m) / max(pr - pos[i], 1e-4);
				var g = min(up, down).clip(0, 1).sqrt;
				BufRd.ar(2, bufnums[i], norm * BufFrames.kr(bufnums[i]), loop: 1)
					* g * sg[i]
			}.sum;
			var o = Limiter.ar(
				Balance2.ar(mix[0], mix[1], pan.lag(0.05), amp.lag(0.05)), 0.95);
			~outMeter.(o, lane);
			Out.ar(out, o);
		}).add;
	};

	s.sync;

	// ---------------- presets ----------------
	~presets = [];
	~loadPresets = {
		var d;
		if (File.exists(~srPresetsFile)) {
			d = File.readAllString(~srPresetsFile).parseYAML;
			~presets = d["presets"].collect { |p|
				(name: p["name"], src: p["src"], tar: p["tar"],
					tarCfg: (p["tarCfg"] ? "5.0").asFloat)
			};
		};
		if (~presets.isEmpty) {
			~presets = [(name: "breath - harmonium",
				src: "a person breathing at a fast pace",
				tar: "a solo harmonium sustaining a warm reedy drone", tarCfg: 5.0)];
		};
	};
	// The preset file is READ-ONLY from the rig. It was writable, a lane
	// edit reached it, and a reference prompt was silently overwritten.
	// Edit studio_presets.json in a text editor to change the set.
	~savePresets = {
		~status.("presets are read-only -- edit studio_presets.json to change them");
	};
	~loadPresets.value;

	// ---------------- GUI vars ----------------
	~status = { |str| { ~statusText.string = str }.defer; str.postln };

	// ---------------- capture strip actions ----------------
	~loadLaneWave = { |i|
		var path = ~laneTakePath[i], sf = SoundFile.new;
		if (path.notNil and: { File.exists(path) } and: { sf.openRead(path) }) {
			~laneDur[i] = sf.numFrames / sf.sampleRate;
			~laneSelStart[i] = 0;
			// clamp the visible selection to what FlowEdit will accept, so a
			// long file shows its real send region instead of being silently
			// truncated later. Widen the sel boxes for a long concat target.
			~laneSelEnd[i] = ~laneDur[i].min(~srMaxSendSecs);
			{
				~laneWaveViews[i].soundfile = sf;
				~laneWaveViews[i].read(0, sf.numFrames);
				~laneWaveViews[i].refresh;
				sf.close;
				~laneSelStartBoxes[i].value = 0;
				~laneSelEndBoxes[i].value = ~laneSelEnd[i].round(0.01);
				~laneTakeTexts[i].string = path.basename
					++ " (" ++ ~laneDur[i].round(0.1) ++ "s)";
			}.defer;
		};
	};

	~stopRecording = {
		var secs = (Main.elapsedTime - ~recStart).min(~srMaxRecSecs);
		~recTimer !? { ~recTimer.stop; ~recTimer = nil };
		nL.do { |i|
			~laneRecSynth[i] !? {
				var frames = (secs * s.sampleRate).asInteger.min(~laneBuf[i].numFrames);
				var path = ~srSession +/+ "take" ++ ~takeNum.asString.padLeft(2, "0")
					++ "_" ++ ~recStamp
					++ "_lane" ++ (i + 1) ++ ".wav";
				~laneRecSynth[i].free; ~laneRecSynth[i] = nil;
				~laneTakePath[i] = path;
				OSCFunc({ { ~loadLaneWave.(i) }.defer }, '/done', s.addr,
					argTemplate: ['/b_write', ~laneBuf[i].bufnum]).oneShot;
				~laneBuf[i].write(path, "wav", "int16", frames);
			};
		};
		nL.do { |i| if (~laneArm[i]) { ~laneBufFresh[i] = true } };
		{ ~recBtn.value = 0; ~recTimeText.string = "saved " ++ secs.round(0.1) ++ "s" }.defer;
		~status.("take " ++ ~takeNum ++ " saved (" ++ secs.round(0.1) ++ "s)");
	};

	// Archive whatever is sitting in the record buffers right now, under a
	// fresh take number. The buffers do not survive a re-evaluation, so this
	// is how a take gets kept without re-recording it -- and every session's
	// material stays as training data instead of being lost.
	~saveTakes = {
		var num = ~nextTakeNum.value, st = ~stamp.value, saved = 0;
		nL.do { |i|
			if (~laneBufFresh[i] and: { ~laneDur[i].notNil }) {
				var path = ~srSession +/+ "take" ++ num.asString.padLeft(2, "0")
					++ "_" ++ st ++ "_lane" ++ (i + 1) ++ ".wav";
				var frames = (~laneDur[i] * s.sampleRate).asInteger
					.min(~laneBuf[i].numFrames);
				~laneBuf[i].write(path, "wav", "int16", frames);
				saved = saved + 1;
			};
		};
		if (saved > 0) {
			~status.("archived " ++ saved ++ " lanes as take "
				++ num.asString.padLeft(2, "0") ++ "_" ++ st);
		} {
			~status.("nothing recorded in the buffers to archive "
				++ "(loaded files are already on disk)");
		};
	};

	~startRecording = {
		~takeNum = ~nextTakeNum.value;
		~recStamp = ~stamp.value;
		nL.do { |i|
			if (~laneArm[i]) {
				~laneBuf[i].zero;
				~laneRecSynth[i] = Synth(\srRec,
					[\buf, ~laneBuf[i], \chan, ~srLaneChans[i]]);
			};
		};
		~recStart = Main.elapsedTime;
		~status.("recording take " ++ ~takeNum ++ " (max " ++ ~srMaxRecSecs ++ "s)...");
		~recTimer = Routine {
			var t = 0;
			while { (t < ~srMaxRecSecs) and: { ~laneRecSynth.any(_.notNil) } } {
				~recTimeText.string = "rec " ++ t ++ "s / " ++ ~srMaxRecSecs ++ "s";
				1.wait; t = t + 1;
			};
			if (~laneRecSynth.any(_.notNil)) { { ~stopRecording.value }.defer };
		}.play(AppClock);
	};

	// long-form corpus recording, straight to disk, no cap
	~startCorpusRec = {
		var shared = (~corpusDestMenu.value == 0);
		~corpusRecStart = Main.elapsedTime;
		nL.do { |i|
			var dir, path;
			if (~laneArm[i]) {
				dir = if (shared) { ~srSession +/+ "corpus/shared" }
					{ ~srSession +/+ "corpus/lane" ++ (i + 1) };
				path = dir +/+ "crec" ++ ~stamp.value ++ "_lane" ++ (i + 1) ++ ".wav";
				~laneDiskBuf[i] = Buffer.alloc(s, 65536, 1);
				~laneDiskBuf[i].write(path, "wav", "int16", 0, 0, true);
				~laneDiskSynth[i] = Synth(\srDiskRec,
					[\buf, ~laneDiskBuf[i], \chan, ~srLaneChans[i]], addAction: \addToTail);
			};
		};
		~status.("CORPUS recording -> " ++ (if (shared) { "shared" } { "lane folders" }));
		~corpusTimer = Routine {
			var t = 0;
			loop {
				~corpusTimeText.string = "corpus " ++ (t.div(60)) ++ "m" ++ (t % 60) ++ "s";
				1.wait; t = t + 1;
			};
		}.play(AppClock);
	};
	~stopCorpusRec = {
		~corpusTimer !? { ~corpusTimer.stop; ~corpusTimer = nil };
		nL.do { |i|
			~laneDiskSynth[i] !? { ~laneDiskSynth[i].free; ~laneDiskSynth[i] = nil };
			~laneDiskBuf[i] !? { ~laneDiskBuf[i].close; ~laneDiskBuf[i].free;
				~laneDiskBuf[i] = nil };
		};
		~status.("corpus recording stopped");
	};

	// write the lane's trimmed selection as a mono send file (used by BOTH
	// tabs; avoids server-side --trim which caps seconds_total at 47)
	// done: called with the path once the file is on disk
	// maxSecs: hard cap on the exported region (FlowEdit passes ~srMaxSendSecs
	// so seconds_total conditioning can never go stale; the concatenator
	// passes nothing, since long targets are fine there)
	~writeSendFile = { |i, done, maxSecs|
		var selS = ~laneSelStart[i], selE = ~laneSelEnd[i] ? ~laneDur[i];
		var sr2 = s.sampleRate, startF, numF;
		if (maxSecs.notNil and: { (selE - selS) > maxSecs }) {
			~status.("lane " ++ (i + 1) ++ ": " ++ (selE - selS).round(0.1)
				++ "s selection capped to " ++ maxSecs ++ "s for FlowEdit");
			selE = selS + maxSecs;
		};
		startF = (selS * sr2).asInteger;
		numF = ((selE - selS) * sr2).asInteger;
		// always resolve `done` -- a lane that can't produce a file must still
		// hand control back or the whole queue wedges behind it
		if (~laneTakePath[i].isNil) {
			~status.("lane " ++ (i + 1) ++ ": no take");
			done.(nil);
		} {
			// if the take was loaded from a file (not this buffer), read it in first
			if (~laneTakePath[i].beginsWith(~srSession).not or: { ~laneBufFresh[i].not }) {
				var sf = SoundFile.new, fsr = 44100;
				if (sf.openRead(~laneTakePath[i])) { fsr = sf.sampleRate; sf.close };
				Buffer.readChannel(s, ~laneTakePath[i],
					(selS * fsr).asInteger, ((selE - selS) * fsr).asInteger,
					channels: [0], action: { |b|
						OSCFunc({ done.(~laneSendPath[i]); b.free }, '/done', s.addr,
							argTemplate: ['/b_write', b.bufnum]).oneShot;
						b.write(~laneSendPath[i], "wav", "int16");
					});
			} {
				OSCFunc({ done.(~laneSendPath[i]) }, '/done', s.addr,
					argTemplate: ['/b_write', ~laneBuf[i].bufnum]).oneShot;
				~laneBuf[i].write(~laneSendPath[i], "wav", "int16", numF, startF);
			};
		};
	};
	~laneBufFresh = false ! nL;   // true when laneBuf holds the current take

	// ---------------- FlowEdit job runner ----------------
	// dirOverride/srcOverride let the chorus'd copies of the slots be
	// loaded in place of the raw ones without duplicating this logic
	~loadLaneSlots = { |i, dirOverride, srcOverride|
		var dir = dirOverride ?? { ~srRoot +/+ "output_audio/lane" ++ (i + 1) };
		var interFiles = (1..20).collect { |k|
			dir +/+ "inter_" ++ k.asString.padLeft(2, "0") ++ ".wav"
		}.select { |p| File.exists(p) };
		var finalP = dir +/+ "final.wav";
		// slot 0 is whatever was actually rendered -- the take's send file
		// normally, the chorus when the chain morphed a collage
		var files = [srcOverride ?? { ~laneLastSrc[i] ? ~laneSendPath[i] }]
			++ interFiles
			++ (if (File.exists(finalP)) { [finalP] } { [] });
		var n = files.size, remaining = n, newBufs = Array.newClear(n);
		var keepSecs = ~laneKeepBoxes[i].value;
		if (n < 3) { ~status.("lane " ++ (i + 1) ++ ": no outputs to load") } {
			files.do { |p, j|
				var sf = SoundFile.new, chans = 2, fsr = 44100;
				if (sf.openRead(p)) { chans = sf.numChannels; fsr = sf.sampleRate; sf.close };
				Buffer.readChannel(s, p, 0,
					if (keepSecs > 0) { (keepSecs * fsr).asInteger } { -1 },
					channels: if (chans > 1) { [0, 1] } { [0, 0] },
					action: { |b|
						newBufs[j] = b;
						// NO per-slot normalise here. slot_gains.py measures the
						// FILES and levels every slot against slot 0; normalising
						// this buffer as well made slot 0 play far louder than the
						// gain it was assigned, so the morph dropped in level the
						// moment you moved off zero.
						remaining = remaining - 1;
						if (remaining == 0) {
							var mani = dir +/+ "manifest.json", tmap = Dictionary.new, posArr;
							if (File.exists(mani)) {
								var m = File.readAllString(mani).parseYAML;
								m["slots"].do { |d| tmap[d["file"]] = d["label"] };
								// surface the seed so a good render can be repeated
								m["seed"] !? { |sd|
									~setGenText.(i, ~laneGenStr[i] ++ " seed " ++ sd);
								};
							};
							posArr = files.collect { |fp, k|
								var lab = tmap[fp.basename];
								case
								{ k == 0 } { 0.0 }
								{ fp.basename == "final.wav" } { 1.0 }
								{ lab.notNil and: { lab.beginsWith("t=") } } {
									(1 - lab.replace("t=", "").asFloat).clip(0.001, 0.999) }
								{ k / (n - 1) };
							};
							(1..(n - 1)).do { |k|
								posArr[k] = max(posArr[k], posArr[k - 1] + 0.001) };
							~laneSlotBufs[i].do(_.free);
							~laneSlotBufs[i] = newBufs;
							~laneSlotPos[i] = posArr;
							~makeMorphDef.(i, n);
							fork {
								s.sync;
								~laneMorphSynth[i] !? {
									~laneMorphSynth[i].free;
									~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol,
										~morphArgs.(i));
								};
							};
							~status.("lane " ++ (i + 1) ++ ": " ++ n ++ " slots loaded");
							~measureSlotGains.(i, files);
						};
					});
			};
		};
	};

	// The server peak-normalises every slot, so the dense target end is much
	// LOUDER than the sparse breath end at the same peak -- sweeping the morph
	// audibly ramps up. Measure each slot's loudness (out of process, result
	// via a file so the language never blocks) and level them.
	~measureSlotGains = { |i, files|
		var dir = ~srRoot +/+ "output_audio/lane" ++ (i + 1);
		var jsonPath = dir +/+ "slot_gains.json";
		var cmd = ([ "python3", ~srRoot +/+ "slot_gains.py" ] ++ files)
			.collect(_.shellQuote).join(" ") ++ " > " ++ jsonPath.shellQuote;
		File.delete(jsonPath);
		cmd.unixCmd({ |exit|
			if (exit == 0 and: { File.exists(jsonPath) }) {
				{
					var d = File.readAllString(jsonPath).parseYAML;
					var g = d !? { d["gains"] };
					if (g.notNil and: { g.size == files.size }) {
						~laneSlotGain[i] = g.collect(_.asFloat);
						~laneMorphSynth[i] !? {
							~laneMorphSynth[i].set(\slotgain, ~laneSlotGain[i]) };
						~status.("lane " ++ (i + 1) ++ ": slots loudness-matched ("
							++ ~laneSlotGain[i].last.round(0.01)
							++ "x at the target end)");
					};
				}.defer;
			};
		});
	};

	// morph status shows on the FlowEdit row AND on the collage row, so a
	// chain never leaves you guessing which stage the "done" belongs to
	~laneGenStr = "--" ! nL;   // mirror: never read .string off-thread
	~setGenText = { |i, str|
		~laneGenStr[i] = str;
		{
			~laneGenTexts[i].string = str;
			~laneLcGenTexts[i] !? { |t| t.string = "morph: " ++ str };
		}.defer;
	};

	~morphArgs = { |i|
		[\bufnums, ~laneSlotBufs[i].collect(_.bufnum), \slotpos, ~laneSlotPos[i],
			\slotgain, (~laneSlotGain[i] ? (1 ! ~laneSlotBufs[i].size)),
			\morph, ~laneMorph[i], \amp, ~effLevel.(i), \pan, ~lanePan[i],
			\out, ~srOutBus]
	};
	~effLevel = { |i|
		var soloed = ~laneSolo.any { |x| x };
		if (~laneMute[i] or: { soloed and: { ~laneSolo[i].not } }) { 0 } { ~laneLevel[i] };
	};
	~applyMix = { |i|
		~laneMorphSynth[i] !? { ~laneMorphSynth[i].set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) };
		~laneRenderSynth[i] !? { ~laneRenderSynth[i].set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) };
		~laneLcSynth[i] !? { ~laneLcSynth[i].set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) };
		if (~laneShimUp[i]) {
			~shimAddr.(i).sendMsg("/level", ~effLevel.(i));
			~shimAddr.(i).sendMsg("/pan", ~lanePan[i]);
		};
		~paneApplyMix !? { ~paneApplyMix.(i) };
	};

	// one job: write send file -> run sc_bridge -> load slots. done.() when finished.
	// MUST be entered on AppClock (button actions / defer): all Qt reads are
	// snapshotted HERE -- the callbacks below run on OSC/process threads where
	// touching a widget throws "_QObject_GetProperty failed".
	// srcOverride: morph THIS file instead of the lane's take, without
	// disturbing the take (the chorus->morph chain uses it, so the lane
	// keeps its original recording and every other tab still sends that).
	~runLaneJob = { |i, server, done, srcOverride|
		var laneDir = ~srRoot +/+ "output_audio/lane" ++ (i + 1);
		var srcText = ~laneSrcStr[i] ? "";
		var tarText = (~laneTarStr[i] ? "")
			.replace("<note>", ~laneNoteFields[i].string ? "");
		var nInter = ~laneInterBoxes[i].value.asInteger.asString;
		var tarCfg = ~laneTarCfgVal[i].asString;
		var seed = ~laneSeedBoxes[i].value.asInteger;   // <0 = fresh each run
		var runWith;   // local, NOT an env var: an env var would be clobbered
		               // by an overlapping job and the async callback would
		               // then run against the wrong lane
		~setGenText.(i, "morphing...");
		// clear stale outputs so a shorter run never picks up old inter files
		(1..20).do { |k|
			File.delete(laneDir +/+ "inter_" ++ k.asString.padLeft(2, "0") ++ ".wav") };
		File.delete(laneDir +/+ "final.wav");
		File.delete(laneDir +/+ "manifest.json");
		runWith = { |sendPath, extraFlags|
			if (sendPath.isNil) {
				~setGenText.(i, "no input");
				done.value;      // hand the queue back, don't wedge on this lane
			} {
			var cmd = ([~srBridge,
				"--audio", sendPath,
				"--url", server.url,
				"--src", srcText,
				"--tar", tarText,
				"--lfe-steps", ~srLfeSteps.asString,
				"--num-intermediates", nInter,
				"--src-cfg", ~srSrcCfg.asString,
				"--tar-cfg", tarCfg,
				"--output-dir", laneDir]
				++ extraFlags
				++ (if (seed >= 0) { ["--seed", seed.asString] } { [] })
				++ server.extra).collect(_.shellQuote).join(" ");
			var t0 = Main.elapsedTime;
			~laneLastSrc[i] = sendPath;   // becomes slot 0 of the morph player
			~setGenText.(i, "rendering on " ++ server.name ++ "...");
			cmd.unixCmd({ |exit|
				var took = (Main.elapsedTime - t0).round(1).asInteger;
				~setGenText.(i, if (exit == 0)
					{ "morph done " ++ took ++ "s" } { "morph FAILED (" ++ exit ++ ")" });
				if (exit == 0) { { ~loadLaneSlots.(i) }.defer };
				done.value;
			});
			};
		};
		if (srcOverride.notNil) {
			// morph the file as-is; cap only if it would overrun the
			// conditioning ceiling (trimming TO the cap keeps seconds_total right)
			var sf = SoundFile.new, dur = 0;
			if (sf.openRead(srcOverride)) { dur = sf.numFrames / sf.sampleRate; sf.close };
			runWith.(srcOverride, if (dur > ~srMaxSendSecs) {
				["--trim-start", "0", "--trim-end", ~srMaxSendSecs.asString]
			} { [] });
		} {
			~laneLastSrc[i] = nil;   // plain morph: slot 0 is the take again
			~writeSendFile.(i, { |p| runWith.(p, []) }, ~srMaxSendSecs);
		};
	};

	// Sequential queue: one lane at a time, every lane through the same
	// server. ~genNext is an ENVIRONMENT variable on purpose -- an earlier
	// version recursed through a local `var worker` closure and the
	// continuation silently died after the first pass, so lanes 3 and 4
	// never ran. Env-var lookup happens fresh at call time and can't go stale.
	~genQueue = List.new;
	~genTotal = 0;
	~genRunning = false;

	~genNext = {
		if (~genQueue.isEmpty) {
			~genRunning = false;
			~status.("generation finished (" ++ ~genTotal ++ " lanes)");
		} {
			var i = ~genQueue.removeAt(0);
			var server = ~srServerPool[0];
			~status.("lane " ++ (i + 1) ++ " -- "
				++ (~genTotal - ~genQueue.size) ++ "/" ++ ~genTotal
				++ " on " ++ server.name);
			~runLaneJob.(i, server, { { ~genNext.value }.defer(0.3) });
		};
	};

	~generateLanes = { |lanes|
		var ready = lanes.select { |i| ~laneTakePath[i].notNil };
		ready.do { |k| ~setGenText.(k, "queued for morph...") };
		case
		{ ~genRunning or: { ~chainRunning } or: { ~lcRunning } }
			{ ~status.("a job is already running -- wait for it") }
		{ ready.isEmpty } { ~status.("no takes to generate -- record or load first") }
		{
			~genQueue = List.newFrom(ready);
			~genTotal = ready.size;
			~genRunning = true;
			~status.("generating " ++ ~genTotal ++ " lanes, one at a time...");
			~genNext.value;
		};
	};

	// warmup: tiny render on each server so the first real take isn't slow
	~warmup = {
		var probe = ~laneTakePath.detect(_.notNil) ?? {
			var f = PathName(~srRoot +/+ "input_audio/normalized").files
				.detect { |p| p.extension == "wav" };
			f !? { f.fullPath };
		};
		if (probe.isNil) { ~status.("warmup: no wav available") } {
			~status.("warming up " ++ ~srServerPool.size ++ " servers...");
			~srServerPool.do { |server, k|
				([~srBridge, "--audio", probe, "--url", server.url,
					"--src", "a person breathing", "--tar", "a harmonium drone",
					"--lfe-steps", "4", "--num-intermediates", "1",
					"--output-dir", "/tmp/sr_warmup" ++ k]
					++ server.extra).collect(_.shellQuote).join(" ")
				.unixCmd({ |exit|
					~status.("warmup " ++ server.name ++ ": "
						++ if (exit == 0) { "ok" } { "FAILED" });
				});
			};
		};
	};

	// ---------------- concatenator shims ----------------
	~shimAddr = { |i| NetAddr("127.0.0.1", ~srShimBasePort + i) };
	~corpusChoices = {
		var base = [
			// the audio already in the lanes, which is usually what you want and
			// needs no corpus-rec pass first
			(name: "this lane's take", dir: nil, useTake: true),
			(name: "all loaded takes", dir: ~srRoot +/+ "input_audio/defaults"),
			(name: "session: shared", dir: ~srSession +/+ "corpus/shared"),
			(name: "session: lane",   dir: nil)];  // resolved per lane
		// Corpora that cannot fit in RAM are left OUT of the menu rather than
		// offered and refused later: the filter holds the whole corpus in
		// memory (~7 GB per corpus-hour, measured), and the 56 h birdsong set
		// would swap this machine into the ground. Estimated from bytes, so a
		// future oversized corpus is excluded too, not just that one.
		var skipped = List.new;
		var ext = PathName(~srCcRoot +/+ "corpus").folders.collect { |p|
			var d = p.fullPath.withoutTrailingSlash;
			var mb = ("du -sLk " ++ d.shellQuote ++ " 2>/dev/null | cut -f1")
				.unixCmdGetStdOut.stripWhiteSpace.asInteger / 1024;
			var compressed = ("find -L " ++ d.shellQuote
				++ " -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' 2>/dev/null "
				++ "| head -1").unixCmdGetStdOut.stripWhiteSpace.isEmpty.not;
			// ~1 MB/min compressed, ~10 MB/min for 44.1k stereo PCM
			var hours = mb / (if (compressed) { 60 } { 600 });
			(name: p.folderName, dir: d, hours: hours);
		}.select { |c|
			if (c.hours > ~srMaxCorpusHours) {
				skipped.add(c.name ++ " (~" ++ c.hours.round(1) ++ "h)");
				false;
			} { true };
		};
		if (skipped.notEmpty) {
			("corpus menu: left out " ++ skipped.asArray.join(", ")
				++ " -- too large to hold in RAM").postln;
		};
		base ++ ext;
	}.value;

	// first choice that has wavs on disk, preferring a breath corpus --
	// so "start shim" works out of the box instead of asserting on an
	// empty session folder
	// this lane's own take: always present (the defaults load at startup)
	// and needs no corpus-rec pass first
	~defaultCorpusIdx = 0;

	// "this lane's take" has to become a DIRECTORY, since load_corpus takes
	// a folder: link the current take into a per-lane folder of its own.
	~laneCorpusDir = { |i|
		var c = ~corpusChoices[~laneCorpusMenus[i].value];
		if (c.useTake == true) {
			var d = ~srSession +/+ "corpus/take" ++ (i + 1);
			("rm -rf " ++ d.shellQuote ++ "; mkdir -p " ++ d.shellQuote).systemCmd;
			~laneTakePath[i] !? { |tp|
				("ln -s " ++ tp.shellQuote ++ " " ++ (d +/+ tp.basename).shellQuote)
					.systemCmd;
			};
			d;
		} {
			c.dir ?? { ~srSession +/+ "corpus/lane" ++ (i + 1) };
		};
	};

	// what each lane rebuilds: its own take, or any wav in the concatenator
	// repo's targets/ folder (the song, the ocean recording, ...), or a file
	// picked with the "..." button
	~ccTargetChoices = [(name: "this lane's take", useTake: true, path: nil)]
		++ PathName(~srCcRoot +/+ "targets").files
			.select { |p| p.extension.toLower == "wav" }
			.sort { |a, b| a.fileName < b.fileName }
			.collect { |p| (name: p.fileName, useTake: false, path: p.fullPath) }
		++ [(name: "(pick a file...)", useTake: false, path: nil)];
	~laneCustomTarget = Array.newClear(nL);
	// ocean waves if it is there, else the lane's own take
	~defaultTargetIdx = ~ccTargetChoices.detectIndex { |c|
		c.path.notNil and: { c.name.containsi("ocean") } } ? 0;

	~startShim = { |i|
		var dir = ~laneCorpusDir.(i);
		// Count every format load_corpus can read, not just wav -- the birdsong
		// corpus is 940 mp3s and read as "empty". Shell, so symlinks (the
		// "this lane's take" corpus) are followed, and the glob sits OUTSIDE
		// the quoting or the shell hunts for a file literally named "*.wav".
		// -L: the prebuilt corpora are SYMLINK FARMS into the datasets, and
		// plain find -type f counts every one of them as zero files
		var find = "find -L " ++ dir.shellQuote ++ " -type f \\( "
			++ ["wav", "mp3", "flac", "aif", "aiff", "m4a", "ogg"]
				.collect { |e| "-iname '*." ++ e ++ "'" }.join(" -o ")
			++ " \\) 2>/dev/null";
		var wavs = (find ++ " | wc -l").unixCmdGetStdOut.stripWhiteSpace.asInteger;
		// Rough decoded-size guard. The 47 h birdsong corpus peaked at 330 GB
		// RSS on a cluster node; loading it here would swap this machine into
		// the ground. Estimate hours from bytes per format and refuse early.
		var mb = (find ++ " -exec du -k {} + 2>/dev/null | "
			++ "awk '{s+=$1} END {print int(s/1024)}'")
			.unixCmdGetStdOut.stripWhiteSpace.asInteger;
		var compressed = (find ++ " -iname '*.mp3' -o -iname '*.m4a' "
			++ "-o -iname '*.ogg' 2>/dev/null | wc -l")
			.unixCmdGetStdOut.stripWhiteSpace.asInteger > 0;
		// ~1 MB/min compressed, ~10 MB/min for 44.1k stereo PCM
		var hours = mb / (if (compressed) { 60 } { 600 });
		var log = ~srSession +/+ "shim_lane" ++ (i + 1) ++ ".log";
		var cmd = ("cd " ++ ~srCcRoot.shellQuote ++ " && "
			++ ([~srCcPython, ~srCcShim,
				"--corpus", dir, "--lane", (i + 1).asString,
				"--osc-port", (~srShimBasePort + i).asString,
				"--reply-port", NetAddr.langPort.asString,
				"--particles", ~srCcParticles.asString,
				"--temperature", ~laneTemp[i].asString,
				"--wet", ~laneWet[i].asString,
				// carry the fader's CURRENT grain setting into the new shim; it
				// used to start at its own default and ignore the fader until the
				// fader was next moved
				"--pd", (~laneGrain[i] / (0.0232 + ~laneGrain[i])).asString,
				"--diag-len-s", ~laneGrain[i].asString,
				"--pan", ~lanePan[i].asString,
				"--level", ~effLevel.(i).asString,
				"--out-device", (~srOutDevice ? "")]
				.collect(_.asString).collect(_.shellQuote).join(" "))
			++ " > " ++ log.shellQuote ++ " 2>&1");
		// An empty corpus makes the tool assert and exit instantly, which
		// surfaced only as "shim exited (1)". Say what is actually wrong.
		case
		{ wavs == 0 } {
			{ ~laneShimTexts[i].string = "corpus is empty" }.defer;
			~status.("lane " ++ (i + 1) ++ ": corpus " ++ dir.basename
				++ " has no audio. Do a corpus rec first, or pick a prebuilt "
				++ "corpus from the menu.");
		}
		{ hours > ~srMaxCorpusHours } {
			{ ~laneShimTexts[i].string = "corpus too big (~" ++ hours.round(1)
				++ " h)" }.defer;
			~status.("lane " ++ (i + 1) ++ ": " ++ dir.basename ++ " is ~"
				++ hours.round(1) ++ " h (" ++ wavs ++ " files). The filter holds the
				whole corpus in RAM -- roughly 7 GB per hour -- so this would swap the
				machine. Use a subset, or raise ~srMaxCorpusHours if you are sure.");
		}
		{
		// A shim may already be running on this lane's port. Clicking start
		// again would spawn a SECOND process fighting for the same OSC port,
		// while the old one went on reporting its own state over the new
		// label -- which is why the status stayed on "idle 78". Retire it.
		if (~laneShimUp[i]) {
			~shimAddr.(i).sendMsg("/quit");
			~laneShimUp[i] = false;
		};
		{ ~laneShimTexts[i].string = "starting (" ++ wavs ++ " files)..." }.defer;
		cmd.unixCmd({ |exit|
			~laneShimUp[i] = false;
			{ ~laneShimTexts[i].string = "shim exited (" ++ exit
				++ ") -- see shim_lane" ++ (i + 1) ++ ".log" }.defer;
		});
		};
	};
	// Resolve what this lane is REBUILDING (the target) and hand it to action.
	// The corpus is what the output is made OF; the target is what it is
	// shaped LIKE. Targeting your own take with a corpus of your own voices
	// just rebuilds the take out of itself -- point this at the song or the
	// ocean recording to hear the corpus reconstruct something else.
	// Qt read: call only from AppClock (button actions).
	~laneTargetPath = { |i, action|
		var choice = ~ccTargetChoices[~laneTargetMenus[i].value];
		var p = choice.path ?? { ~laneCustomTarget[i] };
		if (choice.useTake) { ~writeSendFile.(i, action) } {
			if (p.notNil and: { File.exists(p) }) { action.(p) } {
				~status.("lane " ++ (i + 1) ++ ": no target file selected");
				action.(nil);
			};
		};
	};

	~shimPlay = { |i|
		if (~laneShimUp[i].not) { ~status.("lane " ++ (i + 1) ++ ": shim not ready") } {
			~laneTargetPath.(i, { |p|
				if (p.notNil) { ~shimAddr.(i).sendMsg("/start", p) };
			});
		};
	};
	~shimRender = { |i, done|
		var dir = ~laneCorpusDir.(i);
		~laneTargetPath.(i, { |sendPath|
			if (sendPath.isNil) { done !? { done.value } } {
			var out = ~srSession +/+ "concat_lane" ++ (i + 1) ++ "_take"
				++ ~takeNum.asString.padLeft(2, "0") ++ ".wav";
			var cmd = ("cd " ++ ~srCcRoot.shellQuote ++ " && "
				++ ([~srCcPython, ~srCcShim, "--corpus", dir,
					"--target", sendPath, "--render", out,
					"--lane", (i + 1).asString,
					"--particles", ~srCcParticles.asString,
					"--temperature", ~laneTemp[i].asString,
					"--pd", (~laneGrain[i] / (0.0232 + ~laneGrain[i])).asString,
					"--wet", ~laneWet[i].asString]
				.collect(_.asString).collect(_.shellQuote).join(" ")));
			{ ~laneShimTexts[i].string = "rendering offline..." }.defer;
			cmd.unixCmd({ |exit|
				{
					~laneShimTexts[i].string = if (exit == 0)
						{ "render done" } { "render FAILED (" ++ exit ++ ")" };
				}.defer;
				if (exit == 0) {
					Buffer.readChannel(s, out, channels: [0], action: { |b|
						{
							~laneRenderBuf[i] !? { ~laneRenderBuf[i].free };
							~laneRenderBuf[i] = b;
							~status.("lane " ++ (i + 1)
								++ ": concat render loaded -- press play");
						}.defer;
					});
				};
				done !? { done.value };
			});
			};
		});
	};

	OSCdef(\srConcatStatus, { |msg|
		var lane = msg[1].asInteger - 1, state = msg[2].asString;
		var frames = msg[3], over = msg[4], secs = msg[5];
		if (lane >= 0 and: { lane < nL }) {
			~laneShimUp[lane] = true;
			{
				~laneShimTexts[lane].string = state ++ " " ++ secs.round(1).asInteger
					++ "s" ++ if (over > 0) { " (!" ++ over ++ " over)" } { "" };
			}.defer;
		};
	}, '/concat/status');

	~quitShims = {
		nL.do { |i| if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/quit") } };
		~laneShimUp = false ! nL;
	};

	// ---------------- latent collage (tab 3) ----------------
	// Segments the take at breath/silence boundaries, rearranges whole LATENT
	// segments, decodes. Same material, new form -- no diffusion in this path,
	// so the timbre survives intact. voices=1 -> collage_client.py;
	// voices>1 -> stack.py (N rearrangements of the SAME take, folded to mono
	// and panned across the field).
	~lcOutPath = { |i| ~srSession +/+ "collage_lane" ++ (i + 1) ++ ".wav" };

	~lcRunLane = { |i, done|
		// Qt reads snapshotted here on AppClock, same rule as the FlowEdit job
		var mode = ["alternate", "shuffle", "reverse"][~laneLcModeMenus[i].value];
		var voices = ~laneLcVoicesBoxes[i].value.asInteger.max(1);
		var seed = ~laneLcSeedBoxes[i].value.asInteger;
		var xfade = ~laneLcXfadeBoxes[i].value.asInteger;
		var silence = ~laneLcSilenceBoxes[i].value;
		var minSeg = ~laneLcMinSegBoxes[i].value.asInteger;
		var out = ~lcOutPath.(i);
		var script, modeFlag;
		{ ~laneLcTexts[i].string = "collage: collaging..." }.defer;
		// stack.py has no reverse mode -- say so rather than silently swapping
		if ((voices > 1) and: { mode == "reverse" }) {
			~status.("lane " ++ (i + 1)
				++ ": reverse is single-voice only -- using alternate");
			mode = "alternate";
		};
		script = if (voices > 1) { ~srLcRoot +/+ "stack.py" }
			{ ~srLcRoot +/+ "collage_client.py" };
		modeFlag = if (voices > 1) { ["--mode", mode] } { ["--" ++ mode] };
		~writeSendFile.(i, { |sendPath|
			if (sendPath.isNil) {
				{ ~laneLcTexts[i].string = "collage: no input" }.defer;
				done.value;
			} {
				var cmd = (["python3", script, sendPath,
					"--url", ~srLcUrl,
					"--xfade-frames", xfade.asString,
					"--silence-db", silence.asString,
					"--min-seg-ms", minSeg.asString,
					"--out-dir", ~srSession +/+ "collage_out",
					"--output-file", out]
					++ modeFlag
					++ (if (voices > 1) { ["--n", voices.asString] } { [] })
					++ (if (seed >= 0) { ["--seed", seed.asString] } { [] })
				).collect(_.asString).collect(_.shellQuote).join(" ");
				var t0 = Main.elapsedTime;
				{ ~laneLcTexts[i].string = "collage: building " ++ voices ++ " voice"
					++ (if (voices > 1) { "s" } { "" }) ++ "..." }.defer;
				cmd.unixCmd({ |exit|
					var took = (Main.elapsedTime - t0).round(1).asInteger;
					{ ~laneLcTexts[i].string = if (exit == 0)
						{ "collage done " ++ took ++ "s" }
						{ "collage FAILED (" ++ exit ++ ") -- is 7884 up?" } }.defer;
					if (exit == 0) {
						var sf = SoundFile.new, chans = 2;
						if (sf.openRead(out)) { chans = sf.numChannels; sf.close };
						Buffer.readChannel(s, out,
							channels: if (chans > 1) { [0, 1] } { [0, 0] },
							action: { |b|
								{
									~laneLcBuf[i] !? { ~laneLcBuf[i].free };
									~laneLcBuf[i] = b;
									~status.("lane " ++ (i + 1) ++ ": collage loaded");
								}.defer;
							});
					};
					done.value;
				});
			};
		});
	};

	// one job at a time: the service holds a single GPU lock, so a second
	// lane would just block inside python with no feedback
	~lcQueue = List.new;
	~lcTotal = 0;
	~lcRunning = false;
	~lcNext = {
		if (~lcQueue.isEmpty) {
			~lcRunning = false;
			~status.("collage finished (" ++ ~lcTotal ++ " lanes)");
		} {
			var i = ~lcQueue.removeAt(0);
			~status.("collage lane " ++ (i + 1) ++ " -- "
				++ (~lcTotal - ~lcQueue.size) ++ "/" ++ ~lcTotal);
			~lcRunLane.(i, { { ~lcNext.value }.defer(0.3) });
		};
	};
	~lcGenerateLanes = { |lanes|
		var ready = lanes.select { |i| ~laneTakePath[i].notNil };
		ready.do { |k| { ~laneLcTexts[k].string = "collage: queued for collage..." }.defer };
		case
		{ ~lcRunning or: { ~chainRunning } or: { ~genRunning } }
			{ ~status.("a job is already running -- wait for it") }
		{ ready.isEmpty } { ~status.("no takes to collage -- record or load first") }
		{
			~lcQueue = List.newFrom(ready);
			~lcTotal = ready.size;
			~lcRunning = true;
			~status.("collaging " ++ ~lcTotal ++ " lanes, one at a time...");
			~lcNext.value;
		};
	};

	// CHAIN: collage -> morph. Build the chorus (N rearranged voices of the
	// take), then morph THAT, so the fader sweeps the whole chorus from breath
	// to harmonium rather than a single voice.
	// NON-DESTRUCTIVE: the chorus is passed to the morph as a source override,
	// so the lane's take stays the original recording and every other tab goes
	// on sending it. Only the morph player holds the chorus.
	// Rearrange every slot of a finished morph into an N-voice chorus, using
	// ONE segmentation computed on the solo source. FlowEdit preserves timing
	// (slot envelopes track the source at zero lag), so the same cut points
	// are valid for every slot and they stay sample-aligned with each other --
	// which is what lets the morph player go on crossfading between them.
	// Needs numpy/scipy, hence the concatenator venv rather than system python.
	~chorusSlots = { |i, done|
		var dir = ~srRoot +/+ "output_audio/lane" ++ (i + 1);
		var outDir = dir +/+ "chorus";
		var src = ~laneLastSrc[i] ? ~laneSendPath[i];
		var slots = [src] ++ (1..20).collect { |k|
			dir +/+ "inter_" ++ k.asString.padLeft(2, "0") ++ ".wav"
		}.select { |p| File.exists(p) }
			++ (if (File.exists(dir +/+ "final.wav")) { [dir +/+ "final.wav"] } { [] });
		var voices = ~laneLcVoicesBoxes[i].value.asInteger.max(1);
		var seed = ~laneLcSeedBoxes[i].value.asInteger;
		var mode = ["alternate", "shuffle", "reverse"][~laneLcModeMenus[i].value];
		var cmd;
		if (mode == "reverse") { mode = "alternate" };   // no reverse in this path
		cmd = ([~srCcPython, ~srRoot +/+ "chorus_slots.py",
			"--source", src, "--out-dir", outDir,
			"--voices", voices.asString, "--mode", mode]
			++ (if (seed >= 0) { ["--seed", seed.asString] } { [] })
			++ slots).collect(_.asString).collect(_.shellQuote).join(" ");
		{ ~laneLcTexts[i].string = "chorus: " ++ voices ++ " voices..." }.defer;
		cmd.unixCmd({ |exit|
			if (exit == 0) {
				{
					~laneLcTexts[i].string = "chorus: " ++ voices ++ " voices ready";
					// reload the morph player from the chorus'd copies
					~loadLaneSlots.(i, outDir, outDir +/+ src.basename);
					~status.("lane " ++ (i + 1) ++ ": morph slots are now a "
						++ voices ++ "-voice chorus -- sweep the fader");
				}.defer;
			} {
				{ ~laneLcTexts[i].string = "chorus FAILED (" ++ exit ++ ")" }.defer;
			};
			done !? { done.value };
		});
	};

	// CHAIN, the good way round: morph the SOLO take (which is what the voice
	// LoRA was trained on), then chorus every slot of the result. The old
	// order -- build a chorus, then morph the summed chorus -- fed the model a
	// mixture it never saw in training, and cost a render per voice if you
	// wanted them independent. This is one render plus a fraction of a second.
	~lcChainLane = { |i, done|
		~runLaneJob.(i, ~srServerPool[0], {
			{ ~chorusSlots.(i, done) }.defer(0.3);
		});
	};

	~chainQueue = List.new;
	~chainTotal = 0;
	~chainRunning = false;
	~chainNext = {
		if (~chainQueue.isEmpty) {
			~chainRunning = false;
			~status.("chain finished -- morph faders now sweep the chorus");
		} {
			var i = ~chainQueue.removeAt(0);
			~status.("chain lane " ++ (i + 1) ++ " -- "
				++ (~chainTotal - ~chainQueue.size) ++ "/" ++ ~chainTotal);
			~lcChainLane.(i, { { ~chainNext.value }.defer(0.3) });
		};
	};
	~chainLanes = { |lanes|
		var ready = lanes.select { |i| ~laneTakePath[i].notNil };
		ready.do { |k|
			{ ~laneLcTexts[k].string = "collage: queued..." }.defer;
			~setGenText.(k, "queued for morph...");
		};
		case
		{ ~chainRunning or: { ~lcRunning } or: { ~genRunning } }
			{ ~status.("a job is already running -- wait for it") }
		{ ready.isEmpty } { ~status.("no takes to chain") }
		{
			~chainQueue = List.newFrom(ready);
			~chainTotal = ready.size;
			~chainRunning = true;
			~status.("chaining " ++ ~chainTotal ++ " lanes: collage then morph...");
			~chainNext.value;
		};
	};

	// Cancel everything queued and kill the local render clients.
	// IMPORTANT and worth being honest about: a render already accepted by
	// the GPU server WILL run to completion there -- the server holds one
	// job at a time and has no cancel endpoint. What this buys you is that
	// the rig stops waiting for it and nothing further is submitted, so a
	// long job you no longer want blocks the next one for its remaining
	// time instead of dragging the whole queue behind it.
	~killRenderClients = { |then|
		var parts = [~srBridge, ~srLcRoot +/+ "collage_client.py",
			~srLcRoot +/+ "stack.py", ~srRoot +/+ "chorus_slots.py"];
		// scoped to THIS repo's scripts so another session's work survives
		var cmd = parts.collect { |x| "pkill -f " ++ x.shellQuote }.join("; ");
		(cmd ++ "; true").unixCmd({ then !? { then.value } });
	};

	~cancelAll = {
		var pending = ~genQueue.size + ~lcQueue.size + ~chainQueue.size;
		~genQueue = List.new; ~lcQueue = List.new; ~chainQueue = List.new;
		~genRunning = false; ~lcRunning = false; ~chainRunning = false;
		~killRenderClients.(nil);
		nL.do { |i|
			~setGenText.(i, "cancelled");
			{ ~laneLcTexts[i].string = "collage: cancelled" }.defer;
		};
		~status.("cancelled -- " ++ pending ++ " queued dropped. A render already "
			++ "on the GPU still finishes there before the next one starts.");
		~surfRefresh !? { ~surfRefresh.value };
	};

	~lcPlayAll = { |on|
		if (on) {
			s.bind {
				nL.do { |i|
					if (~laneLcBuf[i].notNil and: { ~laneLcSynth[i].isNil }) {
						~laneLcSynth[i] = Synth(\srFilePlay2, [\buf, ~laneLcBuf[i], \lane, i,
							\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
					};
				};
			};
		} {
			nL.do { |i|
				~laneLcSynth[i] !? { ~laneLcSynth[i].free; ~laneLcSynth[i] = nil };
			};
		};
		{ nL.do { |i|
			~laneLcPlayBtns[i].value =
				if (on and: { ~laneLcBuf[i].notNil }) { 1 } { 0 };
		} }.defer;
	};

	// ---------------- GUI ----------------
	~laneWaveViews = Array.newClear(nL);
	~laneTakeTexts = Array.newClear(nL);
	~laneMeterTexts = Array.newClear(nL);
	~laneMeterViews = Array.newClear(nL);
	~laneMeterSegs = Array.newClear(nL);
	~laneOutMeterViews = Array.newClear(nL);
	~laneOutMeterSegs = Array.newClear(nL);
	~laneOutLit = 0 ! nL;
	~laneOutPeak = 0 ! nL;
	~laneOutDrawn = -1 ! nL;
	~laneOutPeakDrawn = -1 ! nL;
	~laneOutSeen = 0 ! nL;    // frames since this lane last reported
	~laneMeterLit = 0 ! nL;        // segments currently lit
	~laneMeterPeak = 0 ! nL;       // peak-hold marker position
	~laneMeterDrawn = -1 ! nL;     // last painted lit count
	~laneMeterPeakDrawn = -1 ! nL; // last painted peak position
	~meterTick = 0;
	~laneSelStartBoxes = Array.newClear(nL);
	~laneSelEndBoxes = Array.newClear(nL);
	~laneChanBoxes = Array.newClear(nL);
	~laneArmBtns = Array.newClear(nL);
	~laneNoteFields = Array.newClear(nL);
	~lanePresetMenus = Array.newClear(nL);
	~laneTarCfgBoxes = Array.newClear(nL);
	~laneInterBoxes = Array.newClear(nL);
	~laneKeepBoxes = Array.newClear(nL);
	~laneGenTexts = Array.newClear(nL);
	~laneSeedBoxes = Array.newClear(nL);
	~laneMorphSliders = Array.newClear(nL);
	~laneMorphBoxes = Array.newClear(nL);
	~lanePanBoxes = Array.newClear(nL);
	~laneLevelBoxes = Array.newClear(nL);
	~lanePlayBtns = Array.newClear(nL);
	~laneCorpusMenus = Array.newClear(nL);
	~laneTargetMenus = Array.newClear(nL);
	~laneLcModeMenus = Array.newClear(nL);
	~laneLcVoicesBoxes = Array.newClear(nL);
	~laneLcSeedBoxes = Array.newClear(nL);
	~laneLcXfadeBoxes = Array.newClear(nL);
	~laneLcSilenceBoxes = Array.newClear(nL);
	~laneLcMinSegBoxes = Array.newClear(nL);
	~laneLcTexts = Array.newClear(nL);      // collage stage status
	~laneLcGenTexts = Array.newClear(nL);   // morph stage status, same row
	~laneLcPlayBtns = Array.newClear(nL);
	// second view onto the SAME morph value as tab 1, so a chained chorus can
	// be swept without leaving the collage tab
	~laneLcMorphSliders = Array.newClear(nL);
	~laneLcMorphBoxes = Array.newClear(nL);
	~laneLcBuf = Array.newClear(nL);
	~laneLcSynth = nil ! nL;
	~laneShimTexts = Array.newClear(nL);
	~laneTempBoxes = Array.newClear(nL);
	~laneWetBoxes = Array.newClear(nL);
	~laneGrainBoxes = Array.newClear(nL);

	~win = Window("supra-organism rig -- flowedit + concatenator + set panes",
		Rect(60, 40, 1180, 860)).front;

	// ----- capture strip -----
	~captureRows = nL.collect { |i|
		~laneChanBoxes[i] = NumberBox().clipLo_(0).clipHi_(63).step_(1)
		.scroll_step_(1).decimals_(0).value_(~srLaneChans[i]).fixedWidth_(44)
		.action_({ |nb|
			~srLaneChans[i] = nb.value.asInteger;
			~meterSynth !? { ~meterSynth.set(\chans, ~srLaneChans) };
		});
		~laneArmBtns[i] = Button().states_([
			["arm", Color.gray(0.4), Color.white],
			["ARMED", Color.white, Color.red(0.7)]])
		.value_(1).action_({ |b| ~laneArm[i] = (b.value == 1) }).fixedWidth_(64);
		// segmented meter: one View per block, lit or unlit -- no sliding bar
		~laneMeterSegs[i] = ~srMeterSegs.collect { |k|
			View().fixedWidth_(6).fixedHeight_(15).background_(Color.gray(0.18))
		};
		~laneMeterViews[i] = View()
		.layout_(HLayout(*~laneMeterSegs[i]).spacing_(1).margins_(0))
		.fixedWidth_((~srMeterSegs * 7) + 2).fixedHeight_(17);
		~laneMeterTexts[i] = StaticText().string_("-inf").fixedWidth_(46);
		// post-fader OUTPUT meter: what this lane is sending to the speakers
		~laneOutMeterSegs[i] = ~srMeterSegs.collect { |k|
			View().fixedWidth_(5).fixedHeight_(13).background_(Color.gray(0.18))
		};
		~laneOutMeterViews[i] = View()
		.layout_(HLayout(*~laneOutMeterSegs[i]).spacing_(1).margins_(0))
		.fixedWidth_((~srMeterSegs * 6) + 2).fixedHeight_(15);
		~laneTakeTexts[i] = StaticText().string_("(no take)").fixedWidth_(190);
		~laneWaveViews[i] = SoundFileView().gridOn_(false).timeCursorOn_(false)
		.fixedHeight_(52);   // keep the capture strip compact --
		                                  // the tab area below gets the stretch
		~laneWaveViews[i].setEditableSelectionStart(0, false);
		~laneWaveViews[i].setEditableSelectionSize(0, false);
		~laneSelStartBoxes[i] = NumberBox().clipLo_(0).step_(0.5).scroll_step_(0.5)
		.decimals_(1).fixedWidth_(54).action_({ |nb|
			~laneSelStart[i] = nb.value.max(0) });
		~laneSelEndBoxes[i] = NumberBox().clipLo_(0).step_(0.5).scroll_step_(0.5)
		.decimals_(1).fixedWidth_(54).action_({ |nb|
			~laneSelEnd[i] = nb.value });
		HLayout(
			StaticText().string_((i + 1).asString).fixedWidth_(14)
				.font_(Font.default.boldVariant),
			StaticText().string_("in").fixedWidth_(16), ~laneChanBoxes[i],
			~laneArmBtns[i],
			StaticText().string_("in").fixedWidth_(16), ~laneMeterViews[i],
			~laneMeterTexts[i],
			Button().states_([["load...", Color.black, Color.white]])
			.fixedWidth_(56).action_({
				Dialog.openPanel(path: ~srSession, okFunc: { |path|
					~laneTakePath[i] = path;
					~laneBufFresh[i] = false;
					~loadLaneWave.(i);
				});
			}),
			Button().states_([["play", Color.black, Color.white],
				["stop", Color.white, Color.green(0.5)]])
			.fixedWidth_(48).action_({ |b|
				if (b.value == 1) {
					if (~laneTakePath[i].notNil) {
						Buffer.readChannel(s, ~laneTakePath[i], channels: [0],
							action: { |bf|
								~lanePrevSynth = Synth(\srPrev, [\buf, bf, \lane, i,
									\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
								~lanePrevSynth.onFree { bf.free; { b.value = 0 }.defer };
							});
					} { b.value = 0 };
				} { ~lanePrevSynth !? { ~lanePrevSynth.free; ~lanePrevSynth = nil } };
			}),
			~laneTakeTexts[i],
			[~laneWaveViews[i], stretch: 1],
			StaticText().string_("sel").fixedWidth_(22),
			~laneSelStartBoxes[i], ~laneSelEndBoxes[i],
			// selection defaults to the FlowEdit cap; collage/concat accept
			// much longer, so make "use the whole file" one click
			Button().states_([["full", Color.black, Color.white]])
			.fixedWidth_(40).action_({
				~laneDur[i] !? { |d|
					~laneSelStart[i] = 0;
					~laneSelEnd[i] = d;
					{
						~laneSelStartBoxes[i].value = 0;
						~laneSelEndBoxes[i].value = d.round(0.01);
					}.defer;
					~status.("lane " ++ (i + 1) ++ ": selection = full "
						++ d.round(0.1) ++ "s (FlowEdit still caps at "
						++ ~srMaxSendSecs ++ "s)");
				};
			})
		)
	};

	~recBtn = Button().states_([
		["● REC TAKES", Color.white, Color.red(0.55)],
		["■ STOP + SAVE", Color.white, Color.red(0.8)]])
	.fixedWidth_(120).action_({ |b|
		if (b.value == 1) { ~startRecording.value } { ~stopRecording.value };
	});
	~recTimeText = StaticText().string_("--").fixedWidth_(110)
	.font_(Font.default.boldVariant);
	~corpusRecBtn = Button().states_([
		["● corpus rec", Color.black, Color.white],
		["■ stop corpus rec", Color.white, Color.blue(0.5)]])
	.fixedWidth_(130).action_({ |b|
		if (b.value == 1) { ~startCorpusRec.value } { ~stopCorpusRec.value };
	});
	~corpusDestMenu = PopUpMenu().items_(["-> shared pool", "-> lane folders"])
	.fixedWidth_(120);
	~corpusTimeText = StaticText().string_("").fixedWidth_(110);
	~statusText = StaticText().string_("idle").font_(Font.default.boldVariant);

	// ----- tab 1: flowedit -----
	// Prompts are full sentences and cannot live in a 300px strip, so each
	// lane opens its own editor window: preset picker (swap between harmonium,
	// aeolian, ocean, brook -- all written in the Stable Audio caption style
	// the LoRAs were trained on), the two prompt fields, cfg, and save.
	~promptWins = Array.newClear(nL);
	// Views currently shown in a lane's prompt window, so a preset change can
	// refresh them. Empty when the window is closed -- nothing outside this
	// window ever depends on these existing.
	~promptViews = Array.newClear(nL);
	~syncPromptViews = { |i|
		var v = ~promptViews[i];
		{
			~laneTarCfgBoxes[i] !? { |b| b.value = ~laneTarCfgVal[i] };
			v !? {
				v.src.string = ~laneSrcStr[i] ? "";
				v.tar.string = ~laneTarStr[i] ? "";
				v.cfg.value = ~laneTarCfgVal[i];
			};
		}.defer;
	};

	// The window builds its OWN widgets every time and writes straight into
	// the lane state. It borrows nothing from the main layout: a Qt view can
	// only live in one layout, so borrowing moved controls out of the lane
	// column, and closing the window then destroyed them.
	~openPromptWindow = { |i|
		var w = ~promptWins[i];
		if (w.notNil and: { w.isClosed.not }) { w.front } {
			var srcF, tarF, cfgB, presetM;
			w = Window("lane " ++ (i + 1) ++ " -- prompts",
				Rect(180 + (i * 26), 220 + (i * 26), 760, 300));
			srcF = TextField().string_(~laneSrcStr[i] ? "")
				.action_({ |f| ~laneSrcStr[i] = f.string });
			tarF = TextField().string_(~laneTarStr[i] ? "")
				.action_({ |f| ~laneTarStr[i] = f.string });
			cfgB = NumberBox().clipLo_(0).clipHi_(25).step_(0.5).scroll_step_(0.5)
				.decimals_(1).value_(~laneTarCfgVal[i]).fixedWidth_(60)
				.action_({ |b| ~laneTarCfgVal[i] = b.value; ~syncPromptViews.(i) });
			presetM = PopUpMenu().items_(~presets.collect(_.name)).fixedWidth_(240)
				.value_(~lanePresetMenus[i].value)
				.action_({ |m|
					var pr = ~presets[m.value];
					~laneSrcStr[i] = pr.src;
					~laneTarStr[i] = pr.tar;
					~laneTarCfgVal[i] = pr.tarCfg;
					{ ~lanePresetMenus[i].value = m.value }.defer;
					~syncPromptViews.(i);
				});
			~promptViews[i] = (src: srcF, tar: tarF, cfg: cfgB);
			w.layout = VLayout(
				HLayout(StaticText().string_("preset").fixedWidth_(50), presetM,
					StaticText().string_("presets are read-only; edits stay on this lane"),
					nil),
				StaticText().string_("src -- describe the RECORDING truthfully; "
					++ "FlowEdit steers away from it").fixedHeight_(16),
				srcF,
				StaticText().string_("tar -- the target. <note> is replaced by this "
					++ "lane's note field").fixedHeight_(16),
				tarF,
				HLayout(StaticText().string_("tar cfg").fixedWidth_(50), cfgB,
					StaticText().string_("5 = general, 9 = when the prompt names a "
						++ "pitch (measured optimum)"),
					nil),
				nil
			);
			// edits are committed on Enter; take them on close too so a typed
			// prompt is never silently lost
			w.onClose = {
				~laneSrcStr[i] = srcF.string;
				~laneTarStr[i] = tarF.string;
				~laneTarCfgVal[i] = cfgB.value;
				~promptViews[i] = nil;
			};
			w.front;
			~promptWins[i] = w;
		};
	};

	~feLaneRows = nL.collect { |i|
		~lanePresetMenus[i] = PopUpMenu().items_(~presets.collect(_.name))
		.fixedWidth_(210).action_({ |m|
			var p = ~presets[m.value];
			~laneSrcStr[i] = p.src;
			~laneTarStr[i] = p.tar;
			~laneTarCfgVal[i] = p.tarCfg;
			~syncPromptViews.(i);
		});
		~laneNoteFields[i] = TextField().string_(["G3", "C4", "E4", "G4"][i])
		.fixedWidth_(50);
		~laneSrcStr[i] = ~presets[0].src;
		~laneTarStr[i] = ~presets[0].tar;
		~laneTarCfgVal[i] = ~presets[0].tarCfg;
		~laneTarCfgBoxes[i] = NumberBox().clipLo_(0).clipHi_(25).step_(0.5)
		.scroll_step_(0.5).decimals_(1).value_(~presets[0].tarCfg).fixedWidth_(48)
		.action_({ |nb| ~laneTarCfgVal[i] = nb.value });
		~laneInterBoxes[i] = NumberBox().clipLo_(1).clipHi_(20).step_(1)
		.scroll_step_(1).decimals_(0).value_(~srNumInter).fixedWidth_(40);
		~laneKeepBoxes[i] = NumberBox().clipLo_(0).step_(1).scroll_step_(1)
		.decimals_(0).value_(0).fixedWidth_(44);   // 0 = keep all; set = keep-seconds
		// -1 = fresh seed each run. Type a reported seed here to reproduce a
		// render exactly (same seed + same params = same audio).
		~laneSeedBoxes[i] = NumberBox().step_(1).scroll_step_(1).decimals_(0)
		.value_(-1).fixedWidth_(84);
		~laneGenTexts[i] = StaticText().string_("--").fixedWidth_(190);
		~laneMorphSliders[i] = Slider().orientation_(\horizontal).value_(0)
		.step_(1/80).action_({ |sl| ~setMorph.(i, sl.value * 10, true) });
		~laneMorphBoxes[i] = NumberBox().clipLo_(0).clipHi_(10).step_(0.125)
		.scroll_step_(0.125).decimals_(2).value_(0).fixedWidth_(56)
		.action_({ |nb| ~setMorph.(i, nb.value, true) });
		~lanePanBoxes[i] = NumberBox().clipLo_(-1).clipHi_(1).step_(0.1)
		.scroll_step_(0.1).decimals_(2).value_(~lanePan[i]).fixedWidth_(52)
		.action_({ |nb| ~lanePan[i] = nb.value; ~applyMix.(i) });
		~laneLevelBoxes[i] = NumberBox().clipLo_(0).clipHi_(1).step_(0.05)
		.scroll_step_(0.05).decimals_(2).value_(~laneLevel[i]).fixedWidth_(52)
		.action_({ |nb| ~laneLevel[i] = nb.value; ~applyMix.(i) });
		~lanePlayBtns[i] = Button().states_([
			["play", Color.black, Color.white],
			["stop", Color.white, Color.green(0.5)]])
		.fixedWidth_(52).action_({ |b|
			if (b.value == 1) {
				if (~laneSlotBufs[i].notNil) {
					~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol, ~morphArgs.(i));
				} { b.value = 0; ~status.("lane " ++ (i + 1) ++ ": nothing generated") };
			} { ~laneMorphSynth[i] !? { ~laneMorphSynth[i].free; ~laneMorphSynth[i] = nil } };
		});
		View().fixedWidth_(~stripW).layout_(VLayout(
			~lanePresetMenus[i].fixedWidth_(~stripW - 6),
			Button().states_([["prompts...", Color.black, Color.white]])
			.fixedWidth_(~stripW - 6).action_({ ~openPromptWindow.(i) }),
			HLayout(StaticText().string_("note").fixedWidth_(40),
				~laneNoteFields[i], nil),
			HLayout(StaticText().string_("tar cfg").fixedWidth_(50),
				~laneTarCfgBoxes[i], nil),
			HLayout(StaticText().string_("inter").fixedWidth_(50),
				~laneInterBoxes[i], nil),
			HLayout(StaticText().string_("keep s").fixedWidth_(50),
				~laneKeepBoxes[i], nil),
			HLayout(StaticText().string_("seed").fixedWidth_(50),
				~laneSeedBoxes[i], nil),
			~laneGenTexts[i].fixedWidth_(~stripW - 6),
			nil
		))
	};

	~setMorph = { |i, v, fromGui = false|
		~laneMorph[i] = v.clip(0, 10);
		// Moving the morph used to be a SILENT no-op unless the lane was
		// already playing, which reads as "the morph does nothing". If the
		// lane has outputs, touching the morph starts it.
		if (~laneMorphSynth[i].isNil and: { ~laneSlotBufs[i].notNil }) {
			~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol, ~morphArgs.(i));
			{ ~lanePlayBtns[i].value = 1 }.defer;
		};
		~laneMorphSynth[i] !? {
			~laneMorphSynth[i].set(\morphlag, 0.08, \morph, ~laneMorph[i]) };
		if (fromGui) {
			~laneMorphSliders[i].value = ~laneMorph[i] / 10;
			~laneMorphBoxes[i].value = ~laneMorph[i];
			~laneLcMorphSliders[i] !? { |s2| s2.value = ~laneMorph[i] / 10 };
			~laneLcMorphBoxes[i] !? { |b2| b2.value = ~laneMorph[i] };
		} { ~midiDirty = true };
	};

	// Automated sweep across every playing lane, the way flowedit_morph.scd
	// does it: ONE server-side ramp (VarLag over the whole duration) so the
	// audio glides continuously, while the GUI only mirrors it once a second
	// -- no animation, stepped readout.
	~sweepRout = nil;
	~runMorphSweep = { |from, to|
		var dur = ~sweepDurBox.value.max(0.5);
		~sweepRout !? { ~sweepRout.stop; ~sweepRout = nil };
		nL.do { |i|
			if (~laneMorphSynth[i].isNil and: { ~laneSlotBufs[i].notNil }) {
				~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol, ~morphArgs.(i));
				{ ~lanePlayBtns[i].value = 1 }.defer;
			};
		};
		if (~laneMorphSynth.every(_.isNil)) {
			~status.("nothing generated to sweep");
		} {
			~status.("sweeping morph " ++ from ++ " -> " ++ to
				++ " over " ++ dur ++ "s");
			~sweepRout = Routine {
				var t = 0;
				nL.do { |i|
					~laneMorph[i] = from;
					~laneMorphSynth[i] !? { ~laneMorphSynth[i]
						.set(\morphlag, 0, \morph, from) };
				};
				0.05.wait;    // let the jump land before the ramp starts
				nL.do { |i|
					~laneMorphSynth[i] !? { ~laneMorphSynth[i]
						.set(\morphlag, dur, \morph, to) };
				};
				while { t < dur } {
					var cur = (from + (t / dur * (to - from))).clip(0, 10);
					nL.do { |i| ~laneMorph[i] = cur };
					~midiDirty = true;      // 2 Hz mirror repaints the sliders
					1.wait;
					t = t + 1;
				};
				nL.do { |i| ~setMorph.(i, to, true) };
				~status.("sweep done");
				~sweepRout = nil;
			}.play(AppClock);
		};
	};

	// start/stop every lane that has outputs. One server bundle so the lanes
	// begin sample-locked rather than drifting apart by a few ms each.
	~playAllLanes = { |on|
		if (on) {
			s.bind {
				nL.do { |i|
					if (~laneSlotBufs[i].notNil and: { ~laneMorphSynth[i].isNil }) {
						~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol,
							~morphArgs.(i));
					};
				};
			};
		} {
			nL.do { |i|
				~laneMorphSynth[i] !? { ~laneMorphSynth[i].free; ~laneMorphSynth[i] = nil };
			};
		};
		{ nL.do { |i|
			~lanePlayBtns[i].value =
				if (on and: { ~laneSlotBufs[i].notNil }) { 1 } { 0 };
		} }.defer;
	};

	~sweepDurBox = NumberBox().clipLo_(0.5).clipHi_(600).step_(1).scroll_step_(1)
	.decimals_(0).value_(20).fixedWidth_(48);

	// One lane at a time: the strips select, this shows that lane's settings.
	// Global actions live on the transport block of the surface below.
	// Four settings columns, each the width of a strip and offset by the
	// transport block, so every column sits directly above its own lane.
	~feTab = View().layout_(
		HLayout(
			View().fixedWidth_(~transportW).layout_(VLayout(
				StaticText().string_("FLOWEDIT MORPH")
					.font_(Font.default.boldVariant).fixedHeight_(16),
				StaticText().string_("pool: "
					++ ~srServerPool.collect(_.name).join(" + ")).fixedHeight_(16),
				nil)),
			*~feLaneRows ++ [nil]
		)
	);

	// ----- tab 2: concatenator -----
	~ccLaneRows = nL.collect { |i|
		// default to a corpus that actually has audio. "session: lane" is
		// empty until a corpus-rec pass has happened, and pointing at an
		// empty folder is the single most common way this tab fails.
		~laneCorpusMenus[i] = PopUpMenu().items_(~corpusChoices.collect(_.name))
		.fixedWidth_(150).value_(~defaultCorpusIdx);
		~laneTargetMenus[i] = PopUpMenu().items_(~ccTargetChoices.collect(_.name))
		.fixedWidth_(170).value_(~defaultTargetIdx);
		~laneShimTexts[i] = StaticText().string_("shim not running").fixedWidth_(170);
		~laneTempBoxes[i] = NumberBox().clipLo_(1).clipHi_(500).step_(5)
		.scroll_step_(5).decimals_(0).value_(~laneTemp[i]).fixedWidth_(52)
		.action_({ |nb| ~laneTemp[i] = nb.value;
			if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/temperature", ~laneTemp[i]) } });
		~laneGrainBoxes[i] = NumberBox().clipLo_(0).clipHi_(30).step_(0.05)
		.scroll_step_(0.05).decimals_(2).value_(~laneGrain[i]).fixedWidth_(52)
		.action_({ |nb| ~setLaneGrain.(i, nb.value); ~surfRefresh.value });
		~laneWetBoxes[i] = NumberBox().clipLo_(0).clipHi_(1).step_(0.05)
		.scroll_step_(0.05).decimals_(2).value_(1).fixedWidth_(52)
		.action_({ |nb| ~laneWet[i] = nb.value;
			if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/wet", ~laneWet[i]) } });
		HLayout(
			StaticText().string_((i + 1).asString).fixedWidth_(14)
				.font_(Font.default.boldVariant),
			StaticText().string_("of").fixedWidth_(16),
			~laneCorpusMenus[i],
			StaticText().string_("shaped like").fixedWidth_(68),
			~laneTargetMenus[i],
			Button().states_([["...", Color.black, Color.white]])
			.fixedWidth_(28).action_({
				Dialog.openPanel(path: ~srCcRoot +/+ "targets", okFunc: { |path|
					~laneCustomTarget[i] = path;
					{
						~laneTargetMenus[i].items = ~ccTargetChoices.collect(_.name)
							.put(~ccTargetChoices.size - 1, path.basename);
						~laneTargetMenus[i].value = ~ccTargetChoices.size - 1;
					}.defer;
					~status.("lane " ++ (i + 1) ++ " target: " ++ path.basename);
				});
			}),
			Button().states_([["start shim", Color.black, Color.white]])
			.fixedWidth_(80).action_({ ~startShim.(i) }),
			// LIVE = stream the take through the filter now, knobs active.
			// The bounce pair below is a separate, optional path.
			Button().states_([["▶ LIVE", Color.white, Color.green(0.4)]])
			.fixedWidth_(72).action_({ ~shimPlay.(i) }),
			Button().states_([["stop", Color.black, Color.white]])
			.fixedWidth_(44).action_({
				if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/stop") } }),
			StaticText().string_("|").fixedWidth_(8),
			Button().states_([["bounce to file", Color.black, Color.white]])
			.fixedWidth_(100).action_({ ~shimRender.(i, nil) }),
			Button().states_([["play bounce", Color.black, Color.white],
				["stop bounce", Color.white, Color.green(0.5)]])
			.fixedWidth_(90).action_({ |b|
				if (b.value == 1) {
					if (~laneRenderBuf[i].notNil) {
						~laneRenderSynth[i] = Synth(\srFilePlay, [\buf, ~laneRenderBuf[i], \lane, i,
							\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
					} { b.value = 0 };
				} { ~laneRenderSynth[i] !? { ~laneRenderSynth[i].free;
					~laneRenderSynth[i] = nil } };
			}),
			StaticText().string_("temp").fixedWidth_(32), ~laneTempBoxes[i],
			StaticText().string_("grain s").fixedWidth_(44), ~laneGrainBoxes[i],
			StaticText().string_("wet").fixedWidth_(26), ~laneWetBoxes[i],
			~laneShimTexts[i], nil)
	};

	~ccTab = View().layout_(VLayout(
		HLayout(
			Button().states_([["start all shims", Color.black, Color.white]])
			.fixedWidth_(110).action_({ nL.do { |i| ~startShim.(i) } }),
			Button().states_([["▶ PLAY ALL", Color.white, Color.green(0.45)]])
			.fixedWidth_(90).action_({
				nL.do { |i| if (~laneShimUp[i]) { ~shimPlay.(i) } };
			}),
			Button().states_([["■ STOP ALL", Color.black, Color.white]])
			.fixedWidth_(90).action_({
				nL.do { |i| if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/stop") } };
			}),
			StaticText().string_("1. pick corpus  2. start shim (wait for 'ready')"
				++ "  3. ▶ LIVE — knobs are live, no render needed"),
			Button().states_([["QUIT ALL SHIMS", Color.black, Color.white]])
			.fixedWidth_(120).action_({ ~quitShims.value }),
			nil),
		*~ccLaneRows
	));

	// ----- tab 3: latent collage -----
	~lcLaneRows = nL.collect { |i|
		~laneLcModeMenus[i] = PopUpMenu()
		.items_(["alternate (breath-safe)", "shuffle", "reverse"])
		.fixedWidth_(150).value_(0);
		// no practical ceiling: the server decodes in VRAM-bounded sub-batches,
		// so cost is GPU time only (~0.4 s per voice per 100 s of input)
		~laneLcVoicesBoxes[i] = NumberBox().clipLo_(1).clipHi_(256).step_(1)
		.scroll_step_(1).decimals_(0).value_(3).fixedWidth_(50);
		~laneLcSeedBoxes[i] = NumberBox().step_(1).scroll_step_(1).decimals_(0)
		.value_(-1).fixedWidth_(78);
		~laneLcXfadeBoxes[i] = NumberBox().clipLo_(0).clipHi_(16).step_(1)
		.scroll_step_(1).decimals_(0).value_(2).fixedWidth_(40);
		~laneLcSilenceBoxes[i] = NumberBox().clipLo_(-90).clipHi_(0).step_(1)
		.scroll_step_(1).decimals_(0).value_(-40).fixedWidth_(46);
		~laneLcMinSegBoxes[i] = NumberBox().clipLo_(50).clipHi_(5000).step_(50)
		.scroll_step_(50).decimals_(0).value_(250).fixedWidth_(54);
		~laneLcTexts[i] = StaticText().string_("collage: --").fixedWidth_(170);
		~laneLcGenTexts[i] = StaticText().string_("morph: --").fixedWidth_(170);
		~laneLcPlayBtns[i] = Button().states_([
			["play", Color.black, Color.white],
			["stop", Color.white, Color.green(0.5)]])
		.fixedWidth_(52).action_({ |b|
			if (b.value == 1) {
				if (~laneLcBuf[i].notNil) {
					~laneLcSynth[i] = Synth(\srFilePlay2, [\buf, ~laneLcBuf[i], \lane, i,
						\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
				} { b.value = 0; ~status.("lane " ++ (i + 1) ++ ": nothing collaged") };
			} { ~laneLcSynth[i] !? { ~laneLcSynth[i].free; ~laneLcSynth[i] = nil } };
		});
		// the chain leaves the chorus in the MORPH player, so the morph has to
		// be reachable here too -- same value as tab 1, second view onto it
		~laneLcMorphSliders[i] = Slider().orientation_(\horizontal).value_(0)
		.step_(1/80).action_({ |sl| ~setMorph.(i, sl.value * 10, true) });
		~laneLcMorphBoxes[i] = NumberBox().clipLo_(0).clipHi_(10).step_(0.125)
		.scroll_step_(0.125).decimals_(2).value_(0).fixedWidth_(56)
		.action_({ |nb| ~setMorph.(i, nb.value, true) });
		View().fixedWidth_(~stripW).layout_(VLayout(
			~laneLcModeMenus[i].fixedWidth_(~stripW - 6),
			// the chain morphs with THIS lane's prompts, so they have to be
			// reachable from here too -- same window as the FlowEdit tab
			Button().states_([["prompts...", Color.black, Color.white]])
			.fixedWidth_(~stripW - 6).action_({ ~openPromptWindow.(i) }),
			HLayout(StaticText().string_("voices").fixedWidth_(52),
				~laneLcVoicesBoxes[i], nil),
			HLayout(StaticText().string_("seed").fixedWidth_(52),
				~laneLcSeedBoxes[i],
				Button().states_([["🎲", Color.black, Color.white]])
				.fixedWidth_(34).action_({ ~laneLcSeedBoxes[i].value = 100000.rand }),
				nil),
			HLayout(StaticText().string_("xfade").fixedWidth_(52),
				~laneLcXfadeBoxes[i], nil),
			HLayout(StaticText().string_("sil dB").fixedWidth_(52),
				~laneLcSilenceBoxes[i], nil),
			HLayout(StaticText().string_("min seg").fixedWidth_(52),
				~laneLcMinSegBoxes[i], nil),
			~laneLcTexts[i].fixedWidth_(~stripW - 6),
			~laneLcGenTexts[i].fixedWidth_(~stripW - 6),
			nil
		))
	};

	~lcTab = View().layout_(
		HLayout(
			View().fixedWidth_(~transportW).layout_(VLayout(
				StaticText().string_("LATENT COLLAGE")
					.font_(Font.default.boldVariant).fixedHeight_(16),
				Button().states_([["CHORUS → MORPH (armed)", Color.white,
					Color.new255(120, 70, 160)]])
				.fixedWidth_(~transportW - 8).action_({
					~chainLanes.((0..(nL - 1)).select { |i| ~laneArm[i] }) }),
				Button().states_([["check 7884", Color.black, Color.white]])
				.fixedWidth_(~transportW - 8).action_({
					("curl -s -m 3 -o /dev/null -w '%{http_code}' "
						++ (~srLcUrl ++ "/health").shellQuote).unixCmd({ |exit|
						~status.(if (exit == 0) { "7884 answered -- collage ready" }
							{ "7884 not answering -- service down" });
					});
				}),
				nil)),
			*~lcLaneRows ++ [nil]
		)
	);

	{
	// ================= set panes: wall of sound / metronomes / LatentFT =================
	// Motion-safe like the rest: every readout is a StaticText stepped at 1-2 Hz
	// by a SendReply, menus and buttons only, no drag anywhere.
	~mmss = { |secs|
		var t = secs.max(0).round.asInteger;
		(t div: 60).asString ++ ":" ++ (t % 60).asString.padLeft(2, "0");
	};
	~wavsIn = { |dir|
		if (File.exists(dir)) {
			PathName(dir).files.select { |f| f.extension == "wav" }
				.collect(_.fullPath).sort;
		} { [] };
	};
	~paneHeader = { |title, sub|
		View().fixedWidth_(~transportW).layout_(VLayout(
			StaticText().string_(title).font_(Font.default.boldVariant).fixedHeight_(16),
			StaticText().string_(sub).fixedHeight_(16),
			nil));
	};
	~paneBtn = { |label, w = 62|
		Button().states_([[label, Color.gray(0.3), Color.white]])
		.fixedWidth_(w).fixedHeight_(20);
	};
	~paneToggle = { |off, on, w = 62|
		Button().states_([
			[off, Color.gray(0.3), Color.white],
			[on, Color.black, Color.new255(90, 220, 120)]])
		.fixedWidth_(w).fixedHeight_(20);
	};

	// ---------------- wall of sound: lane 1 = bell_12min render ----------------
	~wsVersions = [];      // [label -> path]
	~wsPath = nil; ~wsDur = 720; ~wsPos = 0; ~wsSynth = nil; ~wsDiskBuf = nil;
	~wsScan = {
		~wsVersions = [];
		["A_dyads", "B_dyads+voices", "C_dyads+voices+chords"].do { |name|
			["curve", "open"].do { |shape|
				var base = ~wsRenders +/+ name ++ "_" ++ shape;
				case
				{ File.exists(base ++ ".wav") } {
					~wsVersions = ~wsVersions.add((name ++ " " ++ shape) -> (base ++ ".wav")) }
				{ File.exists(base ++ ".mp3") } {
					~wsVersions = ~wsVersions.add((name ++ " " ++ shape ++ " (mp3)")
						-> (base ++ ".mp3")) };
			};
		};
		~wsMenu !? { |m|
			var keep = m.value;
			m.items = ~wsVersions.collect(_.key);
			if (~wsVersions.notEmpty) {
				m.value = keep.clip(0, ~wsVersions.size - 1);
				~wsPath = ~wsVersions[m.value].value;
			};
		};
		if (~wsVersions.notEmpty and: { ~wsPath.isNil }) { ~wsPath = ~wsVersions[0].value };
	};
	~wsReadoutSet = { |str| { ~wsReadout !? { ~wsReadout.string = str } }.defer };
	~wsPlay = { |on|
		if (on) {
			if (~wsSynth.isNil and: { ~wsPath.notNil }) {
				var sf = SoundFile.openRead(~wsPath);
				if (sf.isNil) {
					~status.("wall: cannot open " ++ ~wsPath.basename);
				} {
					var fileSR = sf.sampleRate;
					~wsDur = sf.numFrames / fileSR;
					sf.close;
					~wsPos = ~wsPos.clip(0, ~wsDur - 1);
					fork {
						var startPos = ~wsPos;
						~wsDiskBuf = Buffer.cueSoundFile(s, ~wsPath,
							(startPos * fileSR).asInteger, 2, 131072);
						s.sync;
						~wsSynth = Synth(\srDisk, [\buf, ~wsDiskBuf,
							\rate, fileSR / s.sampleRate, \start, startPos, \dur, ~wsDur,
							\amp, ~effLevel.(~wsLane), \pan, ~lanePan[~wsLane],
							\out, ~srOutBus, \lane, ~wsLane]);
						~wsSynth.onFree {
							var b = ~wsDiskBuf;
							~wsSynth = nil;
							~wsDiskBuf = nil;
							b !? { b.close; b.free };
							// ran off the end: next play starts over
							if (~wsPos >= (~wsDur - 1.5)) { ~wsPos = 0 };
							~wsReadoutSet.(~mmss.(~wsPos) ++ " / " ++ ~mmss.(~wsDur) ++ "  stopped");
							~surfRefresh.value;
						};
						~status.("wall: " ++ ~wsPath.basename ++ " from " ++ ~mmss.(startPos)
							++ " (" ++ fileSR ++ " Hz file, rate " ++ (fileSR / s.sampleRate) ++ ")");
					};
				};
			};
		} {
			~wsSynth !? { ~wsSynth.free };   // onFree does the bookkeeping
		};
		~surfRefresh.value;
	};
	~wsLocate = { |secs|
		var was = ~wsSynth.notNil;
		~wsPos = secs.clip(0, ~wsDur - 1);
		if (was) { ~wsSynth.free; { ~wsPlay.(true) }.defer(0.1) }
		{ ~wsReadoutSet.(~mmss.(~wsPos) ++ " / " ++ ~mmss.(~wsDur) ++ "  cued") };
	};
	OSCdef(\srWsPos, { |msg|
		~wsPos = msg[3];
		~wsReadoutSet.(~mmss.(~wsPos) ++ " / " ++ ~mmss.(~wsDur) ++ "  playing");
	}, '/srWsPos');

	// ---------------- wall of sound: lane 2 = live dyads ----------------
	// Mirrors compose.py by hand: one stem per event, apex envelope peaking
	// at a gaussian-drawn point (mean 0.5, sigma 0.125, clipped 0.25-0.75),
	// random azimuth, random gain 0 to -6 dB. Stem choice is a Tenney-style
	// dissonant-counterpoint draw: the longer since a stem was used, the
	// likelier it is (weight = age^2), so the same dyad never comes twice.
	~dyadBufs = Array.newClear(24);
	~dyadGroup = Group(s);
	~dyadAuto = nil;
	~dyadDensity = 0.5;          // fader position 0..1
	~dyadIvalFor = { |v| 60 * ((2 / 60) ** v.clip(0, 1)) };   // 60 s .. 2 s mean gap
	~dyadCount = 0;
	~dyadFired = nil ! 24;       // event index when stem k was last fired
	~dyadLast = nil;
	~dyadLoaded = 0;
	~dyadLoad = {
		var paths = ~wavsIn.(~wsStems);
		~dyadLoaded = 0;
		paths.do { |p|
			var k = p.basename.splitext[0].asInteger - 1;
			if (k >= 0 and: { k < 24 } and: { ~dyadBufs[k].isNil }) {
				~dyadBufs[k] = Buffer.read(s, p, action: {
					~dyadLoaded = ~dyadLoaded + 1;
					{ ~dyadReadout !? { ~dyadReadout.string =
						"stems loaded " ++ ~dyadLoaded ++ " / " ++ paths.size } }.defer;
				});
			};
		};
		if (paths.isEmpty) { ~status.("wall: no stems found in " ++ ~wsStems) };
	};
	~dyadPick = {
		var w = 24.collect { |k|
			var age = if (~dyadFired[k].isNil) { 24 } { (~dyadCount - ~dyadFired[k]).clip(1, 24) };
			if (~dyadBufs[k].isNil) { 0 } { age.squared };
		};
		if (w.sum <= 0) { nil } { (0..23).wchoose(w.normalizeSum) };
	};
	~dyadFire = { |k|
		var buf = if (k.notNil) { ~dyadBufs[k] };
		if (buf.isNil) {
			~status.("wall: stem " ++ (k !? { |x| (x + 1).asString } ? "?") ++ " not loaded");
		} {
			var pos = 0.85.rand2;
			var gainDb = rrand(-6.0, 0.0);
			var apex = 0.5.gauss(0.125).clip(0.25, 0.75);
			Synth(\srDyad, [\buf, buf, \amp, ~effLevel.(~dyLane), \gain, gainDb.dbamp,
				\pos, pos, \apex, apex, \out, ~srOutBus, \lane, ~dyLane], ~dyadGroup);
			~dyadFired[k] = ~dyadCount;
			~dyadCount = ~dyadCount + 1;
			~dyadLast = k;
			{ ~dyadReadout !? { ~dyadReadout.string =
				"last: " ++ (k + 1).asString.padLeft(2, "0")
				++ "  pos " ++ pos.round(0.01) ++ "  " ++ gainDb.round(0.1) ++ " dB"
				++ "  apex " ++ apex.round(0.01)
				++ "  · events " ++ ~dyadCount
				++ if (~dyadAuto.notNil) { "  · AUTO ~" ++ ~dyadIvalFor.(~dyadDensity).round(0.1) ++ " s" } { "" } } }.defer;
		};
	};
	~dyadAutoSet = { |on|
		if (on) {
			if (~dyadAuto.isNil) {
				~dyadAuto = Routine {
					loop {
						~dyadFire.(~dyadPick.value);
						(~dyadIvalFor.(~dyadDensity) * exprand(0.5, 2.0)).wait;
					};
				}.play(SystemClock);
			};
		} {
			~dyadAuto !? { ~dyadAuto.stop; ~dyadAuto = nil };
		};
		{ ~dyadAutoBtn !? { ~dyadAutoBtn.value = ~dyadAuto.notNil.asInteger } }.defer;
		~surfRefresh.value;
	};
	~dyadSetDensity = { |v| ~dyadDensity = v.clip(0, 1) };
	~dyadHush = {     // let sounding dyads finish but fire no more
		~dyadAutoSet.(false);
	};
	~dyadCut = { ~dyadAutoSet.(false); ~dyadGroup.freeAll };

	{
	}.value;

	// ---------------- metronomes: lane 3 ----------------
	// Three modes. FILES = the pre-rendered Callender sweeps (exact durations,
	// end on a downbeat at 80). LIVE = a click whose tempo follows fader 3
	// inside a BPM range, with a short glide -- steer it by how the dancers
	// are doing. GLIDE = type a target BPM and a duration, GO, and the click
	// ramps there from wherever it is; re-target any time mid-ramp.
	~mtSets = [    // label -> folder (relative to metronomes/), voices below
		"speedups 30-80" -> "speedups_30-80bpm",
		"90 counts 30-80" -> "90counts_30-80bpm",
		"log-even 30-80" -> "logeven/30-80bpm",
		"log-even 30-120" -> "logeven/30-120bpm",
		"fixed tempo" -> ""
	];
	~mtVoices = ["tock", "beep"];
	~mtFiles = [];   // paths for the current set/voice
	~mtBuf = nil; ~mtSynth = nil; ~mtPath = nil;
	~mtTimes = nil; ~mtBpms = nil; ~mtBeats = nil; ~mtTotal = 0; ~mtDur = 0; ~mtPos = 0;
	~mtScan = {
		var set = ~mtSets[~mtSetMenu.value];
		var dir = if (set.value == "") { ~mtRoot }
			{ ~mtRoot +/+ set.value +/+ ~mtVoices[~mtVoiceMenu.value] };
		~mtFiles = ~wavsIn.(dir);
		~mtFileMenu.items = ~mtFiles.collect { |p| p.basename.splitext[0] };
		if (~mtFiles.notEmpty) { ~mtFileMenu.value = 0 };
		~mtReadout.string = if (~mtFiles.isEmpty) { "no files in " ++ dir.basename }
			{ ~mtFiles.size.asString ++ " files -- pick one and LOAD" };
	};
	~mtLoad = {
		var path = if (~mtFiles.notEmpty) { ~mtFiles[~mtFileMenu.value] };
		var jp;
		path !? {
			~mtStop.value;
			~mtBuf !? { ~mtBuf.free; ~mtBuf = nil };
			~mtTimes = nil; ~mtBpms = nil; ~mtBeats = nil; ~mtTotal = 0; ~mtPos = 0;
			~mtPath = path;
			jp = path.splitext[0] ++ ".beats.json";
			if (File.exists(jp)) {
				var d = File.readAllString(jp).parseJSON;
				var ev = d["events"] ? [];
				~mtTimes = ev.collect { |e| e["t"].asFloat };
				~mtBpms  = ev.collect { |e| e["bpm"].asFloat };
				~mtBeats = ev.collect { |e| e["beat"].asFloat };
				~mtTotal = (d["total_beats"] ? ev.size.asString).asInteger;
			};
			~mtBuf = Buffer.read(s, path, action: { |b|
				~mtDur = b.duration;
				{ ~mtReadout.string = path.basename.splitext[0] ++ "  " ++ ~mmss.(~mtDur)
					++ if (~mtTimes.notNil) { "  · " ++ ~mtTotal ++ " beats" } { "  (no beats.json)" }
					++ "  -- ready" }.defer;
			});
		};
	};
	~mtPlay = { |on|
		if (on) {
			~clickSet.(false);   // one metronome at a time on lane 3
			if (~mtSynth.isNil and: { ~mtBuf.notNil }) {
				~mtSynth = Synth(\srMetro, [\buf, ~mtBuf, \start, ~mtPos.clip(0, ~mtDur - 0.1),
					\amp, ~effLevel.(~mtLane), \pan, ~lanePan[~mtLane],
					\out, ~srOutBus, \lane, ~mtLane]);
				~mtSynth.onFree {
					~mtSynth = nil;
					if (~mtPos >= (~mtDur - 1)) { ~mtPos = 0 };
					{ ~mtReadout.string = ~mtReadout.string.replace("playing", "stopped");
						~mtPlayBtn !? { ~mtPlayBtn.value = 0 } }.defer;
					~surfRefresh.value;
				};
			};
			if (~mtBuf.isNil) { ~status.("metronome: LOAD a file first") };
		} {
			~mtSynth !? { ~mtSynth.free };
		};
		~surfRefresh.value;
	};
	~mtStop = { ~mtSynth !? { ~mtSynth.free } };
	~mtRewind = { var was = ~mtSynth.notNil; ~mtStop.value; ~mtPos = 0;
		if (was) { { ~mtPlay.(true) }.defer(0.1) } };
	OSCdef(\srMtPos, { |msg|
		var pos = msg[3];
		var idx, beat, bpm, str;
		~mtPos = pos;
		if (~mtTimes.notNil and: { ~mtTimes.notEmpty }) {
			idx = (~mtTimes.indexOfGreaterThan(pos) ? ~mtTimes.size) - 1;
			idx = idx.clip(0, ~mtTimes.size - 1);
			beat = ~mtBeats[idx].asInteger;
			bpm = ~mtBpms[idx];
			str = "beat " ++ beat ++ " / " ++ ~mtTotal ++ "   " ++ bpm.round(0.1) ++ " BPM   ";
		} { str = "" };
		str = str ++ ~mmss.(pos) ++ " / " ++ ~mmss.(~mtDur) ++ "  playing";
		{ ~mtReadout.string = str }.defer;
	}, '/srMtPos');

	// --- live click (LIVE and GLIDE modes share it) ---
	~clickSynth = nil;
	~clickBpm = 30;          // where the click is heading (the control value)
	~clickBpmNow = 30;       // last reported actual tempo
	~clickGlide = 1.5;       // LIVE: seconds for a fader move to settle
	~clickLo = 30; ~clickHi = 80;   // fader 3 range
	~clickVoice = 0;
	~clickCurve = 0;         // 0 linear, else exponential-ish (VarLag warp)
	~clickBeats = 0;
	~clickStarted = nil;
	~clickBpmForFader = { |v| ~clickLo + ((~clickHi - ~clickLo) * v.clip(0, 1)) };
	~clickFaderForBpm = { |b| ((b - ~clickLo) / max(~clickHi - ~clickLo, 1)).clip(0, 1) };
	~clickSet = { |on|
		if (on) {
			~mtStop.value;
			if (~clickSynth.isNil) {
				~clickSynth = Synth(\srClick, [\bpm, ~clickBpm, \glide, 0, \voice, ~clickVoice,
					\amp, ~effLevel.(~mtLane), \pan, ~lanePan[~mtLane],
					\out, ~srOutBus, \lane, ~mtLane]);
				~clickBeats = 0;
				~clickStarted = Main.elapsedTime;
			};
		} {
			~clickSynth !? { ~clickSynth.free; ~clickSynth = nil };
			~glideEnds = nil;
			{ ~clickReadout !? { ~clickReadout.string = ~clickReadout.string.replace("running", "stopped") } }.defer;
		};
		{ ~clickBtn !? { ~clickBtn.value = ~clickSynth.notNil.asInteger } }.defer;
		~surfRefresh.value;
	};
	// LIVE: the fader sets the tempo; short glide so it never jumps
	~clickSetBpm = { |bpm|
		~clickBpm = bpm.clip(20, 300).round(0.1);
		~glideEnds = nil;
		~clickSynth !? { ~clickSynth.set(\glide, ~clickGlide, \curve, 0, \bpm, ~clickBpm) };
		{ ~clickBpmBox !? { ~clickBpmBox.value = ~clickBpm } }.defer;
	};
	// GLIDE: ramp from the current tempo to a target over `secs`
	~glideEnds = nil;
	~clickGlideTo = { |target, secs|
		target = target.clip(20, 300);
		secs = secs.max(0.1);
		~clickBpm = target;
		if (~clickSynth.isNil) { ~clickSet.(true) };
		~clickSynth.set(\glide, secs, \curve, ~clickCurve, \bpm, target);
		~glideEnds = Main.elapsedTime + secs;
		{ ~clickBpmBox !? { ~clickBpmBox.value = target } }.defer;
		~status.("click: gliding " ++ ~clickBpmNow.round(0.1) ++ " -> " ++ target
			++ " BPM over " ++ secs.round(0.1) ++ " s");
	};
	~clickHold = {    // freeze the tempo where it is right now (mid-glide)
		~clickBpm = ~clickBpmNow.round(0.1);
		~glideEnds = nil;
		~clickSynth !? { ~clickSynth.set(\glide, 0, \bpm, ~clickBpm) };
		{ ~clickBpmBox !? { ~clickBpmBox.value = ~clickBpm } }.defer;
	};
	OSCdef(\srClick, { |msg|
		var left;
		~clickBeats = msg[3].asInteger;
		~clickBpmNow = msg[4];
		left = ~glideEnds !? { (~glideEnds - Main.elapsedTime).max(0) };
		{ ~clickReadout !? { ~clickReadout.string =
			"beat " ++ ~clickBeats ++ "   " ++ ~clickBpmNow.round(0.1) ++ " BPM"
			++ if (left.notNil and: { left > 0.4 }) {
				"   -> " ++ ~clickBpm ++ " in " ++ ~mmss.(left) } { "" }
			++ "   " ++ ~mmss.(Main.elapsedTime - (~clickStarted ? Main.elapsedTime))
			++ "  running" } }.defer;
	}, '/srClick');

	{
	}.value;

	// ---------------- LatentFT: lane 4 ----------------
	~lfSources = [];   // [label -> path]; index 0 is the original when found
	~lfBufs = Dictionary();
	~lfSynth = nil; ~lfPos = 0; ~lfX = 0; ~lfDur = 320; ~lfOffB = 0;
	~lfA = nil; ~lfB = nil;   // paths
	~lfScan = {
		var orig = ~lfOriginals.detect { |p| File.exists(p) };
		~lfSources = [];
		orig !? { ~lfSources = ~lfSources.add("original phantom_pain" -> orig) };
		~lfDirs.do { |assoc|
			~wavsIn.(~soRoot +/+ assoc.value).do { |p|
				~lfSources = ~lfSources.add(
					(assoc.key ++ " / " ++ p.basename.splitext[0]) -> p);
			};
		};
		[~lfAMenu, ~lfBMenu].do { |m|
			m !? {
				var keep = m.value;
				m.items = ~lfSources.collect(_.key);
				if (~lfSources.notEmpty) { m.value = keep.clip(0, ~lfSources.size - 1) };
			};
		};
		if (orig.isNil) { ~status.("latentft: original phantom_pain.wav not found") };
	};
	~lfBufFor = { |path, done|
		var b = ~lfBufs[path];
		if (b.notNil) { done.(b) } {
			~lfBufs[path] = Buffer.read(s, path, action: { |bb| done.(bb) });
		};
	};
	~lfReadoutSet = { |str| { ~lfReadout !? { ~lfReadout.string = str } }.defer };
	~lfPick = { |which, idx|
		var path = if (~lfSources.notEmpty) { ~lfSources[idx.clip(0, ~lfSources.size - 1)].value };
		path !? {
			if (which == \a) { ~lfA = path } { ~lfB = path };
			// pieces cut from 60 s into the track: line B up with the song clock
			if (which == \b) {
				~lfOffB = if (path.basename.contains("60s")) { -60 } { 0 };
				{ ~lfOffBox !? { ~lfOffBox.value = ~lfOffB } }.defer;
				~lfSynth !? { ~lfSynth.set(\offB, ~lfOffB) };
			};
			~lfReadoutSet.("loading " ++ path.basename ++ " ...");
			~lfBufFor.(path, { |b|
				~lfSynth !? { ~lfSynth.set(if (which == \a) { \bufA } { \bufB }, b) };
				~lfReadoutSet.(~mmss.(~lfPos) ++ "  " ++ path.basename.splitext[0]
					++ " ready (" ++ ~mmss.(b.duration) ++ ")");
			});
		};
	};
	~lfPlay = { |on|
		if (on) {
			var a = ~lfA !? { ~lfBufs[~lfA] };
			var b = (~lfB !? { ~lfBufs[~lfB] }) ? a;
			case
			{ ~lfSynth.notNil } { }
			{ a.isNil } { ~status.("latentft: pick source A (and let it load) first") }
			{
				~lfDur = max(a.duration, b.duration - ~lfOffB);
				~lfSynth = Synth(\srLfX, [\bufA, a, \bufB, b, \xf, ~lfX, \offB, ~lfOffB,
					\start, ~lfPos.clip(0, ~lfDur - 0.1), \dur, ~lfDur,
					\amp, ~effLevel.(~lfLane), \pan, ~lanePan[~lfLane],
					\out, ~srOutBus, \lane, ~lfLane]);
				~lfSynth.onFree {
					~lfSynth = nil;
					if (~lfPos >= (~lfDur - 1.5)) { ~lfPos = 0 };
					~lfReadoutSet.(~mmss.(~lfPos) ++ " / " ++ ~mmss.(~lfDur) ++ "  stopped");
					~surfRefresh.value;
				};
			};
		} {
			~lfSynth !? { ~lfSynth.free };
		};
		~surfRefresh.value;
	};
	~lfLocate = { |secs|
		var was = ~lfSynth.notNil;
		~lfPos = secs.max(0);
		if (was) { ~lfSynth.free; { ~lfPlay.(true) }.defer(0.1) }
		{ ~lfReadoutSet.(~mmss.(~lfPos) ++ "  cued") };
	};
	~lfSetX = { |v, fromGui = false|
		~lfX = v.clip(0, 1);
		~lfSynth !? { ~lfSynth.set(\xf, ~lfX) };
		{
			~lfXSlider !? { ~lfXSlider.value = ~lfX };
			~lfXBox !? { ~lfXBox.value = ~lfX.round(0.01) };
		}.defer;
	};
	OSCdef(\srLfPos, { |msg|
		~lfPos = msg[3];
		~lfReadoutSet.(~mmss.(~lfPos) ++ " / " ++ ~mmss.(~lfDur)
			++ "   A " ++ (1 - ~lfX).round(0.01) ++ " · B " ++ ~lfX.round(0.01) ++ "  playing");
	}, '/srLfPos');
	// section cues from the arch map (macro sections, letter + ordinal)
	~lfSections = [];
	if (File.exists(~lfFormFile)) {
		var d = File.readAllString(~lfFormFile).parseJSON;
		(d["macro"] ? []).do { |m|
			var letter = m["letter"] ? "";
			var role = (m["role"] ? "").asString;
			var label = case
				{ letter != "" } { letter ++ (m["ordinal"] ? "") }
				{ role == "intro" } { "in" }
				{ role == "outro" } { "out" }
				{ (m["text"] ? role).asString.keep(4) };
			~lfSections = ~lfSections.add(label -> m["t_start"].asFloat);
		};
	};

	// everything the pane players own -- the transport STOP and the window
	// close both go through here
	~panePlaying = { |i|
		case
		{ i == ~wsLane } { ~wsSynth.notNil }
		{ i == ~dyLane } { ~dyadAuto.notNil }
		{ i == ~mtLane } { ~mtSynth.notNil or: { ~clickSynth.notNil } }
		{ i == ~lfLane } { ~lfSynth.notNil }
		{ false };
	};
	~paneStop = { |i|
		case
		{ i == ~wsLane } { ~wsPlay.(false) }
		{ i == ~dyLane } { ~dyadAutoSet.(false) }
		{ i == ~mtLane } { ~mtStop.value; ~clickSet.(false) }
		{ i == ~lfLane } { ~lfPlay.(false) };
	};
	~paneStart = { |i|
		case
		{ i == ~wsLane } { ~wsPlay.(true) }
		{ i == ~dyLane } { ~dyadAutoSet.(true) }
		{ i == ~mtLane } { if (~mtBuf.notNil) { ~mtPlay.(true) } { ~clickSet.(true) } }
		{ i == ~lfLane } { ~lfPlay.(true) };
	};
	~panesStopAll = { 4.do { |i| ~paneStop.(i) } };
	~paneApplyMix = { |i|
		case
		{ i == ~wsLane } { ~wsSynth !? { ~wsSynth.set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) } }
		{ i == ~dyLane } { ~dyadGroup.set(\amp, ~effLevel.(i)) }
		{ i == ~mtLane } {
			~mtSynth !? { ~mtSynth.set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) };
			~clickSynth !? { ~clickSynth.set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) } }
		{ i == ~lfLane } { ~lfSynth !? { ~lfSynth.set(\amp, ~effLevel.(i), \pan, ~lanePan[i]) } };
	};

	{
	}.value;

	// ----- tab 4: wall of sound -----
	~wsScan.value;
	~wsMenu = PopUpMenu().items_(~wsVersions.collect(_.key)).fixedWidth_(~stripW - 8)
	.action_({ |m|
		var was = ~wsSynth.notNil;
		~wsPath = ~wsVersions[m.value].value;
		if (was) { ~wsLocate.(~wsPos) };
	});
	~wsPlayBtn = ~paneToggle.("play", "pause").action_({ |b| ~wsPlay.(b.value == 1) });
	~wsLocBox = NumberBox().clipLo_(0).clipHi_(720).step_(10).scroll_step_(10)
	.decimals_(0).value_(0).fixedWidth_(56);
	~wsReadout = StaticText().string_("0:00 / 12:00").fixedHeight_(16);
	~wsCol = View().fixedWidth_(~stripW).layout_(VLayout(
		StaticText().string_("lane 1 · render").font_(Font.default.boldVariant).fixedHeight_(16),
		~wsMenu,
		HLayout(~wsPlayBtn, ~paneBtn.("|◀", 30).action_({ ~wsLocate.(0) }),
			~paneBtn.("rescan", 54).action_({ ~wsScan.value; ~status.("wall: rescanned renders") })),
		HLayout(StaticText().string_("go to s").fixedWidth_(46), ~wsLocBox,
			~paneBtn.("go", 34).action_({ ~wsLocate.(~wsLocBox.value) })),
		~wsReadout,
		StaticText().string_("mp3 = 48 kHz stand-in until the\n96 kHz wav lands; rescan then.")
			.fixedHeight_(30),
		nil
	).spacing_(3));
	~dyadBtns = 24.collect { |k|
		Button().states_([[(k + 1).asString.padLeft(2, "0"), Color.gray(0.3), Color.white]])
		.fixedWidth_(46).fixedHeight_(22).action_({ ~dyadFire.(k) });
	};
	~dyadAutoBtn = ~paneToggle.("AUTO", "AUTO", 62).action_({ |b| ~dyadAutoSet.(b.value == 1) });
	~dyadReadout = StaticText().string_(if (~wsLoadStems) { "loading stems..." } { "stems not loaded" })
	.fixedHeight_(16);
	~dyadCol = View().layout_(VLayout(
		StaticText().string_("lane 2 · live dyads  (fader 2 = density; apex envelope, random azimuth)")
			.font_(Font.default.boldVariant).fixedHeight_(16),
		HLayout(*(~dyadBtns[0..7]) ++ [nil]).spacing_(3),
		HLayout(*(~dyadBtns[8..15]) ++ [nil]).spacing_(3),
		HLayout(*(~dyadBtns[16..23]) ++ [nil]).spacing_(3),
		HLayout(~dyadAutoBtn,
			~paneBtn.("cut all", 62).action_({ ~dyadCut.value }),
			~paneBtn.("load stems", 80).action_({ ~dyadLoad.value }), nil),
		~dyadReadout,
		nil
	).spacing_(4));
	~wsTab = View().layout_(HLayout(
		~paneHeader.("WALL OF SOUND", "bell_12min + live dyads"),
		~wsCol, ~dyadCol, nil));

	{
	}.value;

	// ----- tab 5: metronomes -----
	~mtSetMenu = PopUpMenu().items_(~mtSets.collect(_.key)).fixedWidth_(130)
	.action_({ ~mtScan.value });
	~mtVoiceMenu = PopUpMenu().items_(~mtVoices).fixedWidth_(70).action_({ ~mtScan.value });
	~mtFileMenu = PopUpMenu().items_([]).fixedWidth_(300);
	~mtReadout = StaticText().string_("pick a set, voice and file, then LOAD")
	.font_(Font.default.boldVariant).fixedHeight_(18);
	~mtPlayBtn = ~paneToggle.("play", "stop", 62).action_({ |b| ~mtPlay.(b.value == 1) });
	// live click controls
	~clickBpmBox = NumberBox().clipLo_(20).clipHi_(300).step_(1).scroll_step_(1)
	.decimals_(1).value_(~clickBpm).fixedWidth_(60)
	.action_({ |nb| ~clickSetBpm.(nb.value) });
	~clickLoBox = NumberBox().clipLo_(20).clipHi_(300).step_(1).scroll_step_(1)
	.decimals_(0).value_(~clickLo).fixedWidth_(48)
	.action_({ |nb| ~clickLo = nb.value; ~surfRefresh.value });
	~clickHiBox = NumberBox().clipLo_(20).clipHi_(300).step_(1).scroll_step_(1)
	.decimals_(0).value_(~clickHi).fixedWidth_(48)
	.action_({ |nb| ~clickHi = nb.value; ~surfRefresh.value });
	~clickGlideBox = NumberBox().clipLo_(0).clipHi_(30).step_(0.5).scroll_step_(0.5)
	.decimals_(1).value_(~clickGlide).fixedWidth_(48)
	.action_({ |nb| ~clickGlide = nb.value });
	~clickVoiceMenu = PopUpMenu().items_(~mtVoices).fixedWidth_(70)
	.action_({ |m| ~clickVoice = m.value; ~clickSynth !? { ~clickSynth.set(\voice, m.value) } });
	~clickBtn = ~paneToggle.("click", "click", 62).action_({ |b| ~clickSet.(b.value == 1) });
	~glideTargetBox = NumberBox().clipLo_(20).clipHi_(300).step_(1).scroll_step_(1)
	.decimals_(0).value_(80).fixedWidth_(52);
	~glideSecsBox = NumberBox().clipLo_(1).clipHi_(1200).step_(5).scroll_step_(5)
	.decimals_(0).value_(120).fixedWidth_(52);
	~glideCurveMenu = PopUpMenu().items_(["linear", "exp"]).fixedWidth_(64)
	.action_({ |m| ~clickCurve = if (m.value == 0) { 0 } { 3 } });
	~clickReadout = StaticText().string_("click stopped").font_(Font.default.boldVariant)
	.fixedHeight_(18);
	~mtTab = View().layout_(HLayout(
		~paneHeader.("METRONOMES", "lane 3 · files / live / glide"),
		View().layout_(VLayout(
			StaticText().string_("FILES -- pre-rendered Callender sweeps (exact, end on a downbeat)")
				.font_(Font.default.boldVariant).fixedHeight_(16),
			HLayout(StaticText().string_("set").fixedWidth_(30), ~mtSetMenu,
				StaticText().string_("voice").fixedWidth_(36), ~mtVoiceMenu,
				~paneBtn.("rescan", 54).action_({ ~mtScan.value }), nil),
			HLayout(StaticText().string_("file").fixedWidth_(30), ~mtFileMenu,
				~paneBtn.("LOAD", 54).action_({ ~mtLoad.value }),
				~mtPlayBtn, ~paneBtn.("|◀", 30).action_({ ~mtRewind.value }), nil),
			~mtReadout,
			StaticText().string_("").fixedHeight_(6),
			StaticText().string_("LIVE -- fader 3 steers the tempo inside the range; glide = settle time")
				.font_(Font.default.boldVariant).fixedHeight_(16),
			HLayout(~clickBtn, StaticText().string_("voice").fixedWidth_(36), ~clickVoiceMenu,
				StaticText().string_("BPM").fixedWidth_(28), ~clickBpmBox,
				StaticText().string_("range").fixedWidth_(38), ~clickLoBox,
				StaticText().string_("-").fixedWidth_(8), ~clickHiBox,
				StaticText().string_("glide s").fixedWidth_(44), ~clickGlideBox, nil),
			StaticText().string_("GLIDE -- ramp from the current tempo to a target; GO again to re-target mid-ramp")
				.font_(Font.default.boldVariant).fixedHeight_(16),
			HLayout(StaticText().string_("to").fixedWidth_(20), ~glideTargetBox,
				StaticText().string_("BPM in").fixedWidth_(42), ~glideSecsBox,
				StaticText().string_("s").fixedWidth_(10), ~glideCurveMenu,
				~paneBtn.("GO", 44).action_({
					~clickGlideTo.(~glideTargetBox.value, ~glideSecsBox.value) }),
				~paneBtn.("HOLD", 44).action_({ ~clickHold.value }),
				~paneBtn.("30→80 / 3:00", 84).action_({
					~clickSetBpm.(30); ~clickSet.(true); ~clickGlideTo.(80, 180) }),
				nil),
			~clickReadout,
			nil
		).spacing_(4)),
		nil));
	~mtScan.value;

	{
	}.value;

	// ----- tab 6: LatentFT -----
	~lfScan.value;
	~lfAMenu = PopUpMenu().items_(~lfSources.collect(_.key)).fixedWidth_(360)
	.action_({ |m| ~lfPick.(\a, m.value) });
	~lfBMenu = PopUpMenu().items_(~lfSources.collect(_.key)).fixedWidth_(360)
	.action_({ |m| ~lfPick.(\b, m.value) });
	~lfOffBox = NumberBox().clipLo_(-400).clipHi_(400).step_(1).scroll_step_(1)
	.decimals_(1).value_(0).fixedWidth_(56)
	.action_({ |nb| ~lfOffB = nb.value; ~lfSynth !? { ~lfSynth.set(\offB, ~lfOffB) } });
	~lfXSlider = Slider().orientation_(\horizontal).fixedWidth_(300).fixedHeight_(20)
	.step_(1/100).value_(0).action_({ |sl| ~lfSetX.(sl.value, true) });
	~lfXBox = NumberBox().clipLo_(0).clipHi_(1).step_(0.05).scroll_step_(0.05)
	.decimals_(2).value_(0).fixedWidth_(50).action_({ |nb| ~lfSetX.(nb.value, true) });
	~lfLocBox = NumberBox().clipLo_(0).clipHi_(400).step_(5).scroll_step_(5)
	.decimals_(0).value_(0).fixedWidth_(56);
	~lfPlayBtn = ~paneToggle.("play", "stop", 62).action_({ |b| ~lfPlay.(b.value == 1) });
	~lfReadout = StaticText().string_("pick A and B (they load on selection)")
	.font_(Font.default.boldVariant).fixedHeight_(18);
	~lfCueBtns = ~lfSections.collect { |sec|
		~paneBtn.(sec.key, 44).action_({ ~lfLocate.(sec.value) });
	};
	~lfTab = View().layout_(HLayout(
		~paneHeader.("LATENTFT", "lane 4 · sample-locked A/B"),
		View().layout_(VLayout(
			HLayout(StaticText().string_("A").fixedWidth_(16), ~lfAMenu, nil),
			HLayout(StaticText().string_("B").fixedWidth_(16), ~lfBMenu,
				StaticText().string_("B offset s").fixedWidth_(60), ~lfOffBox, nil),
			HLayout(StaticText().string_("A ⟷ B").fixedWidth_(44), ~lfXSlider, ~lfXBox,
				StaticText().string_("(fader 4)").fixedWidth_(60), nil),
			HLayout(~lfPlayBtn, ~paneBtn.("|◀", 30).action_({ ~lfLocate.(0) }),
				StaticText().string_("go to s").fixedWidth_(46), ~lfLocBox,
				~paneBtn.("go", 34).action_({ ~lfLocate.(~lfLocBox.value) }),
				~paneBtn.("rescan", 54).action_({ ~lfScan.value }), nil),
			HLayout(StaticText().string_("cue").fixedWidth_(30), *~lfCueBtns ++ [nil]).spacing_(3),
			~lfReadout,
			nil
		).spacing_(4)),
		nil));
	// default A = original, B = the reconstruct if present
	if (~lfSources.notEmpty) {
		var bIdx = ~lfSources.detectIndex { |a| a.value.basename.contains("reconstruct_fullsong") } ? 0;
		~lfAMenu.value = 0; ~lfPick.(\a, 0);
		~lfBMenu.value = bIdx; ~lfPick.(\b, bIdx);
	};
	if (~wsLoadStems) { ~dyadLoad.value };

	}.value;

	// ----- control surface: the nanoKONTROL2 IS the interface -----
	// Four strips, the hardware's own geometry, one per lane: knob on top,
	// vertical fader under it, S/M/R beneath. The transport block on the left
	// carries the global actions and LIGHTS UP to show state. Clicking a strip
	// selects that lane; the panel above shows the selected lane's settings.
	~selLane = 0;
	~surfKnobs = Array.newClear(4);
	~surfFaders = Array.newClear(4);
	~surfKnobTexts = Array.newClear(4);
	~surfFaderTexts = Array.newClear(4);
	~surfFaderLabels = Array.newClear(4);
	~surfPanBoxes = Array.newClear(4);
	~surfPlayBtns = Array.newClear(4);
	~surfCollageBtns = Array.newClear(4);
	~surfMorphBtns = Array.newClear(4);
	~surfSelBtns = Array.newClear(4);

	// Average grain length for the concatenator fader. pd alone does NOT
	// change it: continuity in the OUTPUT comes from a diagonal look-back
	// that caps segments regardless of pd, so a pd-only knob feels dead.
	// Drive both, exponentially -- 20 ms (about one frame) up to 5 s.
	~grainFor = { |v| 0.02 * ((5.0 / 0.02) ** v.clip(0, 1)) };
	~grainToFader = { |g| ((g / 0.02).log / (5.0 / 0.02).log).clip(0, 1) };
	// Temperature has to come along, and NOT monotonically. Measured at 5 s
	// grain: temp 50 -> flux 123, temp 15 -> 98, temp 5 -> 134. Too high and
	// resampling severs continuity; too low and the filter wanders. 15 is the
	// floor, not 5. Short grain keeps the sharper default.
	~tempForGrain = { |v| 50 * ((15 / 50) ** v.clip(0, 1)) };
	~grainWarnAt = 0;
	~setLaneGrain = { |i, g|
		var temp = ~tempForGrain.(~grainToFader.(g));
		~laneGrain[i] = g;
		~laneTemp[i] = temp.round(1);
		if (~laneShimUp[i]) {
			~shimAddr.(i).sendMsg("/graintime", g);
			~shimAddr.(i).sendMsg("/diaglen", g);
			~shimAddr.(i).sendMsg("/temperature", ~laneTemp[i]);
		} {
			// silently storing the value is how this reads as a dead fader
			if ((Main.elapsedTime - ~grainWarnAt) > 2) {
				~grainWarnAt = Main.elapsedTime;
				~status.("lane " ++ (i + 1) ++ ": grain " ++ g.round(0.01)
					++ "s stored -- no shim running, so nothing to hear yet");
			};
		};
	};

	// faders 1-4 mean something different per tab. On the set panes only the
	// pane's own lane has a fader parameter; the others read "--" and do nothing.
	~paneFaderOwner = { |i|
		case
		{ (~curTab == ~tabWs) and: { i == ~dyLane } } { \density }
		{ (~curTab == ~tabMt) and: { i == ~mtLane } } { \clickbpm }
		{ (~curTab == ~tabLf) and: { i == ~lfLane } } { \xfade }
		{ nil };
	};
	~surfFaderName = { |i|
		case
		{ ~curTab == ~tabCc } { "grain s" }
		{ ~curTab >= ~tabWs } {
			switch (~paneFaderOwner.(i),
				\density, { "density" }, \clickbpm, { "live BPM" }, \xfade, { "A <> B" }, { "--" })
		}
		{ "morph" };
	};
	~surfFaderVal = { |i|
		case
		{ ~curTab == ~tabCc } { ~grainToFader.(~laneGrain[i]) }
		{ ~curTab >= ~tabWs } {
			switch (~paneFaderOwner.(i),
				\density, { ~dyadDensity },
				\clickbpm, { ~clickFaderForBpm.(~clickBpm) },
				\xfade, { ~lfX }, { 0 })
		}
		{ ~laneMorph[i] / 10 };
	};
	~surfFaderText = { |i|
		case
		{ ~curTab == ~tabCc } { ~laneGrain[i].round(0.01).asString }
		{ ~curTab >= ~tabWs } {
			switch (~paneFaderOwner.(i),
				\density, { "~" ++ ~dyadIvalFor.(~dyadDensity).round(0.1) ++ " s" },
				\clickbpm, { ~clickBpm.round(0.1).asString },
				\xfade, { ~lfX.round(0.01).asString }, { "--" })
		}
		{ ~laneMorph[i].round(0.1).asString };
	};
	// one entry point for the on-screen fader AND the MIDI fader
	~surfFaderSet = { |i, v, fromGui = false|
		case
		{ ~curTab == ~tabCc } {
			~setLaneGrain.(i, ~grainFor.(v));
			if (fromGui) { ~surfRefresh.value } { ~midiDirty = true };
		}
		{ ~curTab >= ~tabWs } {
			switch (~paneFaderOwner.(i),
				\density, { ~dyadSetDensity.(v) },
				\clickbpm, { ~clickSetBpm.(~clickBpmForFader.(v)) },
				\xfade, { ~lfSetX.(v, fromGui) });
			if (fromGui) { ~surfRefresh.value } { ~midiDirty = true };
		}
		{ ~setMorph.(i, v * 10, fromGui) };
	};

	// one selection drives every tab's settings panel, so switching tabs keeps
	// showing the same lane you were working on
	~setSelLane = { |i|
		~selLane = i;
		{
		}.defer;
		~surfRefresh.value;
	};

	~lanePlaying = { |i|
		~laneMorphSynth[i].notNil or: { ~laneLcSynth[i].notNil }
			or: { ~laneRenderSynth[i].notNil } or: { ~panePlaying.(i) };
	};

	// play means "hear this lane" -- what that is depends on the tab:
	// the morph player, the collage bounce, or the live concatenator
	~laneTogglePlay = { |i|
		if (~lanePlaying.(i)) {
			~laneMorphSynth[i] !? { ~laneMorphSynth[i].free; ~laneMorphSynth[i] = nil };
			~laneLcSynth[i] !? { ~laneLcSynth[i].free; ~laneLcSynth[i] = nil };
			~laneRenderSynth[i] !? { ~laneRenderSynth[i].free;
				~laneRenderSynth[i] = nil };
			if (~curTab == ~tabCc and: { ~laneShimUp[i] }) {
			~shimAddr.(i).sendMsg("/stop") };
			~paneStop.(i);
		} {
			case
			{ ~curTab >= ~tabWs } { ~paneStart.(i) }
			{ ~curTab == ~tabCc } { ~shimPlay.(i) }
			{ (~curTab == ~tabLc) and: { ~laneLcBuf[i].notNil }
				and: { ~laneSlotBufs[i].isNil } } {
				~laneLcSynth[i] = Synth(\srFilePlay2, [\buf, ~laneLcBuf[i], \lane, i,
					\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
			}
			{ ~laneSlotBufs[i].notNil } {
				~laneMorphSynth[i] = Synth(("srMorphL" ++ i).asSymbol, ~morphArgs.(i));
			}
			{ ~laneLcBuf[i].notNil } {
				~laneLcSynth[i] = Synth(\srFilePlay2, [\buf, ~laneLcBuf[i], \lane, i,
					\amp, ~effLevel.(i), \pan, ~lanePan[i], \out, ~srOutBus]);
			}
			{ ~status.("lane " ++ (i + 1) ++ ": nothing rendered yet") };
		};
		~surfRefresh.value;
	};

	~surfRefresh = {
		{
			var anyPlaying = ~laneMorphSynth.any(_.notNil)
				or: { ~laneLcSynth.any(_.notNil) } or: { (0..3).any { |i| ~panePlaying.(i) } };
			var busy = ~genRunning or: { ~lcRunning } or: { ~chainRunning };
			4.do { |i|
				~surfKnobs[i].value = ~laneLevel[i];
				~surfKnobTexts[i].string =
					(~laneLevel[i] * 100).round.asInteger.asString;
				~surfFaders[i].value = ~surfFaderVal.(i);
				~surfFaderTexts[i].string = ~surfFaderText.(i);
				~surfFaderLabels[i].string = ~surfFaderName.(i);
				~surfPanBoxes[i].value = ~lanePan[i].round(0.01);
				~surfPlayBtns[i].value = ~lanePlaying.(i).asInteger;
				~surfCollageBtns[i].value = (~lcRunning or: { ~chainRunning })
					.asInteger;
				~surfSelBtns[i].value = (i == ~selLane).asInteger;
				~surfMorphBtns[i].value = (~genRunning or: { ~chainRunning })
					.asInteger;
			};
			// transport lamps
			~tPlayBtn !? { ~tPlayBtn.value = anyPlaying.asInteger };
			~tRecBtn  !? { ~tRecBtn.value = busy.asInteger };
			~tCycleBtn !? { ~tCycleBtn.value = (~sweepRout.notNil).asInteger };
		}.defer;
	};

	// --- the four lane strips ---
	~surfStrips = 4.collect { |i|
		~surfSelBtns[i] = Button().states_([
			["lane " ++ (i + 1), Color.gray(0.3), Color.white],
			["lane " ++ (i + 1), Color.black, Color.new255(120, 200, 255)]])
		.fixedWidth_(64).fixedHeight_(18)
		.action_({ ~setSelLane.(i) });
		~surfKnobs[i] = Knob().fixedWidth_(40).fixedHeight_(40).value_(0.7)
		.action_({ |kn| ~laneLevel[i] = kn.value; ~applyMix.(i); ~surfRefresh.value });
		~surfKnobTexts[i] = StaticText().string_("--").align_(\center)
		.fixedWidth_(64).fixedHeight_(14);
		~surfPanBoxes[i] = NumberBox().clipLo_(-1).clipHi_(1).step_(0.05)
		.scroll_step_(0.05).decimals_(2).value_(~lanePan[i]).fixedWidth_(56)
		.action_({ |nb| ~lanePan[i] = nb.value; ~applyMix.(i) });
		~surfFaders[i] = Slider().orientation_(\vertical)
		.fixedWidth_(30).fixedHeight_(120).step_(1/80).value_(0)
		.action_({ |sl| ~surfFaderSet.(i, sl.value, true) });
		~surfFaderLabels[i] = StaticText().string_("morph").align_(\center)
		.fixedWidth_(64).fixedHeight_(14);
		~surfFaderTexts[i] = StaticText().string_("--").align_(\center)
		.fixedWidth_(64).fixedHeight_(14);
		// the three things you do to a lane: hear it, collage it, morph it
		~surfPlayBtns[i] = Button().states_([
			["play", Color.gray(0.3), Color.white],
			["stop", Color.black, Color.new255(90, 220, 120)]])
		.fixedWidth_(62).fixedHeight_(20).action_({ ~laneTogglePlay.(i) });
		~surfCollageBtns[i] = Button().states_([
			["collage", Color.gray(0.3), Color.white],
			["collage", Color.white, Color.blue(0.6)]])
		.fixedWidth_(62).fixedHeight_(20).action_({ ~lcGenerateLanes.([i]) });
		~surfMorphBtns[i] = Button().states_([
			["morph", Color.gray(0.3), Color.white],
			["morph", Color.white, Color.new255(120, 70, 160)]])
		.fixedWidth_(62).fixedHeight_(20).action_({ ~generateLanes.([i]) });
		// hardware anatomy: knob on top, then the button column BESIDE the
		// fader (not under it) -- as drawn in the control-surface map
		View().fixedWidth_(~stripW).layout_(VLayout(
			~surfSelBtns[i],
			HLayout(nil, ~surfKnobs[i], nil).spacing_(0),
			~surfKnobTexts[i],
			HLayout(StaticText().string_("pan").fixedWidth_(24), ~surfPanBoxes[i]),
			HLayout(nil,
				VLayout(~surfPlayBtns[i], ~surfCollageBtns[i],
					~surfMorphBtns[i], nil)
					.spacing_(3),
				~surfFaders[i], nil).spacing_(5),
			~surfFaderLabels[i],
			~surfFaderTexts[i],
			// this lane's post-fader output, directly under its own fader
			StaticText().string_("out").align_(\center).fixedHeight_(12),
			HLayout(nil, ~laneOutMeterViews[i], nil).spacing_(0),
			nil
		).spacing_(2))
	};

	// --- transport block, left of the strips, like the hardware ---
	~tSmall = { |label, w = 46|
		Button().states_([[label, Color.gray(0.3), Color.white]])
		.fixedWidth_(w).fixedHeight_(22);
	};
	~tPlayBtn = Button().states_([
		["▶", Color.gray(0.3), Color.white],
		["▶", Color.black, Color.new255(90, 220, 120)]])
	.fixedWidth_(40).fixedHeight_(26).action_({ ~playAllLanes.(true) });
	~tStopBtn = Button().states_([["■", Color.gray(0.3), Color.white]])
	.fixedWidth_(40).fixedHeight_(26).action_({
		~playAllLanes.(false); ~lcPlayAll.(false); ~panesStopAll.value;
		~sweepRout !? { ~sweepRout.stop; ~sweepRout = nil };
		~surfRefresh.value;
	});
	~tRecBtn = Button().states_([
		["●", Color.gray(0.3), Color.white],
		["●", Color.white, Color.new255(215, 60, 50)]])
	.fixedWidth_(40).fixedHeight_(26).action_({
		if (~curTab == ~tabLc) {
			~lcGenerateLanes.((0..(nL - 1)).select { |i| ~laneArm[i] });
		} { ~generateLanes.((0..(nL - 1)).select { |i| ~laneArm[i] }) };
	});
	~tCycleBtn = Button().states_([
		["CYCLE", Color.gray(0.3), Color.white],
		["CYCLE", Color.black, Color.new255(120, 200, 255)]])
	.fixedWidth_(58).fixedHeight_(22)
	.action_({ ~runMorphSweep.(0, 10) });
	~tRewBtn = ~tSmall.("◀◀").action_({ ~runMorphSweep.(10, 0) });
	~tFfBtn  = ~tSmall.("▶▶").action_({ ~runMorphSweep.(0, 10) });
	~tTrkPrev = ~tSmall.("◀", 30).action_({ ~setTab.((~curTab - 1).wrap(0, ~tabBtns.size - 1)) });
	~tTrkNext = ~tSmall.("▶", 30).action_({ ~setTab.((~curTab + 1).wrap(0, ~tabBtns.size - 1)) });
	~tMarkSet = ~tSmall.("warm", 52).action_({ ~warmup.value });

	~transportBlock = VLayout(
		HLayout(StaticText().string_("TRACK").fixedWidth_(46), ~tTrkPrev, ~tTrkNext),
		HLayout(~tCycleBtn, ~tMarkSet),
		HLayout(StaticText().string_("sweep").fixedWidth_(46), ~tRewBtn, ~tFfBtn,
			~sweepDurBox),
		HLayout(~tPlayBtn, ~tStopBtn, ~tRecBtn),
		Button().states_([["CANCEL QUEUE", Color.white, Color.red(0.55)]])
			.fixedWidth_(~transportW - 8).fixedHeight_(22)
			.action_({ ~cancelAll.value }),
		StaticText().string_("▶ play all  ■ stop  ● generate all")
			.fixedHeight_(14),
		nil
	).spacing_(3);

	~surfacePanel = View().layout_(
		HLayout(
			View().fixedWidth_(~transportW).layout_(~transportBlock),
			*~surfStrips ++ [nil]).spacing_(0)
	);

	// ----- assemble -----
	~tabStack = StackLayout(~feTab, ~lcTab, ~ccTab, ~wsTab, ~mtTab, ~lfTab);
	~tabBtns = ["FLOWEDIT MORPH", "LATENT COLLAGE", "CONCATENATOR",
		"WALL OF SOUND", "METRONOMES", "LATENTFT"].collect { |name, k|
		Button().states_([[name, Color.gray(0.4), Color.white],
			[name, Color.white, Color.black]])
		.action_({ ~setTab.(k) })
	};
	~curTab = 0;   // plain mirror of ~tabStack.index -- the MIDI thread must
	               // never read a Qt property directly
	~setTab = { |k|
		~curTab = k;
		{
			~tabStack.index = k;
			~tabBtns.do { |b, j| b.value = (j == k).asInteger };
		}.defer;
		// faders 1-4 mean something different per tab; relabel and re-read
		~surfRefresh !? { ~surfRefresh.value };
	};

	// posts every incoming CC to the console -- for checking the controller's
	// map against ~srMidi without guessing
	~midiMonBtn = Button().states_([
		["midi mon", Color.black, Color.white],
		["midi mon ON", Color.white, Color.blue(0.5)]])
	.fixedWidth_(90).action_({ |b| ~midiMon = (b.value == 1) });

	// Output meters live in a column down the RIGHT of the tab area -- the
	// bottom half of the window -- so they sit beside the morph/collage rows
	// whose levels they show, and stay put across all three tabs.

	~winRows = [HLayout(~recBtn, ~recTimeText, ~corpusRecBtn, ~corpusDestMenu,
		~corpusTimeText,
		Button().states_([["save takes", Color.white, Color.blue(0.5)]])
			.fixedWidth_(86).action_({ ~saveTakes.value }),
		~midiMonBtn, nil, ~statusText)]
		++ ~captureRows
		++ [HLayout(*~tabBtns),
			~tabStack,
			[~surfacePanel, stretch: 1]];
	~win.layout = VLayout(*~winRows);
	~setTab.(~tabFe);
	~setSelLane.(0);

	// keep the transport lamps honest even when nothing is being touched
	// (play/generate finish on their own; 2 Hz, stepped, no animation)
	~lampRout = Routine {
		loop { 0.5.wait; ~surfRefresh.value };
	}.play(AppClock);

	// keyboard fallback for tab switching (1-6). Text fields swallow the
	// key while they have focus, so typing in a prompt won't switch tabs.
	~win.view.keyDownAction = { |view, char|
		case
		{ char == $1 } { ~setTab.(~tabFe) }
		{ char == $2 } { ~setTab.(~tabLc) }
		{ char == $3 } { ~setTab.(~tabCc) }
		{ char == $4 } { ~setTab.(~tabWs) }
		{ char == $5 } { ~setTab.(~tabMt) }
		{ char == $6 } { ~setTab.(~tabLf) };
	};

	// ----- meters -----
	// repaint ONLY the blocks whose state changed; a steady signal repaints
	// nothing at all, so the visual change rate is far below ~srMeterHz
	~segColor = { |k|
		var dbAt = -60 + ((k + 1) * 60 / ~srMeterSegs);
		case
		{ dbAt > -6 }  { Color(0.88, 0.27, 0.22) }
		{ dbAt > -18 } { Color(0.87, 0.68, 0.24) }
		{ Color(0.30, 0.72, 0.42) };
	};
	~paintMeter = { |segViews, lit, pk|
		segViews.do { |v, k|
			v.background = case
			{ k < lit } { ~segColor.(k) }
			{ (k + 1) == pk } { Color.gray(0.5) }     // peak hold
			{ Color.gray(0.18) };
		};
	};
	~drawMeter = { |i| ~paintMeter.(~laneMeterSegs[i],
		~laneMeterLit[i], ~laneMeterPeak[i]) };
	~drawOutMeter = { |i| ~paintMeter.(~laneOutMeterSegs[i],
		~laneOutLit[i], ~laneOutPeak[i]) };
	~ampToLit = { |amp|
		(((amp.ampdb + 60) / 60) * ~srMeterSegs).round.asInteger
			.clip(0, ~srMeterSegs);
	};

	// post-fader output levels, tagged per lane by SendReply's replyID
	OSCdef(\srOutMeters, { |msg|
		{
			var lane = msg[2].asInteger;
			var lit = ~ampToLit.(msg[3..].maxItem);
			if (lane >= 0 and: { lane < nL }) {
				~laneOutSeen[lane] = 0;
				~laneOutLit[lane] = lit;
				if (lit > ~laneOutPeak[lane]) { ~laneOutPeak[lane] = lit };
				if ((lit != ~laneOutDrawn[lane])
					or: { ~laneOutPeak[lane] != ~laneOutPeakDrawn[lane] }) {
					~laneOutDrawn[lane] = lit;
					~laneOutPeakDrawn[lane] = ~laneOutPeak[lane];
					~drawOutMeter.(lane);
				};
			};
		}.defer;
	}, '/srOutMeters');

	~meterSynth = Synth(\srMeter, [\chans, ~srLaneChans, \rate, ~srMeterHz]);
	OSCdef(\srMeters, { |msg|
		{
			// number refreshes every other frame (~2 Hz at the 4 Hz default)
			var showText = (~meterTick % (~srMeterHz / 2).max(1).round.asInteger) == 0;
			~meterTick = ~meterTick + 1;
			nL.do { |i|
				var db = msg[3 + i].ampdb;
				var lit = (((db + 60) / 60) * ~srMeterSegs).round.asInteger
					.clip(0, ~srMeterSegs);
				~laneMeterLit[i] = lit;
				if (lit > ~laneMeterPeak[i]) { ~laneMeterPeak[i] = lit };
				if ((lit != ~laneMeterDrawn[i])
					or: { ~laneMeterPeak[i] != ~laneMeterPeakDrawn[i] }) {
					~laneMeterDrawn[i] = lit;
					~laneMeterPeakDrawn[i] = ~laneMeterPeak[i];
					~drawMeter.(i);
				};
				// the number stays at ~2 Hz, as before
				if (showText) {
					~laneMeterTexts[i].string =
						if (db < -60) { "-inf" } { db.round(1).asString };
				};
			};
		}.defer;
	}, '/srMeters');

	// peak markers fall back one block at a time, twice a second
	~peakDecay = Routine {
		loop {
			0.5.wait;
			nL.do { |i|
				if (~laneMeterPeak[i] > ~laneMeterLit[i]) {
					~laneMeterPeak[i] = ~laneMeterPeak[i] - 1;
				};
				// a stopped lane simply stops reporting, so its output meter
				// has to be walked down here or it would freeze lit
				~laneOutSeen[i] = ~laneOutSeen[i] + 1;
				if (~laneOutSeen[i] > 1) {
					if ((~laneOutLit[i] > 0) or: { ~laneOutPeak[i] > 0 }) {
						~laneOutLit[i] = 0;
						~laneOutPeak[i] = (~laneOutPeak[i] - 1).max(0);
						~laneOutDrawn[i] = 0;
						~laneOutPeakDrawn[i] = ~laneOutPeak[i];
						~drawOutMeter.(i);
					};
				} {
					if (~laneOutPeak[i] > ~laneOutLit[i]) {
						~laneOutPeak[i] = ~laneOutPeak[i] - 1;
					};
				};
			};
		};
	}.play(AppClock);

	// ----- MIDI -----
	// init unconditionally: the source list is cached at init time, so a
	// controller plugged in AFTER a previous evaluation is invisible until
	// this re-runs. (Re-evaluating the patch is the way to adopt a device.)
	MIDIClient.init;
	MIDIIn.connectAll;
	("MIDI sources: " ++ MIDIClient.sources.collect { |e| e.device }).postln;
	~midiMon = false;

	// Buttons arrive as CC on some units and as noteOn on others -- Jon's
	// nanoKONTROL2 sends the TRACK buttons as noteOn ch 2, note 58/59, i.e.
	// the factory CC numbers carried on note messages while the faders and
	// knobs stay CC. Both message types route through here, so the same
	// number does the same thing either way and no scene change is needed.
	~midiButton = { |num, val|
		if (val > 0) {
			// same three actions as the on-screen strip buttons, so the unit and
			// the screen always agree about what a button does
			~srMidi.playBtns.do { |c, i| if (num == c) { ~laneTogglePlay.(i) } };
			~srMidi.collageBtns.do { |c, i|
				if (num == c) { ~lcGenerateLanes.([i]) } };
			~srMidi.morphBtns.do { |c, i|
				if (num == c) { ~generateLanes.([i]) } };
			if (num == ~srMidi.tabPrev) { ~setTab.((~curTab - 1).wrap(0, ~tabBtns.size - 1)) };
			if (num == ~srMidi.tabNext) { ~setTab.((~curTab + 1).wrap(0, ~tabBtns.size - 1)) };
			~surfRefresh !? { ~surfRefresh.value };
		};
	};

	MIDIdef.noteOn(\srNoteMon, { |vel, note, chan|
		if (~midiMon) {
			("MIDI noteOn note " ++ note ++ " vel " ++ vel ++ " ch " ++ chan).postln };
		~midiButton.(note, vel);
	});
	MIDIdef.cc(\srCC, { |val, cc, chan|
		var v = val / 127;
		if (~midiMon) {
			("MIDI cc " ++ cc ++ " val " ++ val ++ " ch " ++ chan).postln };
		// fader: morph on the FlowEdit and collage tabs, chase speed on
		// the concatenator tab (the only one with a live parameter)
		~srMidi.gestureSliders.do { |c, i|
			if (cc == c) { ~surfFaderSet.(i, v, false) };
		};
		// knob directly above each fader = that lane's volume
		~srMidi.volumeKnobs.do { |c, i|
			if (cc == c) { ~laneLevel[i] = v; ~applyMix.(i); ~midiDirty = true };
		};
		~srMidi.panKnobs.do { |c, i|
			if (cc == c) { ~lanePan[i] = (v * 2) - 1; ~applyMix.(i); ~midiDirty = true };
		};
		~srMidi.wetSliders.do { |c, i|
			if (cc == c and: { ~curTab == ~tabCc }) {
				~laneWet[i] = v;
				if (~laneShimUp[i]) { ~shimAddr.(i).sendMsg("/wet", v) };
				~midiDirty = true;
			};
		};
		~midiButton.(cc, val);
	});

	// MIDI -> GUI mirror at 2 Hz (stepped; no per-CC repaints)
	~midiMirror = Routine {
		loop {
			if (~midiDirty) {
				~midiDirty = false;
				nL.do { |i|
					~laneMorphSliders[i].value = ~laneMorph[i] / 10;
					~laneMorphBoxes[i].value = ~laneMorph[i].round(0.01);
					~laneLcMorphSliders[i] !? { |s2| s2.value = ~laneMorph[i] / 10 };
					~laneLcMorphBoxes[i] !? { |b2|
						b2.value = ~laneMorph[i].round(0.01) };
					~lanePanBoxes[i].value = ~lanePan[i].round(0.01);
					~laneLevelBoxes[i].value = ~laneLevel[i].round(0.01);
					~laneTempBoxes[i].value = ~laneTemp[i];
					~laneWetBoxes[i].value = ~laneWet[i].round(0.01);
				};
				~surfRefresh !? { ~surfRefresh.value };
			};
			0.5.wait;
		};
	}.play(AppClock);

	// ----- cleanup -----
	~win.onClose = {
		~quitShims.value;
		nL.do { |i|
			~laneMorphSynth[i] !? (_.free);
			~laneRenderSynth[i] !? (_.free);
			~laneLcSynth[i] !? (_.free);
			~laneLcBuf[i] !? (_.free);
			~laneRecSynth[i] !? (_.free);
			~laneSlotBufs[i] !? { |bs| bs.do(_.free) };
			~laneRenderBuf[i] !? (_.free);
			~laneBuf[i] !? (_.free);
		};
		~stopCorpusRec.value;
		// set panes
		~dyadAuto !? (_.stop);
		~wsSynth !? (_.free); ~mtSynth !? (_.free); ~clickSynth !? (_.free); ~lfSynth !? (_.free);
		~dyadGroup !? (_.free);
		~wsDiskBuf !? { |b| b.close; b.free };
		~dyadBufs.do { |b| b !? (_.free) };
		~mtBuf !? (_.free);
		~lfBufs.do { |b| b.free }; ~lfBufs = Dictionary();
		OSCdef(\srWsPos).free; OSCdef(\srMtPos).free; OSCdef(\srClick).free; OSCdef(\srLfPos).free;
		~meterSynth !? (_.free);
		~recTimer !? (_.stop);
		~midiMirror !? (_.stop);
		~peakDecay !? (_.stop);
		~lampRout !? (_.stop);
		~sweepRout !? (_.stop);
		OSCdef(\srConcatStatus).free;
		OSCdef(\srMeters).free;
		OSCdef(\srOutMeters).free;
		MIDIdef(\srCC).free;
		MIDIdef(\srNoteMon).free;
	};

	// preload the default takes so the rig is playable immediately; recording
	// over a lane replaces its take as usual
	// Re-evaluating the patch does NOT stop the render clients the previous
	// evaluation spawned: they are OS processes and go on writing into the
	// same lane directories, so their results land in a session that no
	// longer expects them. Clear them here.
	~killRenderClients.({
		~status.("cleared any render jobs left over from a previous evaluation");
	});

	~srDefaultTakes !? {
		var loaded = 0;
		~srDefaultTakes.do { |rel, i|
			var path = if (rel.isNil) { nil } {
				if (PathName(rel).isAbsolutePath) { rel } { ~srRoot +/+ rel };
			};
			if (i < nL and: { path.notNil } and: { File.exists(path) }) {
				~laneTakePath[i] = path;
				~laneBufFresh[i] = false;    // read from disk, not the rec buffer
				~loadLaneWave.(i);
				loaded = loaded + 1;
			};
		};
		if (loaded > 0) {
			~status.("loaded " ++ loaded ++ " default takes into lanes 1-"
				++ loaded ++ " (breathing_2)");
		};
	};

	~status.("ready -- session " ++ ~srSession.basename
		++ " | tabs 4-6: wall of sound / metronomes / latentft (keys 4 5 6)");
};
)
