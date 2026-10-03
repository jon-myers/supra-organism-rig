/*
force_hub.scd -- the FORCE tab: 14 force signals (6 sensors + a 7th "central", each DC and AC) from one of four
SOURCES, written to 14 control buses that any patch can read. Select all, evaluate (or tab 6 of show_tabs.scd).

  SOURCES
    simulate      six copies of the press process in Marc-André's ForceSensorSimulator.maxpat (a press of random
                  strength 0.1-0.9 held 0.5-2.5 s, then a 0.1-2.1 s pause; ~80 ms attack/release; slow baseline
                  drift; a little noise and 8.5 Hz hand tremor), with knobs for strength / hold / pause, and
                  "contagion": a press can cut other sensors' pauses short. Sensors can be switched off.
    faders        nanoKONTROL2 sliders 1-6 ARE the six sensors (pressure = fader). Same jitter filter as breath36.
    external OSC  the real hardware (or concatenator-corpus/force_sim.py) to sclang's port (57120):
                    /force/all  dc0..dc6 ac0..ac6      (14 floats; 6 = central)
                    /force/dc/<k> v   /force/ac/<k> v   (k 0-6)      /force/dc k v   /force/ac k v
                  "compute AC here" makes AC from the incoming DC instead (for a feed that sends DC only).
    mapped OSC    ANY OSC, however it is labelled: the OSC MONITOR page lists every address that arrives (sender,
                  rate, number of values, latest values, each value's min..max so far) and lets each of the 14
                  signals pick "address [value index]" from a menu, with a range (LEARN = the observed min..max)
                  scaled to 0..1 for DC, -1..1 for AC. Unmapped ACs are computed here; unmapped central = mean/sum.
                  The mapping is saved to rig/force_map.scd on every change and reloaded next time.
                  The page shows this laptop's IP addresses; "also listen on port" opens another UDP port.
    playback      a CSV recorded here (rig/force_recordings/), replayed at its own timing, looping.
  DC = the force, 0..1 (central may exceed 1 when it is the sum). AC = DC through a first-order high-pass at
  0.1 Hz, as in the Max patch ("AC Coupling is achieved by high pass filtering a signal at around 0.1 Hz"):
  a press shows as a bump that sinks back toward 0 over ~1.6 s even if the pressure is held; release swings
  negative. It is NOT the derivative. CENTRAL = mean of the six DCs (or their sum -- menu); it gets its own AC.
  UNKNOWN until the hardware team confirms: what their 7th signal really is, their rate, their ranges.

  FOR OTHER PATCHES (server side, no language hop):
    In.kr(~fhBus.index + k)       DC of sensor k   (k 0-5; 6 = central)
    In.kr(~fhBus.index + 7 + k)   AC of sensor k
  language side: ~fhValues (the latest 14 numbers), ~fhOnFrame (a function called with them every frame, or nil).
  The buses are written at the source rate (30 Hz default, like the Max patch's qmetro 33).

  DISPLAY: every meter, number and status line redraws 4 times a second at most (Jon: faster screen motion
  triggers vestibular migraine). The signals themselves run at full rate; only what is drawn is slowed.
  Record writes every frame (not the 4 Hz view) to force_recordings/force_<date>.csv.
  "send OSC out" also sends every frame as /force/all to host:port (e.g. Max, or another machine).
*/
(
var here = PathName(thisProcess.nowExecutingPath).pathOnly;
~fhRecDir = here +/+ "force_recordings";
~fhNames = ["1", "2", "3", "4", "5", "6", "central"];
~fhP = ~fhP ? (source: \mapped, rate: 30, strength: 1, hold: 1, gap: 1, drift: 1, noise: 1, couple: 0.15,
	central: \mean, acHere: false, sendOut: false, outHost: "127.0.0.1", outPort: 57121);
~fhOn = ~fhOn ? (true ! 6);
s = Server.default;
s.waitForBoot {
	var hp, sensor, frame, csvLine;
	// ---- tear down a previous evaluation (synchronously: see HANDOFF, "No more buffer numbers") ----
	~fhWin !? { if (~fhWin.isClosed.not) { ~fhWin.onClose = nil; ~fhWin.close } };
	~fhSrcRout !? { ~fhSrcRout.stop }; ~fhDrawRout !? { ~fhDrawRout.stop }; ~fhPlayRout !? { ~fhPlayRout.stop };
	~fhLogFlush !? { ~fhLogFlush.() }; ~fhLogRout !? { ~fhLogRout.stop }; ~fhRawRout !? { ~fhRawRout.stop }; ~fhRawReplaying = false;
	~fhRecFile !? { ~fhRecFile.close }; ~fhRecFile = nil;
	[\fhAll, \fhDC, \fhAC, \fhDCflat, \fhACflat].do { |k| OSCdef(k).free }; (0..6).do { |k| OSCdef(("fhDC" ++ k).asSymbol).free; OSCdef(("fhAC" ++ k).asSymbol).free };
	MIDIdef(\fhcc).free;
	~fhRecv !? { thisProcess.removeOSCRecvFunc(~fhRecv) };
	~fhBus = ~fhBus ?? { Bus.control(s, 14) };
	if (~fhBus.server != s) { ~fhBus = Bus.control(s, 14) };
	~fhValues = 0 ! 14; ~fhBus.setn(~fhValues);

	// ---- AC: first-order high-pass at fc Hz, one state per signal (x prev, y) ----
	hp = { |fc = 0.1| (rc: 1 / (2pi * fc), x: nil, y: 0) };
	~fhHP = 7.collect { hp.() };
	~fhAC = { |k, x, dt| var f = ~fhHP[k], a = f[\rc] / (f[\rc] + dt);
		if (f[\x].isNil) { f[\x] = x }; f[\y] = a * (f[\y] + x - f[\x]); f[\x] = x; f[\y] };
	~fhResetAC = { ~fhHP = 7.collect { hp.() } };

	// ---- the simulated sensor (ForceSensorSimulator.maxpat's press process) ----
	sensor = { |i| (i: i, base: rrand(0.02, 0.08), level: 0, target: 0, tNext: 0, pressing: false, phase: rrand(0, 2pi)) };
	~fhSens = 6.collect { |i| sensor.(i) };
	~fhStep = { |sn, t, dt| var a, drift, noise;
		if (t >= sn[\tNext]) {
			if (sn[\pressing]) { sn[\pressing] = false; sn[\target] = 0; sn[\tNext] = t + (rrand(0.1, 2.1) * ~fhP[\gap]) } {
				sn[\pressing] = true; sn[\target] = rrand(0.1, 0.9) * ~fhP[\strength]; sn[\tNext] = t + (rrand(0.5, 2.5) * ~fhP[\hold]);
				// contagion: this press may cut the other sensors' pauses short
				~fhSens.do { |o| if ((o !== sn) and: { o[\pressing].not } and: { ~fhP[\couple].coin }) { o[\tNext] = o[\tNext].min(t + rrand(0.0, 0.3)) } } } };
		if (~fhOn[sn[\i]].not) { sn[\target] = 0 };
		a = 1 - exp(dt.neg / 0.08); sn[\level] = sn[\level] + ((sn[\target] - sn[\level]) * a);
		drift = 0.02 * ~fhP[\drift] * sin((t / 37) + sn[\phase]);
		noise = ~fhP[\noise] * (0.0.gauss(0.004) + (0.006 * sin(t * 2pi * 8.5 + sn[\phase]) * sn[\level]));
		if (~fhOn[sn[\i]]) { (sn[\base] + drift + sn[\level] + noise).clip(0, 1.5) } { 0 } };

	// ---- one frame: 6 DC in -> central, 7 ACs, buses, OSC out, recording ----
	~fhT0 = Main.elapsedTime;
	frame = { |dc6, dt, ac7|
		var dc = dc6 ++ [if (~fhP[\central] == \sum) { dc6.sum } { dc6.mean }];
		var ac = ac7 ?? { 7.collect { |k| ~fhAC.(k, dc[k], dt) } };
		~fhValues = dc ++ ac;
		~fhBus.setn(~fhValues);
		~fhOnFrame !? { ~fhOnFrame.value(~fhValues) };
		if (~fhP[\sendOut]) { ~fhOut !? { ~fhOut.sendMsg('/force/all', *~fhValues) } };
		~fhRecFile !? { ~fhRecFile.write(csvLine.(Main.elapsedTime - ~fhRecT0, ~fhValues)) };
		~fhFrames = (~fhFrames ? 0) + 1 };
	~fhFrame = frame;
	~fhEmit = { |v| ~fhValues = v; ~fhBus.setn(v); ~fhOnFrame !? { ~fhOnFrame.value(v) };
		if (~fhP[\sendOut]) { ~fhOut !? { ~fhOut.sendMsg('/force/all', *v) } };
		~fhRecFile !? { ~fhRecFile.write(csvLine.(Main.elapsedTime - ~fhRecT0, v)) };
		~fhFrames = (~fhFrames ? 0) + 1 };

	// ---- OSC MONITOR: every message from outside SuperCollider, whatever its address ----
	~fhMapPath = here +/+ "force_map.scd";
	~fhMap = if (File.exists(~fhMapPath)) { File.readAllString(~fhMapPath).interpret } ? (nil ! 14) ? (nil ! 14);
	~fhMapRaw = nil ! 14; ~fhMapN = 0; ~fhMapLast = nil;
	~fhReindex = { ~fhMapIndex = Dictionary.new;
		~fhMap.do { |m, j| m !? { ~fhMapIndex[m[\addr]] = (~fhMapIndex[m[\addr]] ? []).add([j, m[\idx]]) } } };
	~fhReindex.();
	~fhSaveMap = { File.use(~fhMapPath, "w", { |f| f.write("// force_hub.scd OSC mapping (14 signals: DC 0-6 then AC 0-6), written " ++ Date.getDate.stamp ++ "\n" ++ ~fhMap.asCompileString ++ "\n") }) };
	~fhSeen = ~fhSeen ? Dictionary.new;
	~fhInternal = { |addr| (addr.ip == "127.0.0.1") and: { Server.all.any { |sv| sv.addr.port == addr.port } } };
	// ---- always-on raw OSC log: rig/force_recordings/log/<YYYY-MM-DD>/<HH>.raw.osc.tsv (one file per hour, created only
	// when messages arrive). Crash-robust: lines are buffered in memory and APPENDED + closed every 2 s, so a crash loses
	// at most ~2 s. Columns: unix time (s), port, address, values. ~fhLogOn = false before loading to disable.
	~fhLogOn = ~fhLogOn ? true; ~fhLogDir = ~fhLogDirOverride ? (~fhRecDir +/+ "log"); ~fhLogBuf = List.new;
	~fhEpoch0 = Date.getDate.rawSeconds - Main.elapsedTime;
	~fhLogFlush = { var lines = ~fhLogBuf, d, dir, path, isNew;
		if (lines.notEmpty) { ~fhLogBuf = List.new;
			d = Date.getDate; dir = ~fhLogDir +/+ d.format("%Y-%m-%d"); path = dir +/+ d.format("%H") ++ ".raw.osc.tsv";
			if (File.exists(dir).not) { File.mkdir(dir) };
			isNew = File.exists(path).not;
			try { File.use(path, "a", { |f|
				if (isNew) { f.write("# raw OSC as received: unix time (s)\tport\taddress\tvalues...  (force_hub.scd always-on log)\n") };
				lines.do { |l| f.write(l) } }); ~fhLogPath = path; ~fhLogLines = (~fhLogLines ? 0) + lines.size }
			{ |err| ("force_hub: log write failed: " ++ err.errorString).warn } } };
	~fhLogRout = Routine { loop { 2.wait; ~fhLogFlush.() } }.play(SystemClock);
	~fhRecv = { |msg, time, addr, port| var a = msg[0].asString, e, args = msg.drop(1), now = Main.elapsedTime;
		if ((a[0] == $/) and: { ~fhInternal.(addr).not }) {
			// RAW OSC recording (2026-10-01, Anna's idea): every incoming message as it arrived, for practice replays that go
			// through whatever mapping is current (a CSV recording stores values AFTER the mapping)
			// ALWAYS-ON LOG (2026-10-01, Jon): every external message, absolute time, appended to disk every 2 s
			if ((~fhLogOn == true) and: { ~fhRawReplaying != true }) {
				~fhLogBuf.add((~fhEpoch0 + now).round(0.0001).asString ++ "\t" ++ port ++ "\t" ++ a ++ "\t" ++ args.collect { |v| if (v.isNumber) { v.round(0.000001) } { v } }.join("\t") ++ "\n") };
			if (~fhRawFile.notNil and: { ~fhRawReplaying != true }) {
				~fhRawFile.write((now - ~fhRecT0).round(0.0001).asString ++ "\t" ++ port ++ "\t" ++ a ++ "\t" ++ args.collect { |v| if (v.isNumber) { v.round(0.000001) } { v } }.join("\t") ++ "\n") };
			e = ~fhSeen[a];
			if (e.isNil and: { ~fhSeen.size < 200 }) { e = (n: 0, lo: [], hi: []); ~fhSeen[a] = e };
			e !? {
				e[\n] = e[\n] + 1; e[\from] = addr.ip ++ ":" ++ addr.port; e[\port] = port; e[\vals] = args; e[\t] = now;
				if (e[\lo].size < args.size) { e[\lo] = e[\lo].extend(args.size, nil); e[\hi] = e[\hi].extend(args.size, nil) };
				args.do { |v, i| if (v.isNumber) { e[\lo][i] = (e[\lo][i] ? v).min(v); e[\hi][i] = (e[\hi][i] ? v).max(v) } } };
			~fhMapIndex[a] !? { |pairs| pairs.do { |p| var v = args[p[1]]; if (v.isNumber) { ~fhMapRaw[p[0]] = v } };
				~fhMapN = ~fhMapN + 1; ~fhMapLast = now } } };
	thisProcess.addOSCRecvFunc(~fhRecv);
	~fhMappedFrame = { |dt| var dc, dc6, ac, sc = { |j, x| var m = ~fhMap[j]; (x - m[\lo]) / (m[\hi] - m[\lo]).max(1e-9) };
		dc = 7.collect { |k| if (~fhMap[k].notNil and: { ~fhMapRaw[k].notNil }) { sc.(k, ~fhMapRaw[k]).clip(0, 6) } };
		dc6 = dc.keep(6).collect { |x| x ? 0 };
		dc = dc6 ++ [dc[6] ?? { if (~fhP[\central] == \sum) { dc6.sum } { dc6.mean } }];
		ac = 7.collect { |k| var j = 7 + k;
			if (~fhMap[j].notNil and: { ~fhMapRaw[j].notNil }) { (sc.(j, ~fhMapRaw[j]) * 2 - 1).clip(-1, 1) } { ~fhAC.(k, dc[k], dt) } };
		~fhEmit.(dc ++ ac) };
	csvLine = { |t, v| t.round(0.0001).asString ++ "," ++ v.collect { |x| x.round(0.00001) }.join(",") ++ "\n" };

	// ---- sources ----
	~fhFader = 0 ! 6; ~fhExtDC = 0 ! 7; ~fhExtAC = 0 ! 7; ~fhExtN = 0; ~fhExtLast = nil; ~fhAllLast = nil;
	~fhSrcRout = Routine { var last = Main.elapsedTime; loop {
		var now = Main.elapsedTime, dt = (now - last).max(0.001), t = now - ~fhT0;
		last = now;
		switch (~fhP[\source],
			\simulate, { frame.(~fhSens.collect { |sn| ~fhStep.(sn, t, dt) }, dt) },
			\faders,   { frame.(~fhFader.collect { |v, i| if (~fhOn[i]) { v } { 0 } }, dt) },
			\external, { if (~fhP[\acHere]) { frame.(~fhExtDC.keep(6), dt) } },   // otherwise frames come straight from the OSC handlers
			\mapped,   { ~fhMappedFrame.(dt) },
			\playback, { }                                                            // frames come from ~fhPlayRout
		);
		(1 / ~fhP[\rate].clip(1, 200)).wait } }.play(SystemClock);

	// external OSC: /force/all (14), /force/dc/<k>, /force/ac/<k>, /force/dc k v, /force/ac k v
	~fhExtFrame = { var dt = if (~fhExtLast.isNil) { 1 / 30 } { (Main.elapsedTime - ~fhExtLast).clip(0.001, 1) };
		~fhExtLast = Main.elapsedTime; ~fhExtN = ~fhExtN + 1;
		if (~fhP[\source] == \external and: { ~fhP[\acHere].not }) {
			~fhValues = ~fhExtDC ++ ~fhExtAC; ~fhBus.setn(~fhValues); ~fhOnFrame !? { ~fhOnFrame.value(~fhValues) }; ~fhFrames = (~fhFrames ? 0) + 1;
			~fhRecFile !? { ~fhRecFile.write(csvLine.(Main.elapsedTime - ~fhRecT0, ~fhValues)) } } };
	OSCdef(\fhAll, { |m| var v = m.drop(1).collect(_.asFloat);
		if (v.size >= 14) { ~fhExtDC = v.keep(7); ~fhExtAC = v.copyRange(7, 13) } { if (v.size >= 6) { ~fhExtDC = v.keep(6) ++ [v.keep(6).mean] } };
		~fhAllLast = Main.elapsedTime; ~fhExtFrame.() }, '/force/all');
	// a sender that sends BOTH /force/all and per-address messages (force_sim.py does) must count once:
	// per-address messages only make a frame when no /force/all has arrived in the last half second
	~fhPerAddrFrame = { if (~fhAllLast.isNil or: { (Main.elapsedTime - ~fhAllLast) > 0.5 }) { ~fhExtFrame.() } };
	7.do { |k|
		OSCdef(("fhDC" ++ k).asSymbol, { |m| ~fhExtDC[k] = m[1].asFloat; if (k == 6) { ~fhPerAddrFrame.() } }, ("/force/dc/" ++ k).asSymbol);
		OSCdef(("fhAC" ++ k).asSymbol, { |m| ~fhExtAC[k] = m[1].asFloat }, ("/force/ac/" ++ k).asSymbol) };
	OSCdef(\fhDCflat, { |m| var k = m[1].asInteger; if (k.inclusivelyBetween(0, 6)) { ~fhExtDC[k] = m[2].asFloat; if (k == 6) { ~fhPerAddrFrame.() } } }, '/force/dc');
	OSCdef(\fhACflat, { |m| var k = m[1].asInteger; if (k.inclusivelyBetween(0, 6)) { ~fhExtAC[k] = m[2].asFloat } }, '/force/ac');

	// playback of a recorded CSV (t, 14 values), looping
	~fhLoadCSV = { |path| var rows = List.new;
		File.readAllString(path).split($\n).drop(1).do { |ln| var f = ln.split($,); if (f.size >= 15) { rows.add(f.collect(_.asFloat)) } };
		rows.asArray };
	~fhPlayFile = { |path| var rows = ~fhLoadCSV.(path);
		~fhPlayRout !? { ~fhPlayRout.stop };
		if (rows.size < 2) { ("force_hub: nothing to play in " ++ path).warn } {
			~fhPlayName = PathName(path).fileName;
			~fhPlayRout = Routine { loop { var prev = rows[0][0];
				rows.do { |r| (r[0] - prev).max(0).wait; prev = r[0];
					if (~fhP[\source] == \playback) { var v = r.drop(1).keep(14);
						~fhValues = v; ~fhBus.setn(v); ~fhOnFrame !? { ~fhOnFrame.value(v) }; ~fhFrames = (~fhFrames ? 0) + 1 } };
				0.1.wait } }.play(SystemClock) } };

	// recording
	~fhRecStart = { var p;
		File.mkdir(~fhRecDir);
		p = ~fhRecDir +/+ "force_" ++ Date.getDate.stamp ++ ".csv";
		~fhRecFile = File(p, "w"); ~fhRecT0 = Main.elapsedTime; ~fhRecPath = p;
		~fhRecFile.write("t," ++ 7.collect { |k| "dc" ++ k }.join(",") ++ "," ++ 7.collect { |k| "ac" ++ k }.join(",") ++ "\n");
		~fhRawPath = p.splitext[0] ++ "_raw.osc.tsv"; ~fhRawFile = File(~fhRawPath, "w");
		~fhRawFile.write("# raw OSC as received: t(s)\tport\taddress\tvalues...  (force_hub.scd REC, " ++ Date.getDate.stamp ++ ")\n") };
	~fhRecStop = { ~fhRecFile !? { ~fhRecFile.close }; ~fhRecFile = nil; ~fhRawFile !? { ~fhRawFile.close }; ~fhRawFile = nil };
	// replay a raw OSC recording: each message SENT to this sclang on its original port at its original time, looping, so
	// the OSC MONITOR, the mapping and the /force/... OSCdefs all see it exactly as if the hardware were sending
	~fhRawReplaying = false;
	~fhRawLoad = { |path| var rows = List.new;
		File.readAllString(path).split($\n).do { |l| var f;
			if ((l.size > 0) and: { l[0] != $# }) { f = l.split($\t);
				if (f.size >= 3) { rows.add([f[0].asFloat, f[1].asInteger, f[2], f.drop(3).collect { |v| var x = v.asFloat; if ((x == 0) and: { v.stripWhiteSpace != "0" } and: { v.stripWhiteSpace.asFloat.isNil.not }) { x } { x } }]) } } };
		rows };
	~fhRawPlay = { |path| var rows = ~fhRawLoad.(path);
		~fhRawRout !? { ~fhRawRout.stop };
		if (rows.isEmpty) { "force_hub: empty raw recording".warn } {
			rows.collect(_[1]).asSet.do { |pt| if (~fhPorts.includes(pt).not and: { pt != NetAddr.langPort }) { if (thisProcess.openUDPPort(pt)) { ~fhPorts = ~fhPorts.add(pt) } } };
			~fhRawReplaying = true; ~fhRawName = PathName(path).fileName;
			~fhRawRout = Routine { loop { var prev = 0;
				prev = rows[0][0];
				rows.do { |r| (r[0] - prev).clip(0, 2).wait; prev = r[0]; NetAddr("127.0.0.1", r[1]).sendMsg(r[2], *r[3]) };   // silences > 2 s shortened to 2 s
				0.05.wait } }.play(SystemClock) } };
	~fhRawStop = { ~fhRawRout !? { ~fhRawRout.stop }; ~fhRawRout = nil; ~fhRawReplaying = false };

	~fhSetOut = { ~fhOut = NetAddr(~fhP[\outHost], ~fhP[\outPort]) }; ~fhSetOut.();
	~fhSetSource = { |src| ~fhP[\source] = src; ~fhResetAC.(); ~fhExtLast = nil;
		if (src == \faders) { ~mkOwners = (~mkOwners ? []).add(\force).asSet.asArray; ~mkOwner = \force } };

	// ---- GUI (everything drawn from ONE routine at 4 Hz) ----
	~fhWin = if (~stHost.notNil) { ~stHost.(\force) } { Window("force hub", Rect(60, 60, 900, 560)).front };
	~fhWin.tryPerform(\toFrontAction_, { ~mkOwners = (~mkOwners ? []).add(\force).asSet.asArray; ~mkOwner = \force });
	~fhSources = [\simulate, \faders, \external, \mapped, \playback];
	~fhSrcMenu = PopUpMenu().items_(["simulate", "nanoKONTROL2 faders 1-6", "external OSC (/force/... addresses)", "external OSC, mapped (OSC MONITOR page)", "playback recording"])
		.value_(~fhSources.indexOf(~fhP[\source]) ? 0)
		.action_({ |m| ~fhSetSource.(~fhSources[m.value]) });
	~fhCentralMenu = PopUpMenu().items_(["central = mean of 6", "central = sum of 6"]).value_((~fhP[\central] == \sum).asInteger)
		.action_({ |m| ~fhP[\central] = [\mean, \sum][m.value] }).fixedWidth_(170);
	~fhMeters = UserView().minHeight_(7 * 34 + 24).background_(Color.grey(0.96))
		.drawFunc_({ |uv| var w = uv.bounds.width, lw = 80, gap = 20, bw = (w - lw - gap - 16) / 2, v = ~fhShown ? (0 ! 14);
			Pen.font = Font.default.size_(11);
			"DC (force)".drawAtPoint((lw + 4) @ 2, Font.default.size_(11).boldVariant, Color.grey(0.3));
			"AC (change vs baseline, 0.1 Hz high-pass)".drawAtPoint((lw + bw + gap + 4) @ 2, Font.default.size_(11).boldVariant, Color.grey(0.3));
			7.do { |k| var y = 22 + (k * 34), dc = v[k], ac = v[7 + k], dmax = if (k == 6 and: { ~fhP[\central] == \sum }) { 6 } { 1 },
				x0 = lw + 4, x1 = lw + bw + gap + 4, mid = x1 + (bw / 2), on = (k == 6) or: { ~fhOn[k] };
				("sensor " ++ ~fhNames[k]).drawAtPoint(4 @ (y + 7), Font.default.size_(12), if (on) { Color.black } { Color.grey(0.6) });
				Pen.fillColor = Color.grey(0.85); Pen.fillRect(Rect(x0, y + 4, bw, 20)); Pen.fillRect(Rect(x1, y + 4, bw, 20));
				Pen.fillColor = Color(0.2, 0.4, 0.75); Pen.fillRect(Rect(x0, y + 4, (dc / dmax).clip(0, 1) * bw, 20));
				Pen.fillColor = if (ac >= 0) { Color(0.25, 0.6, 0.35) } { Color(0.75, 0.4, 0.25) };
				Pen.fillRect(Rect(mid + (ac.clip(-1, 0) * bw / 2), y + 4, ac.clip(-1, 1).abs * bw / 2, 20));
				Pen.strokeColor = Color.grey(0.5); Pen.line(mid @ (y + 2), mid @ (y + 26)); Pen.stroke;
				dc.round(0.01).asString.drawAtPoint((x0 + bw - 34) @ (y + 7), Font.default.size_(11), Color.grey(0.15));
				(if (ac >= 0) { "+" } { "" } ++ ac.round(0.01)).drawAtPoint((x1 + bw - 40) @ (y + 7), Font.default.size_(11), Color.grey(0.15)) } });
	~fhKnob = { |key, label, lo, hi| var sp = ControlSpec(lo, hi, \lin), nb;
		nb = NumberBox().value_(~fhP[key]).clipLo_(lo).clipHi_(hi).decimals_(2).step_((hi - lo) / 100).scroll_step_((hi - lo) / 100).fixedWidth_(52)
			.action_({ |b| ~fhP[key] = b.value });
		HLayout(StaticText().string_(label), nb) };
	~fhOnBoxes = 6.collect { |i| CheckBox().string_(~fhNames[i]).value_(~fhOn[i]).action_({ |c| ~fhOn[i] = c.value }) };
	~fhAcHere = CheckBox().string_("compute AC here").value_(~fhP[\acHere]).action_({ |c| ~fhP[\acHere] = c.value; ~fhResetAC.() });
	~fhSendOut = CheckBox().string_("send OSC out /force/all to").value_(~fhP[\sendOut]).action_({ |c| ~fhP[\sendOut] = c.value });
	~fhOutField = TextField().string_(~fhP[\outHost] ++ ":" ++ ~fhP[\outPort]).fixedWidth_(140)
		.action_({ |t| var p = t.string.split($:); ~fhP[\outHost] = p[0]; ~fhP[\outPort] = (p[1] ? "57121").asInteger; ~fhSetOut.() });
	~fhRecBtn = Button().states_([["REC"], ["STOP REC", Color.white, Color.red(0.7)]]).fixedWidth_(90)
		.action_({ |b| if (b.value == 1) { ~fhRecStart.() } { ~fhRecStop.() } });
	~fhPlayMenu = PopUpMenu().fixedWidth_(260);
	~fhScanRecs = { ~fhRecs = (~fhRecDir +/+ "*.csv").pathMatch.sort.reverse; ~fhPlayMenu.items = if (~fhRecs.isEmpty) { ["(no recordings yet)"] } { ~fhRecs.collect { |p| PathName(p).fileName } } };
	~fhScanRecs.();
	~fhRawMenu = PopUpMenu().fixedWidth_(260);
	~fhScanRaw = { ~fhRaws = ((~fhRecDir +/+ "*_raw.osc.tsv").pathMatch ++ (~fhLogDir +/+ "*/*.raw.osc.tsv").pathMatch).sort { |a, b| File.mtime(a) > File.mtime(b) };
		~fhRawMenu.items = if (~fhRaws.isEmpty) { ["(no raw OSC recordings yet)"] } { ~fhRaws.collect { |p| if (p.contains("/log/")) { "log " ++ PathName(p).folderName ++ " " ++ PathName(p).fileName } { PathName(p).fileName } } } };
	~fhScanRaw.();
	~fhRawBtn = Button().states_([["replay raw OSC"], ["STOP raw replay", Color.white, Color(0.2, 0.45, 0.75)]]).fixedWidth_(130).action_({ |b|
		if (b.value == 1) { ~fhScanRaw.(); if (~fhRaws.notEmpty) { ~fhRawPlay.(~fhRaws[~fhRawMenu.value.clip(0, ~fhRaws.size - 1)]) } { b.value = 0 } } { ~fhRawStop.() } });
	~fhPlayBtn = Button().states_([["play file"]]).fixedWidth_(80).action_({
		~fhScanRecs.(); if (~fhRecs.notEmpty) { ~fhPlayFile.(~fhRecs[~fhPlayMenu.value.clip(0, ~fhRecs.size - 1)]); ~fhSrcMenu.valueAction = 4 } });
	~fhStatus = StaticText().string_("").fixedHeight_(18);
	// ---- page 2: OSC MONITOR + MAPPING ----
	~fhIPs = { "for i in 0 1 2 3 4 5 6 7 8 9; do ipconfig getifaddr en$i; done".unixCmdGetStdOut.split($\n).reject(_.isEmpty) };
	~fhPorts = ~fhPorts ? [];
	// the hardware team's port (force_map.scd: /FSDC1-7, /FSAC1-7 on 7500) is opened at load (2026-10-01), so choosing
	// "external OSC, mapped" is the only step needed when the real sensors are sending
	~fhHwPort = ~fhHwPort ? 7500;
	if (~fhPorts.includes(~fhHwPort).not) { if (thisProcess.openUDPPort(~fhHwPort)) { ~fhPorts = ~fhPorts.add(~fhHwPort) } { ("force_hub: could not open UDP port " ++ ~fhHwPort).warn } };
	~fhWhere = StaticText().font_(Font.default.size_(13).boldVariant);
	~fhShowWhere = { ~fhWhere.string = "send OSC to  " ++ (~fhIPs.().join("  or  ") ? "?") ++ "   port " ++ ([NetAddr.langPort] ++ ~fhPorts).join(" / ") };
	~fhShowWhere.();
	~fhPortField = TextField().string_("9000").fixedWidth_(60);   // 7500 (hardware) is already open
	~fhPortBtn = Button().states_([["also listen on port"]]).action_({ var n = ~fhPortField.string.asInteger;
		if (n > 1024 and: { ~fhPorts.includes(n).not }) { if (thisProcess.openUDPPort(n)) { ~fhPorts = ~fhPorts.add(n) } { ("force_hub: could not open UDP port " ++ n).warn } };
		~fhShowWhere.() });
	~fhClearBtn = Button().states_([["clear list"]]).action_({ ~fhSeen.clear });
	~fhMonText = StaticText().font_(Font.monospace(11)).align_(\topLeft).minHeight_(210).background_(Color.grey(0.97));
	// mapping grid: 14 rows (DC 1-6, DC central, AC 1-6, AC central): source menu, range lo..hi, LEARN
	~fhMapKeys = [];   // [addr, idx] for each menu item after the first ("--")
	~fhMapMenus = 14.collect { |j| PopUpMenu().items_(["--"]).fixedWidth_(250).action_({ |m|
		if (m.value == 0) { ~fhMap[j] = nil } {
			var k = ~fhMapKeys[m.value - 1], e = ~fhSeen[k[0]], lo = e !? { e[\lo][k[1]] }, hi = e !? { e[\hi][k[1]] };
			if (lo.isNil or: { hi.isNil } or: { hi <= lo }) { lo = 0; hi = 1 };
			~fhMap[j] = (addr: k[0], idx: k[1], lo: lo, hi: hi) };
		~fhMapLo[j].value = ~fhMap[j] !? { |x| x[\lo] } ? 0; ~fhMapHi[j].value = ~fhMap[j] !? { |x| x[\hi] } ? 1;
		~fhReindex.(); ~fhSaveMap.() }) };
	~fhMapLo = 14.collect { |j| NumberBox().decimals_(3).fixedWidth_(64).value_(~fhMap[j] !? { |x| x[\lo] } ? 0)
		.action_({ |b| ~fhMap[j] !? { ~fhMap[j][\lo] = b.value; ~fhSaveMap.() } }) };
	~fhMapHi = 14.collect { |j| NumberBox().decimals_(3).fixedWidth_(64).value_(~fhMap[j] !? { |x| x[\hi] } ? 1)
		.action_({ |b| ~fhMap[j] !? { ~fhMap[j][\hi] = b.value; ~fhSaveMap.() } }) };
	~fhMapLearn = 14.collect { |j| Button().states_([["learn"]]).fixedWidth_(50).action_({
		~fhMap[j] !? { |m| var e = ~fhSeen[m[\addr]];
			e !? { if (e[\lo][m[\idx]].notNil and: { e[\hi][m[\idx]] > e[\lo][m[\idx]] }) {
				m[\lo] = e[\lo][m[\idx]]; m[\hi] = e[\hi][m[\idx]]; ~fhMapLo[j].value = m[\lo]; ~fhMapHi[j].value = m[\hi]; ~fhSaveMap.() } } } }) };
	// the menus list what has arrived so far; they refresh only when asked (a menu must not change under the mouse)
	~fhRefreshMenus = { var items;
		~fhMapKeys = ~fhSeen.keys.asArray.sort.collect { |a| var e = ~fhSeen[a];
			e[\vals].size.collect { |i| if (e[\vals][i].isNumber) { [a, i] } } }.flatten(1).reject(_.isNil);
		items = ["--"] ++ ~fhMapKeys.collect { |k| k[0] ++ "  [" ++ k[1] ++ "]" };
		14.do { |j| var m = ~fhMap[j], sel = 0;
			m !? { sel = (~fhMapKeys.detectIndex { |k| (k[0] == m[\addr]) and: { k[1] == m[\idx] } } ? -1) + 1;
				if (sel == 0) { items = items ++ [m[\addr] ++ "  [" ++ m[\idx] ++ "]  (not seen yet)"]; ~fhMapKeys = ~fhMapKeys.add([m[\addr], m[\idx]]); sel = items.size - 1 } };
			~fhMapMenus[j].items = items; ~fhMapMenus[j].value = sel } };
	~fhRefreshBtn = Button().states_([["refresh address menus"]]).action_({ ~fhRefreshMenus.() });
	~fhClearMapBtn = Button().states_([["clear mapping"]]).action_({ ~fhMap = nil ! 14; ~fhReindex.(); ~fhSaveMap.(); ~fhRefreshMenus.() });
	~fhRefreshMenus.();
	~fhSigNames = 7.collect { |k| "DC " ++ ~fhNames[k] } ++ 7.collect { |k| "AC " ++ ~fhNames[k] };
	~fhMapGrid = GridLayout.rows(*(7.collect { |r| [0, 7].collect { |c| var j = r + c;
		[StaticText().string_(~fhSigNames[j]).fixedWidth_(78), ~fhMapMenus[j], ~fhMapLo[j], StaticText().string_(".."), ~fhMapHi[j], ~fhMapLearn[j]] }.flatten }));
	~fhMonPage = View().layout_(VLayout(
		HLayout(~fhWhere, nil, ~fhPortField, ~fhPortBtn, ~fhClearBtn),
		StaticText().string_("everything arriving (not SuperCollider's own messages): address, sender, rate, values now (min..max so far)").font_(Font.default.size_(11)),
		~fhMonText,
		HLayout(StaticText().string_("MAPPING (source 'external OSC, mapped'): DC scaled lo..hi -> 0..1, AC lo..hi -> -1..1").font_(Font.default.size_(11).boldVariant), nil, ~fhRefreshBtn, ~fhClearMapBtn),
		~fhMapGrid, nil).margins_(2));
	~fhMeterPage = View().layout_(VLayout(
		~fhMeters,
		HLayout(StaticText().string_("simulation:"), ~fhKnob.(\strength, "strength", 0, 1.5), ~fhKnob.(\hold, "hold x", 0.1, 5),
			~fhKnob.(\gap, "pause x", 0.1, 5), ~fhKnob.(\couple, "contagion", 0, 1), ~fhKnob.(\drift, "drift", 0, 3), ~fhKnob.(\noise, "noise", 0, 3), nil),
		HLayout(StaticText().string_("sensors on:"), *(~fhOnBoxes ++ [nil])),
		HLayout(~fhRecBtn, ~fhPlayMenu, ~fhPlayBtn, nil, ~fhSendOut, ~fhOutField),
		HLayout(~fhRawMenu, ~fhRawBtn, ~fhLogText = StaticText().string_("").fixedHeight_(16), nil),
		StaticText().string_("patches read: In.kr(~fhBus.index + k) = DC k,  In.kr(~fhBus.index + 7 + k) = AC k   (k 0-5 sensors, 6 central)")
			.font_(Font.default.size_(10)).stringColor_(Color.grey(0.4)), nil).margins_(2));
	~fhPages = StackLayout(~fhMeterPage, ~fhMonPage);
	~fhPageBtns = ["METERS", "OSC MONITOR + MAPPING"].collect { |t, i| Button().states_([[t, Color.black, Color.grey(0.85)], [t, Color.white, Color.blue(0.45)]])
		.action_({ ~fhPages.index = i; ~fhPageBtns.do { |b, j| b.value = (j == i).asInteger }; if (i == 1) { ~fhShowWhere.() } }) };
	~fhPageBtns[0].value = 1;
	~fhWin.layout = VLayout(
		HLayout(StaticText().string_("source").font_(Font.default.boldVariant), ~fhSrcMenu, ~fhCentralMenu, ~fhAcHere, nil, *~fhPageBtns),
		~fhPages,
		~fhStatus
	);
	// monitor text: one line per address, newest activity first
	~fhMonLines = { |prev| var now = Main.elapsedTime, lines;
		lines = ~fhSeen.keys.asArray.sort { |a, b| (~fhSeen[a][\t] ? 0) > (~fhSeen[b][\t] ? 0) }.keep(14).collect { |a| var e = ~fhSeen[a], rate, vs;
			rate = ((e[\n] - (prev[a] ? e[\n])) * 4); prev[a] = e[\n];
			vs = e[\vals].keep(6).collect { |v, i| if (v.isNumber) { v.round(0.001).asString ++ "(" ++ e[\lo][i].round(0.01) ++ ".." ++ e[\hi][i].round(0.01) ++ ")" } { v.asString.keep(12) } }.join(" ");
			a.keep(30).padRight(31) ++ e[\from].padRight(22) ++ ("->" ++ e[\port]).padRight(8)
				++ (if ((now - e[\t]) > 3) { "quiet " ++ (now - e[\t]).round(1) ++ "s" } { rate.asString ++ "/s" }).padRight(11)
				++ e[\vals].size ++ " val" ++ (if (e[\vals].size == 1) { "  " } { "s " }) ++ vs ++ (if (e[\vals].size > 6) { " ..." } { "" }) };
		if (lines.isEmpty) { "(nothing received yet -- waiting on port " ++ ([NetAddr.langPort] ++ ~fhPorts).join(" / ") ++ ")" } { lines.join("\n") } };
	~fhMonPrev = IdentityDictionary.new;
	// the ONLY place anything on screen changes: 4 times a second
	~fhDrawRout = Routine { var lastFrames = 0, lastExt = 0; loop {
		var fps = ((~fhFrames ? 0) - lastFrames) * 4, ext = (~fhExtN - lastExt) * 4;
		lastFrames = ~fhFrames ? 0; lastExt = ~fhExtN;
		~fhShown = ~fhValues.copy;
		if (~fhPages.index == 0) { ~fhMeters.refresh } { ~fhMonText.string = ~fhMonLines.(~fhMonPrev) };
		~fhStatus.string = switch (~fhP[\source],
				\simulate, { "simulating 6 sensors at " ++ ~fhP[\rate] ++ " Hz" },
				\faders, { "nanoKONTROL2 sliders 1-6 = sensors 1-6" ++ if (~mkOwner == \force) { "" } { "   (the controller is owned by " ++ ~mkOwner ++ " -- select this tab)" } },
				\external, { if (~fhExtLast.isNil) { "external: waiting for /force/... on port " ++ NetAddr.langPort }
					{ "external: " ++ (ext.round(1)) ++ " msg/s, last " ++ (Main.elapsedTime - ~fhExtLast).round(0.1) ++ " s ago" } },
				\mapped, { var n = ~fhMap.count(_.notNil);
					if (n == 0) { "mapped: nothing mapped yet -- OSC MONITOR page" } {
						"mapped: " ++ n ++ " of 14 signals mapped" ++ if (~fhMapLast.isNil) { ", waiting for them" } { ", last mapped message " ++ (Main.elapsedTime - ~fhMapLast).round(0.1) ++ " s ago" } } },
				\playback, { "playback: " ++ (~fhPlayName ? "(choose a file, press play file)") })
			++ "   |   " ++ fps.round(1) ++ " frames/s to the buses"
			++ (~fhRecFile !? { "   |   REC " ++ PathName(~fhRecPath).fileName ++ "  " ++ (Main.elapsedTime - ~fhRecT0).round(1) ++ " s" } ? "");
		~fhLogText !? { ~fhLogText.string = "always-on OSC log: " ++ if (~fhLogOn == true) { ((~fhLogLines ? 0).asString ++ " messages logged" ++ (~fhLogPath !? { |p| " -> log/" ++ PathName(p).folderName ++ "/" ++ PathName(p).fileName } ? " (waiting for OSC)")) } { "OFF" } ++ if (~fhRawReplaying == true) { "   |   replaying " ++ (~fhRawName ? "") ++ " (not logged)" } { "" } };
		0.25.wait } }.play(AppClock);

	// ---- nanoKONTROL2: sliders 1-6 are the sensors when this tab owns the controller (source = faders) ----
	~fhHeld = IdentityDictionary.new; ~fhWay = IdentityDictionary.new; ~fhPend = IdentityDictionary.new;
	~fhSteady = { |cc, val| var held = ~fhHeld[cc], d, go = false;   // same jitter filter as breath36 / rite
		if (held.isNil) { ~fhHeld[cc] = val; go = true } {
			d = val - held;
			case
				{ d == 0 } { ~fhPend[cc] = nil }
				{ d.sign == (~fhWay[cc] ? 0) } { go = true; ~fhPend[cc] = nil }
				{ d.abs >= 4 and: { ~fhPend[cc] == d.sign } } { go = true; ~fhPend[cc] = nil }
				{ d.abs >= 4 } { ~fhPend[cc] = d.sign }
				{ ~fhPend[cc] = nil };
			if (go) { ~fhHeld[cc] = val; ~fhWay[cc] = d.sign } };
		go };
	if (MIDIClient.initialized.not) { MIDIClient.init(verbose: false) }; MIDIIn.connectAll(verbose: false);
	MIDIdef.cc(\fhcc, { |val, cc| if (~mkOwner == \force and: { cc < 6 } and: { ~fhSteady.(cc, val) }) { ~fhFader[cc] = val / 127 } }).permanent_(true);

	~fhWin.onClose = { ~fhSrcRout.stop; ~fhDrawRout.stop; ~fhLogFlush.(); ~fhLogRout.stop; ~fhRawStop.(); ~fhRecStop.(); thisProcess.removeOSCRecvFunc(~fhRecv); ~fhPlayRout !? { ~fhPlayRout.stop }; ~fhRecStop.();
		[\fhAll, \fhDCflat, \fhACflat].do { |k| OSCdef(k).free }; 7.do { |k| OSCdef(("fhDC" ++ k).asSymbol).free; OSCdef(("fhAC" ++ k).asSymbol).free };
		MIDIdef(\fhcc).free; ~mkOwners !? { ~mkOwners.remove(\force); ~mkOwner = ~mkOwners.first } };
	("FORCE_HUB_READY  buses " ++ ~fhBus.index ++ ".." ++ (~fhBus.index + 13) ++ " (DC 0-6, AC 0-6)").postln;
};
)
