/*
force_breath.scd -- FORCE -> 36 BREATHS, "perturbation" configuration (2026-09-29, Jon). ALTERNATE: touches no
other file. Needs breath36.scd (the voices) and force_hub.scd (the FORCE tab's buses) loaded first; show_tabs_dev.scd
loads everything (tab 7). show_tabs.scd, breath36.scd, force_hub.scd and force_layer.scd are unchanged by this.

Each voice keeps its CENTRE exactly as now -- its breath36 slider / nanoKONTROL2 block fader / ALL (the morph,
breath -> harmonium). Force adds a wobble around it:
    morph = centre + depth * p_i        (clipped 0..1 by breath36's own control synth)
through breath36's existing modulation input (~b36SetMod), the same hook force_layer.scd uses.

p_i, voice i's wobble (-1..1), from a subset of the six sensors -- 36 = 6 + 15 + 15:
    6 SINGLE   p = s[a]                    follows one sensor
   15 TOGETHER p = (s[a] + s[b]) / 2       a pair in unison: moves when either presses, most when both do
   15 AGAINST  p = s[a] - s[b]             the same pairs in contrary motion: up when a presses, down when b does
Assignment is spread so every nanoKONTROL2 block (4 5 4 5 4 5 4 5) and every performer gets a mix of kinds and
sensors; the grid on screen names each voice's subset.
Signal s (menu):  AC (default: press pushes up, release swings down, a held press settles back in ~1-2 s)
                  DC (press pushes up only)      DC vs its own 10-s average (slower both-way wobble)
Controls: mode off / PERTURB / grid (= force_layer.scd's 6x6 products, if loaded -- only one drives the voices),
depth 0-50 % (default 30), sensitivity (x on the signal), smoothing (s).
nanoKONTROL2: the transport REC button toggles force on/off while the 36 BREATHS tab owns the controller.
SLOW SIGNALS (Jon: "averages that are slow smoothed out, like 5 second long lagging activity level"), for each sensor
and central, window W s (default 5, one-pole average with time constant W):
    activity k = the average size of sensor k's AC over ~W s, x gain, 0..1 -- how much it has been MOVING lately
    slow DC k  = its DC averaged over ~W s                                  -- how hard it has been pressed lately
  on buses for any patch: In.kr(~fbSlowBus.index + k) activity, + 7 + k slow DC (k 0-5, 6 = central).
  Used here two ways: signal "slow activity" (voices drift up as their sensors get busy), and "depth follows
  overall activity" (the wobble is small when the dancers are calm, full when the ensemble is busy).
DISPLAY: the grid shows each voice's current wobble, redrawn 4 times a second at most (Jon: vestibular migraine);
"show live wobble" off freezes it. The breath36 sliders keep showing the centres.
*/
(
~fbP = ~fbP ? (mode: \off, lastOn: \perturb, depth: 0.3, sens: 1, smooth: 0.1, signal: 0, showLive: true);
~fbP[\win] = ~fbP[\win] ? 5; ~fbP[\actGain] = ~fbP[\actGain] ? 3; ~fbP[\actDepth] = ~fbP[\actDepth] ? 0;
s = Server.default;
s.waitForBoot {
	var pairs, kinds, order, ka, kb, wa, wb, lab;
	// ---- tear down a previous evaluation ----
	~fbWin !? { if (~fbWin.isClosed.not) { ~fbWin.onClose = nil; ~fbWin.close } };
	~fbRout !? { ~fbRout.stop };
	if (~fbP[\mode] == \perturb) { ~b36ClearMod !? { ~b36ClearMod.() } };
	~fbSynth = nil; ~fbSlowSynth = nil; ~fbGrp !? { ~fbGrp.free }; ~fbOut !? { ~fbOut.free };
	MIDIdef(\fbcc).free; MIDIdef(\fbnote).free;

	// ---- the 36 subsets: 6 singles, 15 pairs together, 15 pairs against ----
	pairs = [[0,1],[2,3],[4,5],[0,2],[1,4],[3,5],[0,3],[1,5],[2,4],[0,4],[1,3],[2,5],[0,5],[1,2],[3,4]];   // round-robin: neighbours share no sensor
	// kind per voice (fixed, no randomness): singles at voices 1 8 15 22 29 36 -- the voices are tiled
	// anna grisha raymond sora ..., so every performer gets singles -- the rest alternate together / against
	~fbSinglesAt = [0, 7, 14, 21, 28, 35];
	kinds = 36.collect { |i| if (~fbSinglesAt.includes(i)) { \single } {
		if ((i - ~fbSinglesAt.count { |j| j < i }).even) { \together } { \against } } };
	order = (single: [[0,0],[3,3],[1,1],[4,4],[2,2],[5,5]], together: pairs, against: pairs.rotate(7));
	ka = Array.newClear(36); kb = Array.newClear(36); wa = Array.newClear(36); wb = Array.newClear(36); lab = Array.newClear(36);
	~fbCount = (single: 0, together: 0, against: 0);
	36.do { |i| var kd = kinds[i], n = ~fbCount[kd], ab = order[kd][n];
		~fbCount[kd] = n + 1;
		ka[i] = ab[0]; kb[i] = ab[1];
		switch (kd,
			\single,   { wa[i] = 1; wb[i] = 0; lab[i] = (ab[0] + 1).asString },
			\together, { wa[i] = 0.5; wb[i] = 0.5; lab[i] = (ab[0] + 1).asString ++ "+" ++ (ab[1] + 1) },
			\against,  { wa[i] = 1; wb[i] = -1; lab[i] = (ab[0] + 1).asString ++ "-" ++ (ab[1] + 1) }) };
	~fbKinds = kinds; ~fbLabels = lab;

	// slow signals: 7 activities (|AC| averaged, x gain), 7 slow DCs (time constant `win` s), 6 DC-minus-10-s-average
	SynthDef(\fbSlow, { |in = 0, out = 0, win = 5, actGain = 3|
		var dc = In.kr(in, 7), ac = In.kr(in + 7, 7), c = exp(-1 / (win.max(0.1) * ControlRate.ir));
		var rel = dc.keep(6) - OnePole.kr(dc.keep(6), exp(-1 / (10 * ControlRate.ir)));
		Out.kr(out, (OnePole.kr(ac.abs, c) * actGain).clip(0, 1) ++ OnePole.kr(dc, c) ++ rel);
	}).add;
	// one small synth per voice (a single 36-voice def is too big to send over OSC): p = wa * s[ka] + wb * s[kb]
	SynthDef(\fbVoice, { |in = 0, slow = 0, out = 0, ka = 0, kb = 0, wa = 1, wb = 0, signal = 0, sens = 1, depth = 0.3, smooth = 0.1, actDepth = 0|
		var sig = { |k| Select.kr(signal, [In.kr(in + 7 + k), In.kr(in + k), In.kr(slow + 14 + k), In.kr(slow + k)]) * sens };
		var p = (sig.(ka) * wa) + (sig.(kb) * wb);
		Out.kr(out, Lag.kr(p.clip(-1, 1), smooth) * depth.lag(0.1) * Select.kr(actDepth, [1, In.kr(slow + 6)]));
	}).add;
	s.sync;
	~fbOut = Bus.control(s, 36);
	~fbSlowBus !? { ~fbSlowBus.free }; ~fbSlowBus = Bus.control(s, 20);
	~fbGrp = Group.head(s);   // ahead of breath36's voices in the default group
	~fbStart = {
		~fbSynth !? { ~fbSynth.do(_.free) };
		if (~fhBus.isNil) { "force_breath: no FORCE tab buses (~fhBus) -- load force_hub.scd first".warn; ~fbSynth = nil } {
			~fbSlowSynth !? { ~fbSlowSynth.free };
			~fbSlowSynth = Synth(\fbSlow, [\in, ~fhBus.index, \out, ~fbSlowBus.index, \win, ~fbP[\win], \actGain, ~fbP[\actGain]], ~fbGrp, \addToHead);
			~fbSynth = 36.collect { |i| Synth(\fbVoice, [\in, ~fhBus.index, \slow, ~fbSlowBus.index, \out, ~fbOut.index + i,
				\ka, ka[i], \kb, kb[i], \wa, wa[i], \wb, wb[i], \signal, ~fbP[\signal], \sens, ~fbP[\sens], \depth, ~fbP[\depth],
				\smooth, ~fbP[\smooth], \actDepth, ~fbP[\actDepth]], ~fbGrp, \addToTail) } } };
	~fbStart.();

	// ---- modes: only one thing drives breath36's modulation input ----
	~fbApply = { |mode|
		if (~b36SetMod.isNil) { "force_breath: breath36 is not loaded".warn } {
			if (mode != \grid) { ~flEngage !? { if (~flEngaged == true) { ~flEngage.(false) } } };
			switch (mode,
				\off,     { ~b36ClearMod.() },
				\perturb, { ~fbSynth ?? { ~fbStart.() }; 36.do { |i| ~b36SetMod.(i, ~fbOut.index + i, 1) } },
				\grid,    { if (~flEngage.notNil) { ~flEngage.(true) } { "force_breath: grid = force_layer.scd, which is not loaded".warn; ~b36ClearMod.() } });
			~fbAppliedTo = ~b36Synths };
		~fbP[\mode] = mode; if (mode != \off) { ~fbP[\lastOn] = mode };
		~uiLater !? { ~uiLater.(\fbMode, { ~fbModeMenu !? { ~fbModeMenu.value = [\off, \perturb, \grid].indexOf(mode) } }) } };
	~fbToggle = { ~fbApply.(if (~fbP[\mode] == \off) { ~fbP[\lastOn] } { \off }) };
	~fbSet = { |key, v| ~fbP[key] = v; ~fbGrp !? { ~fbGrp.set(key, v) } };   // every voice synth + the slow synth

	// ---- GUI ----
	~fbWin = if (~stHost.notNil) { ~stHost.(\fbreath) } { Window("breath force -- perturbation", Rect(120, 80, 900, 620)).front };
	~fbModeMenu = PopUpMenu().items_(["off", "PERTURB around the centres", "grid (force_layer.scd)"]).value_([\off, \perturb, \grid].indexOf(~fbP[\mode]))
		.action_({ |m| ~fbApply.([\off, \perturb, \grid][m.value]) }).fixedWidth_(260);
	~fbSigMenu = PopUpMenu().items_(["AC (press up, release down)", "DC (press pushes up only)", "DC vs its 10-s average", "slow activity (drifts up when busy)"]).value_(~fbP[\signal])
		.action_({ |m| ~fbSet.(\signal, m.value) }).fixedWidth_(240);
	~fbDepthSl = Slider().orientation_(\horizontal).fixedHeight_(24).value_(~fbP[\depth] / 0.5)
		.action_({ |sl| ~fbSet.(\depth, sl.value * 0.5); ~uiLater.(\fbDepthTxt, { ~fbDepthTxt.string = (~fbP[\depth] * 100).round.asInteger.asString ++ " %" }) });
	~fbDepthTxt = StaticText().string_((~fbP[\depth] * 100).round.asInteger.asString ++ " %").fixedWidth_(50);
	~fbSensBox = NumberBox().value_(~fbP[\sens]).clipLo_(0).clipHi_(5).step_(0.1).scroll_step_(0.1).decimals_(1).fixedWidth_(50).action_({ |b| ~fbSet.(\sens, b.value) });
	~fbSmoothBox = NumberBox().value_(~fbP[\smooth]).clipLo_(0).clipHi_(5).step_(0.05).scroll_step_(0.05).decimals_(2).fixedWidth_(50).action_({ |b| ~fbSet.(\smooth, b.value) });
	~fbLive = CheckBox().string_("show live wobble").value_(~fbP[\showLive]).action_({ |c| ~fbP[\showLive] = c.value; ~fbGrid.refresh });
	~fbShown = 0 ! 36;
	// 36 cells in breath36's voice order, grouped by nanoKONTROL2 block (4 5 4 5 4 5 4 5): one column per fader
	~fbBlocks = [4, 5, 4, 5, 4, 5, 4, 5];
	~fbGrid = UserView().minHeight_(5 * 52 + 30).background_(Color.grey(0.96)).drawFunc_({ |uv|
		var w = uv.bounds.width, cw = (w - 16) / 8, v = 0;
		~fbBlocks.do { |sz, g| ("fader " ++ (g + 1)).drawAtPoint((8 + (g * cw) + 4) @ 4, Font.default.size_(11).boldVariant, Color.grey(0.35));
			sz.do { |r| var i = v + r, x = 8 + (g * cw) + 3, y = 24 + (r * 52), p = ~fbShown[i] ? 0, d = ~fbP[\depth].max(0.001), f = (p / d).clip(-1, 1);
				Pen.fillColor = Color.grey(0.88); Pen.fillRect(Rect(x, y, cw - 6, 46));
				if (~fbP[\showLive] and: { ~fbP[\mode] == \perturb }) {
					Pen.fillColor = if (f >= 0) { Color(0.35, 0.55, 0.75, 0.55) } { Color(0.75, 0.5, 0.35, 0.55) };
					Pen.fillRect(Rect(x, y + 23 - (f.max(0) * 23), cw - 6, f.abs * 23)) };
				Pen.strokeColor = Color.grey(0.6); Pen.line((x) @ (y + 23), (x + cw - 6) @ (y + 23)); Pen.stroke;
				("v" ++ (i + 1)).drawAtPoint((x + 3) @ (y + 2), Font.default.size_(10), Color.grey(0.45));
				~fbLabels[i].drawAtPoint((x + 3) @ (y + 16), Font.default.size_(15).boldVariant,
					switch (~fbKinds[i], \single, { Color.black }, \together, { Color(0.1, 0.3, 0.6) }, \against, { Color(0.6, 0.25, 0.1) }));
				if (~fbP[\showLive] and: { ~fbP[\mode] == \perturb }) {
					((if (p >= 0) { "+" } { "" }) ++ (p * 100).round.asInteger ++ "%").drawAtPoint((x + 3) @ (y + 32), Font.default.size_(10), Color.grey(0.25)) } };
			v = v + sz } });
	~fbStatus = StaticText().string_("").fixedHeight_(18);
	~fbWinBox = NumberBox().value_(~fbP[\win]).clipLo_(0.5).clipHi_(60).step_(0.5).scroll_step_(0.5).decimals_(1).fixedWidth_(50).action_({ |b| ~fbSet.(\win, b.value) });
	~fbGainBox = NumberBox().value_(~fbP[\actGain]).clipLo_(0.1).clipHi_(20).step_(0.1).scroll_step_(0.1).decimals_(1).fixedWidth_(50).action_({ |b| ~fbSet.(\actGain, b.value) });
	~fbActDepth = CheckBox().string_("depth follows overall activity").value_(~fbP[\actDepth] == 1).action_({ |c| ~fbSet.(\actDepth, c.value.asInteger) });
	~fbSlowShown = 0 ! 14;
	~fbSlowView = UserView().fixedHeight_(58).background_(Color.grey(0.96)).drawFunc_({ |uv|
		var w = uv.bounds.width, cw = (w - 150) / 7, v = ~fbSlowShown;
		"activity".drawAtPoint(6 @ 10, Font.default.size_(11).boldVariant, Color.grey(0.3));
		"slow level".drawAtPoint(6 @ 34, Font.default.size_(11).boldVariant, Color.grey(0.3));
		7.do { |k| var x = 90 + (k * cw);
			["1", "2", "3", "4", "5", "6", "central"][k].drawAtPoint((x + 2) @ 0, Font.default.size_(9), Color.grey(0.4));
			Pen.fillColor = Color.grey(0.86); Pen.fillRect(Rect(x, 12, cw - 8, 16)); Pen.fillRect(Rect(x, 36, cw - 8, 16));
			Pen.fillColor = Color(0.3, 0.55, 0.4); Pen.fillRect(Rect(x, 12, (v[k] ? 0).clip(0, 1) * (cw - 8), 16));
			Pen.fillColor = Color(0.25, 0.4, 0.7); Pen.fillRect(Rect(x, 36, ((v[7 + k] ? 0) / (if ((k == 6) and: { (~fhP !? { |p| p[\central] }) == \sum }) { 6 } { 1 })).clip(0, 1) * (cw - 8), 16)) } });
	~fbWin.layout = VLayout(
		HLayout(StaticText().string_("force -> 36 breaths").font_(Font.default.size_(15).boldVariant), ~fbModeMenu, nil,
			StaticText().string_("signal"), ~fbSigMenu),
		HLayout(StaticText().string_("depth (up and down around each centre)"), ~fbDepthSl, ~fbDepthTxt),
		HLayout(StaticText().string_("sensitivity x"), ~fbSensBox, StaticText().string_("  smoothing s"), ~fbSmoothBox, nil, ~fbLive),
		HLayout(StaticText().string_("SLOW SIGNALS  window s").font_(Font.default.boldVariant), ~fbWinBox, StaticText().string_("  activity gain x"), ~fbGainBox, nil, ~fbActDepth),
		~fbSlowView,
		~fbGrid,
		StaticText().string_("black = one sensor,  blue a+b = a pair together,  brown a-b = the pair against each other (up when a presses, down when b does). "
			++ "Centres = the 36 BREATHS sliders / nanoKONTROL2 block faders.").font_(Font.default.size_(11)),
		~fbStatus, nil);

	// ---- the ONE display routine: 4 times a second at most ----
	~fbRout = Routine { loop {
		// breath36 reloaded (new voice synths)? re-attach the current mode
		if ((~fbP[\mode] != \off) and: { ~b36Synths.notNil } and: { ~b36Synths !== ~fbAppliedTo }) { ~fbApply.(~fbP[\mode]) };
		if (~fbP[\showLive] and: { ~fbP[\mode] == \perturb }) { ~fbOut.getn(36, { |v| ~fbShown = v }) };
		if (~fbP[\showLive]) { ~fbSlowBus.getn(14, { |v| ~fbSlowShown = v }) };
		~fbGrid.refresh; ~fbSlowView.refresh;
		~fbStatus.string = switch (~fbP[\mode], \off, { "OFF -- the breaths are exactly as without force" },
				\perturb, { "PERTURB: each voice moves up to " ++ (~fbP[\depth] * 100).round.asInteger ++ " % either way around its centre" },
				\grid, { "GRID: force_layer.scd drives the voices" ++ if (~flEngage.isNil) { " (NOT LOADED)" } { "" } })
			++ "   |   FORCE source: " ++ (~fhP !? { |p| p[\source] } ? "no FORCE tab") ++ "   |   Korg REC toggles on/off (36 BREATHS tab)";
		0.25.wait } }.play(AppClock);

	// ---- nanoKONTROL2: REC (cc 45, or note 45) toggles force while the 36 BREATHS tab owns the controller ----
	MIDIdef.cc(\fbcc, { |val, cc| if ((cc == 45) and: { val > 0 } and: { ~mkOwner == \breath36 }) { { ~fbToggle.() }.defer } }).permanent_(true);
	MIDIdef.noteOn(\fbnote, { |vel, note| if ((note == 45) and: { ~mkOwner == \breath36 }) { { ~fbToggle.() }.defer } }).permanent_(true);

	~fbWin.onClose = { ~fbRout.stop; if (~fbP[\mode] == \perturb) { ~b36ClearMod !? { ~b36ClearMod.() } };
		~fbSynth = nil; ~fbSlowSynth = nil;   // freed with ~fbGrp
		~fbGrp !? { ~fbGrp.free }; ~fbGrp = nil; ~fbOut !? { ~fbOut.free }; ~fbOut = nil; ~fbSlowBus !? { ~fbSlowBus.free }; ~fbSlowBus = nil;
		MIDIdef(\fbcc).free; MIDIdef(\fbnote).free };
	if (~fbP[\mode] != \off) { ~fbApply.(~fbP[\mode]) };
	("FORCE_BREATH_READY  (mode " ++ ~fbP[\mode] ++ ", depth " ++ (~fbP[\depth] * 100).round ++ " %)").postln;
};
)
