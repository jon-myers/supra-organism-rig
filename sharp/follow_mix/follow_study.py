#!/usr/bin/env python3
"""follow_study.py (2026-10-02, overnight, for Jon) -- FOLLOW MIX: several renders playing together, their levels following the
dancers' force sensors, always renormalised so the shares sum to 1, with a long lag so the balance moves slowly; the lag time
itself set by the CENTRAL sensor (7). Run on yesterday's logged OSC (force_recordings/log/2026-10-01, 50 Hz) to choose between
AC (motion), DC (pressure) and DC-change (shifts of weight) before anything is wired live.

The engine (identical in rig/dev/tornado_live.scd):
  feature x_k(t) in 0..1 per sensor k (1-6 drive sources; 7 sets the lag)
     AC      env of |AC_k| x sens   (rise 0.1 s / fall 0.6 s)                      offset-free: rests at 0
     DC      (DC_k - lo_k) / (hi_k - lo_k), lo/hi = 5th/95th percentile             absolute pressure, per-sensor range
     DCchg   env of |d DC_k / dt| x sens                                            offset-free like AC, slower content
  drive  d_i = floor + x_{s(i)} ^ gamma          source i listens to sensor s(i) = i mod 6
  lag    D_i = one-pole lag of d_i, time tau(t)  (SuperCollider Lag convention: tau = time to get within 60 dB)
  share  w_i = D_i / sum_j D_j                   (sums to 1 at every instant)
  gain   g_i = sqrt(w_i)                         equal POWER: the total loudness stays put while the balance moves
  tau(t) = tau_slow * (tau_fast / tau_slow) ^ c(t),  c = central-sensor feature (0 still -> tau_slow, 1 busy -> tau_fast)
Writes out/: summary.json (metrics per variant), shares_*.png (stacked shares over the run), and listening mixes of the tornado
sets and the octave-down Rite renders driven by 4-5 minutes of the run.
"""
import os, json, numpy as np, datetime as dt
HERE = os.path.dirname(os.path.abspath(__file__)); RIG = os.path.abspath(os.path.join(HERE, "..", ".."))
SO = os.path.abspath(os.path.join(RIG, ".."))
OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)
FS = 50.0
d = np.load(os.path.join(RIG, "force_recordings", "derived", "osc_2026-10-01_50hz.npz")); X = d["X"]; T0 = float(d["t0"])
idx = lambda hhmmss: int((dt.datetime.strptime("2026-10-01 " + hhmmss, "%Y-%m-%d %H:%M:%S").timestamp() - T0) * FS)
SEGS = {"run 16:44-17:47": ("16:44:00", "17:47:30"), "morning 10:41-11:37": ("10:41:00", "11:37:00"), "midday 12:05-13:00": ("12:05:00", "13:00:00")}

def coef(tau):  # SC Lag: within 60 dB after tau seconds
    tau = np.maximum(np.asarray(tau, float), 1e-4); return np.exp(np.log(0.001) / (tau * FS))
def lag(x, tau):
    tau = np.broadcast_to(np.asarray(tau, float), x.shape[:1]); b = coef(tau); y = np.empty_like(x); acc = x[0].copy()
    for t in range(len(x)): acc = b[t] * acc + (1 - b[t]) * x[t]; y[t] = acc
    return y
def lagud(x, up, down):
    bu, bd = coef(up), coef(down); y = np.empty_like(x); acc = x[0].copy()
    for t in range(len(x)): b = np.where(x[t] > acc, bu, bd); acc = b * acc + (1 - b) * x[t]; y[t] = acc
    return y
def fill(a):   # hold the last value across gaps (the live bus also holds)
    a = a.copy()
    for k in range(a.shape[1]):
        m = np.isfinite(a[:, k]);
        if not m.any(): a[:, k] = 0; continue
        i = np.where(m, np.arange(len(a)), 0); np.maximum.accumulate(i, out=i); a[:, k] = a[i, k]; a[~np.isfinite(a[:, k]), k] = 0
    return a

DCall, ACall = X[:, :7], X[:, 7:]
LO = np.nanpercentile(DCall, 5, 0); HI = np.nanpercentile(DCall, 95, 0)
_r = slice(int((dt.datetime(2026, 10, 1, 16, 44).timestamp() - T0) * FS), int((dt.datetime(2026, 10, 1, 17, 47).timestamp() - T0) * FS))
_g = np.abs(np.diff(fill(DCall[_r]), axis=0)) * FS; CHG95 = np.percentile(lagud(_g, 0.1, 0.6), 95, 0)
ACT95 = np.percentile(np.sqrt(lag(fill(ACall[_r]) ** 2, 4.0)), 95, 0)
def features(a, b, kind, sens_ac=4.0, sens_chg=8.0, win=4.0):
    dc, ac = fill(DCall[a:b]), fill(ACall[a:b])
    if kind == "AC": return np.clip(lagud(np.abs(ac) * sens_ac, 0.1, 0.6), 0, 1)
    if kind == "ACact":   # ACTIVITY: motion RMS over the last ~win s, scaled so each sensor's 95th percentile (in the run) = 1
        return np.clip(np.sqrt(lag(ac ** 2, win)) / ACT95, 0, 1)
    if kind == "DC": return np.clip((dc - LO) / np.maximum(HI - LO, 1e-3), 0, 1)
    if kind == "DCchg":
        g = lagud(np.vstack([np.zeros((1, 7)), np.abs(np.diff(dc, axis=0)) * FS]), 0.1, 0.6)   # pressure change per second
        return np.clip(g / CHG95, 0, 1)                                                          # 95th percentile -> 1
    raise ValueError(kind)
def engine(x, n, floor=0.05, gamma=2.0, tau=8.0, tau7=None, cfeat=None):
    s = np.arange(n) % 6; dr = floor + x[:, s] ** gamma
    if tau7 is not None:
        c = lagud(cfeat[:, 6:7], 0.5, 3.0)[:, 0].clip(0, 1); tau = tau7[0] * (tau7[1] / tau7[0]) ** c
    D = lag(dr, tau); w = D / D.sum(1, keepdims=True); return w, tau
def metrics(w, x, tau):
    n = w.shape[1]; lead = np.argmax(w, 1)
    # leader changes with hysteresis: a new leader must beat the old by 10 % of its share
    ch = 0; cur = lead[0]
    for t in range(1, len(w)):
        if lead[t] != cur and w[t, lead[t]] > 1.1 * w[t, cur]: ch += 1; cur = lead[t]
    H = -(w * np.log(w + 1e-12)).sum(1) / np.log(n)
    follow = np.nanmean([np.corrcoef(w[:, i], x[:, i % 6])[0, 1] for i in range(n) if x[:, i % 6].std() > 1e-6])
    return dict(minutes=round(len(w) / FS / 60, 1), leader_changes_per_min=round(ch / (len(w) / FS / 60), 2),
                mean_evenness=round(float(H.mean()), 3), most_dominant_share_p95=round(float(np.percentile(w.max(1), 95)), 3),
                share_speed_per_s=round(float(np.abs(np.diff(w, axis=0)).sum(1).mean() * FS), 4),
                follows_own_sensor_r=round(float(follow), 3), tau_median_s=round(float(np.median(tau)), 1))

VARIANTS = {   # name: (feature, engine kwargs).  lag = SC 60-dB time; the time constant is lag / 6.9
    "AC raw  lag 20 s (first try)": ("AC", dict(tau=20.0)),
    "AC activity  lag 30 s": ("ACact", dict(tau=30.0, gamma=2.5)),
    "AC activity  lag 60 s": ("ACact", dict(tau=60.0, gamma=2.5)),
    "AC activity  lag 60->10 s by sensor 7": ("ACact", dict(tau7=(60.0, 10.0), gamma=2.5)),
    "DC  lag 30 s": ("DC", dict(tau=30.0, gamma=2.5)),
    "DC  lag 60->10 s by sensor 7": ("DC", dict(tau7=(60.0, 10.0), gamma=2.5)),
    "DC change  lag 30 s": ("DCchg", dict(tau=30.0, gamma=2.5)),
}
if __name__ == "__main__":
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    summary = {}; N = 5
    for seg, (a_, b_) in SEGS.items():
        a, b = idx(a_), idx(b_); summary[seg] = {}
        feats = {k: features(a, b, k) for k in ("AC", "ACact", "DC", "DCchg")}
        # how much of DC's movement is placement steps (sensor moved / re-seated) rather than dancing:
        dc = fill(DCall[a:b]); sm = lag(dc, 2.0); step = np.abs(np.diff(sm[:: int(FS * 5)], axis=0)) > 0.15
        summary[seg]["DC steps (>0.15 in 5 s) per sensor"] = [int(v) for v in step.sum(0)]
        fig, ax = plt.subplots(len(VARIANTS), 1, figsize=(20, 2.3 * len(VARIANTS)), sharex=True)
        tt = np.arange(b - a) / FS / 60
        for r, (name, (kind, kw)) in enumerate(VARIANTS.items()):
            x = feats[kind]; w, tau = engine(x, N, cfeat=feats["ACact"], **kw)   # sensor 7's lag control always reads its ACTIVITY
            summary[seg][name] = metrics(w, x, np.broadcast_to(tau, (len(w),)))
            ax[r].stackplot(tt[::25], w[::25].T, colors=["#5aa9ff", "#ff6b6b", "#ffa64d", "#5fd17a", "#b48cff"], lw=0)
            ax[r].set_ylim(0, 1); ax[r].set_ylabel(name, rotation=0, ha="right", fontsize=9); ax[r].set_yticks([])
        ax[-1].set_xlabel(f"minutes from {a_}  (shares of 5 sources; sources 1-5 = sensors 1-5)")
        plt.suptitle(f"FOLLOW MIX shares, {seg}"); plt.tight_layout(); plt.savefig(os.path.join(OUT, f"shares_{seg.split()[0]}.png"), dpi=60); plt.close()
    json.dump(summary, open(os.path.join(OUT, "summary.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))
