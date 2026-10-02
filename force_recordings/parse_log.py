#!/usr/bin/env python3
"""parse_log.py DATE (2026-10-02) -- the always-on raw OSC log (log/<DATE>/<HH>.raw.osc.tsv, from force_hub.scd) as a 50 Hz array:
derived/osc_<DATE>_50hz.npz  {t0 (unix s), dt 0.02, X (n, 14) = DC1-7 then AC1-7, NaN where no data for > 0.5 s, names}
Also prints the other OSC addresses seen (anything that is not /FSDC* or /FSAC*), with counts and first/last time.
"""
import sys, os, glob, numpy as np, datetime as dt
HERE = os.path.dirname(os.path.abspath(__file__))
day = sys.argv[1] if len(sys.argv) > 1 else dt.date.today().isoformat()
names = [f"/FSDC{k}" for k in range(1, 8)] + [f"/FSAC{k}" for k in range(1, 8)]; col = {n: i for i, n in enumerate(names)}
ts, cs, vs, other = [], [], [], {}
for f in sorted(glob.glob(os.path.join(HERE, "log", day, "*.raw.osc.tsv"))):
    t_, c_, v_ = [], [], []
    for line in open(f):
        if line[0] == "#": continue
        p = line.rstrip("\n").split("\t")
        if len(p) < 3: continue
        i = col.get(p[2])
        if i is None:
            o = other.setdefault((p[1], p[2]), [0, float(p[0]), 0.0]); o[0] += 1; o[2] = float(p[0]); continue
        if len(p) < 4: continue
        t_.append(float(p[0])); c_.append(i); v_.append(float(p[3]))
    ts.append(np.array(t_)); cs.append(np.array(c_, np.int8)); vs.append(np.array(v_, np.float32)); print(os.path.basename(f), len(t_), flush=True)
t = np.concatenate(ts); c = np.concatenate(cs); v = np.concatenate(vs); o = np.argsort(t, kind="stable"); t, c, v = t[o], c[o], v[o]
t0 = np.floor(t[0]); grid = np.arange(t0, t[-1], 0.02); X = np.full((len(grid), 14), np.nan, np.float32)
for i in range(14):
    m = c == i; ti, vi = t[m], v[m]
    if not len(ti): continue
    k = np.searchsorted(ti, grid, side="right") - 1; ok = k >= 0
    X[ok, i] = vi[k[ok]]; gap = np.ones(len(grid), bool); gap[ok] = (grid[ok] - ti[k[ok]]) > 0.5; X[gap, i] = np.nan
os.makedirs(os.path.join(HERE, "derived"), exist_ok=True)
out = os.path.join(HERE, "derived", f"osc_{day}_50hz.npz"); np.savez_compressed(out, t0=t0, dt=0.02, X=X, names=np.array(names))
fmt = lambda s: dt.datetime.fromtimestamp(s).strftime("%H:%M:%S")
print(f"{out}: {len(grid)} frames, {fmt(t0)} - {fmt(grid[-1])}, no-data share {np.isnan(X[:, 0]).mean():.2f}")
for (port, addr), (n, a, b) in sorted(other.items()): print(f"  other: port {port} {addr}  x{n}  {fmt(a)}-{fmt(b)}")
